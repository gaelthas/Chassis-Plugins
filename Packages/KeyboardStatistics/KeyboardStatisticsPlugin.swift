import AppKit
import Foundation
import PluginAPI
import SwiftUI

/// 键盘按键统计：记录每个物理键的按下次数，按天聚合，设置页用键盘热力图与柱状图展示。
///
/// 只订阅键盘事件、只写自己的 store：不读窗口、不取屏、不记录输入内容。
@MainActor
public final class KeyboardStatisticsPlugin: FeaturePlugin {
    public static let manifest = PluginManifest(
        id: "com.gaelthas.plugin.keyboard-statistics",
        version: "1.0.0",
        minHostVersion: "1.0.0",
        title: "kb.title",
        summary: "kb.summary",
        iconSystemName: "keyboard",
        // 键盘 tap 由「输入监控」门控；本插件不碰鼠标与 AX。
        requiredCapabilities: [.inputMonitoring],
        optionalCapabilities: [],
        resourceBundle: resourceBundle
    )

    /// `KeyFilter` 只有白名单、没有通配符，所以枚举全部 HID usage 来表达「所有键」。
    /// 0...255 覆盖 Apple 键盘与外接键盘的常用区间；越界键码本来也不在热力图里。
    private static let allKeyCodes = Set(Int64(0)...Int64(255))

    private var context: PluginContext?
    private var keySub: Subscription?
    private var tickTask: Task<Void, Never>?

    private(set) var settingsModel: KeyboardStatisticsModel?

    public init() {}

    // MARK: - 生命周期

    public func activate(context: PluginContext) throws {
        self.context = context
        if settingsModel == nil {
            settingsModel = KeyboardStatisticsModel(store: context.store)
        }
        guard let model = settingsModel else { return }

        // activate 可能被重复调用：先摘掉旧订阅，避免同一按键被计两次。
        keySub?.cancel()
        keySub = context.inputBus.subscribeToKey(
            KeyFilter(keyCodes: Self.allKeyCodes),
            // 只统计，不拦截：任何按键都原样交给系统。
            syncIntercept: nil,
            handler: { [weak self] event in
                self?.handle(event)
            }
        )

        // 打字频率高，逐键刷新界面/落盘都太浪费：由 1 秒一跳的任务合并。
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.settingsModel?.tick(at: Date())
            }
        }

        model.refresh()
    }

    public func deactivate() {
        keySub?.cancel()
        keySub = nil

        tickTask?.cancel()
        tickTask = nil

        // 关闭时要立刻落盘：之后不再有 tick 任务，未写的计数会丢。
        settingsModel?.persist()
        context = nil
    }

    public func makeSettingsView() -> AnyView {
        guard let model = settingsModel else {
            return AnyView(Text(verbatim: KBStrings.t("plugin.inactive")))
        }
        return AnyView(KeyboardStatisticsSettingsView(model: model))
    }

    // MARK: - 计数

    private func handle(_ event: KeyEvent) {
        guard let model = settingsModel, model.enabled else { return }

        switch event.kind {
        case .keyDown:
            // 长按产生的自动重复不是新的按下，计进去会让空格/方向键的数值失真。
            guard !event.isRepeat else { return }
            // 修饰键统一走 flagsChanged：部分外接键盘会同时发 keyDown，避免重复计数。
            guard KeyboardStatisticsModel.modifierFlag(for: event.keyCode) == nil else { return }
            model.record(keyCode: event.keyCode)

        case .flagsChanged:
            // 松开修饰键时 flags 里没有对应位，只有按下才计。
            guard let flag = KeyboardStatisticsModel.modifierFlag(for: event.keyCode),
                  event.flags.contains(flag) else { return }
            model.record(keyCode: event.keyCode)

        case .keyUp:
            break
        }
    }
}

enum KBStrings {
    static func t(_ key: String) -> String {
        resourceBundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// SwiftPM 构建用 `Bundle.module`；作为 `.chassisplugin` 动态库构建时，
/// `Bundle(for:)` 会向上找到插件包自己的 `Contents/Info.plist`。
final class PluginResourceToken {}

let resourceBundle: Bundle = {
    #if SWIFT_PACKAGE
    return .module
    #else
    return Bundle(for: PluginResourceToken.self)
    #endif
}()
