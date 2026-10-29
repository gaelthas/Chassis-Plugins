import AppKit
import Foundation
import PluginAPI
import SwiftUI

/// Windows 风格 Alt-Tab：在所有**窗口**之间切换（系统 Cmd-Tab 只到应用级）。
///
/// 事件全部走基座的键盘三段式：`syncIntercept` 只在 tap 线程做位运算与原子读，
/// 真正的窗口枚举、悬浮层与激活都在主线程。
@MainActor
public final class WindowSwitcherPlugin: FeaturePlugin {
    public static let manifest = PluginManifest(
        id: "com.gaelthas.plugin.window-switcher",
        version: "1.0.0",
        minHostVersion: "1.0.0",
        title: "windowSwitcher.title",
        summary: "windowSwitcher.summary",
        iconSystemName: "rectangle.on.rectangle",
        // 键盘 tap → 输入监控；窗口枚举与 AX 置顶 → 辅助功能。
        requiredCapabilities: [.inputMonitoring, .accessibility],
        optionalCapabilities: [.screenCapture],
        resourceBundle: resourceBundle
    )

    private var context: PluginContext?
    private var keySub: Subscription?
    private var interruptionSub: Subscription?
    private var orderObserver: NSObjectProtocol?

    private(set) var settingsModel: WindowSwitcherModel?
    private let panel = SwitcherPanel()
    private let thumbnails = ThumbnailGovernor()

    /// tap 线程需要知道「切换器是否打开」以决定是否吞掉导航键。
    private let openFlag = AtomicFlag(false)
    private var isOpen = false
    private var windows: [SwitcherWindow] = []
    private var selected = 0
    private var thumbnailTask: Task<Void, Never>?

    /// 应用级 MRU：最近激活的应用排在前面，窗口按所属应用分组排序。
    private var appOrder: [pid_t] = []

    private enum KeyCode {
        static let tab: Int64 = 0x30
        static let escape: Int64 = 0x35
        static let ret: Int64 = 0x24
        static let left: Int64 = 0x7B
        static let right: Int64 = 0x7C
        static let down: Int64 = 0x7D
        static let up: Int64 = 0x7E
        static let option: Int64 = 0x3A
    }

    public init() {}

    // MARK: - 生命周期

    public func activate(context: PluginContext) throws {
        self.context = context
        if settingsModel == nil {
            settingsModel = WindowSwitcherModel(store: context.store)
        }
        guard let model = settingsModel else { return }

        if let front = NSWorkspace.shared.frontmostApplication {
            appOrder = [front.processIdentifier]
        }
        orderObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // 只在 nonisolated 闭包里取出标量 pid，再带进主线程；NSRunningApplication 不是 Sendable。
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.noteActivation(pid: pid)
                }
            }
        }

        keySub = context.inputBus.subscribeToKey(
            KeyFilter(keyCodes: [
                KeyCode.tab, KeyCode.escape, KeyCode.ret,
                KeyCode.left, KeyCode.right, KeyCode.down, KeyCode.up,
                KeyCode.option,
            ]),
            syncIntercept: { [openFlag] event in
                // 修饰键的 flagsChanged 必须放行，否则系统与其他应用会看不到 ⌥ 的抬起。
                guard event.kind != .flagsChanged else { return .passthrough }
                if openFlag.value { return .consume }
                if event.kind == .keyDown,
                   event.keyCode == KeyCode.tab,
                   event.flags.contains(.maskAlternate) {
                    return .consume  // 吞掉 ⌥Tab，避免插入 Tab 或触发系统切换
                }
                return .passthrough
            },
            handler: { [weak self] event in
                self?.handle(event)
            }
        )

        interruptionSub = context.inputBus.subscribeToInterruptions { [weak self] interruption in
            guard interruption.source == .keyboard else { return }
            self?.close(reason: "input interrupted")
        }

        model.append("ready: \(model.mode == .icons ? "icons" : "thumbnails")")
    }

    public func deactivate() {
        keySub?.cancel()
        interruptionSub?.cancel()
        keySub = nil
        interruptionSub = nil

        if let orderObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(orderObserver)
        }
        orderObserver = nil

        thumbnailTask?.cancel()
        thumbnailTask = nil
        close(reason: "deactivate")
        context = nil
    }

    public func makeSettingsView() -> AnyView {
        guard settingsModel != nil else {
            return AnyView(Text(verbatim: WindowSwitcherStrings.t("plugin.inactive")))
        }
        return AnyView(WindowSwitcherSettingsView(plugin: self))
    }

    // MARK: - 按键

    private func handle(_ event: KeyEvent) {
        if event.kind == .flagsChanged {
            // 松开 ⌥ → 提交。
            if isOpen, event.keyCode == KeyCode.option, !event.flags.contains(.maskAlternate) {
                commit()
            }
            return
        }

        if event.kind == .keyDown {
            if event.keyCode == KeyCode.tab, event.flags.contains(.maskAlternate) {
                if isOpen {
                    move(by: event.flags.contains(.maskShift) ? -1 : 1)
                } else {
                    present()
                }
                return
            }
        }

        guard isOpen, event.kind == .keyDown else { return }
        switch event.keyCode {
        case KeyCode.escape:
            close(reason: "cancelled")
        case KeyCode.ret:
            commit()
        case KeyCode.left, KeyCode.up:
            move(by: -1)
        case KeyCode.right, KeyCode.down:
            move(by: 1)
        default:
            break
        }
    }

    // MARK: - 会话

    private func present() {
        guard let context, let model = settingsModel, !isOpen else { return }
        isOpen = true
        openFlag.value = true

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let knownOrder = appOrder

        Task { [weak self] in
            let list = (try? await context.performBackground {
                WindowCatalog.windows(excludingPID: ownPID)
            }) ?? []

            guard let self else { return }
            guard !list.isEmpty else {
                self.close(reason: "no windows")
                model.append("no windows to switch")
                return
            }

            self.windows = Self.sorted(list, by: knownOrder)
            self.selected = 0
            self.panel.show(
                windows: self.windows,
                selected: 0,
                mode: model.mode,
                showTitles: model.showWindowTitles,
                onSelect: { [weak self] window in
                    // 点击卡片立即切换：与 Dock2Min 的 mouseHover 触发源行为一致。
                    self?.selectFromPanel(window)
                }
            )
            model.append("opened with \(self.windows.count) window(s)")
            let session = self.thumbnails.beginSession()
            self.loadThumbnailsIfNeeded(session: session)
        }
    }

    private func move(by delta: Int) {
        guard isOpen, !windows.isEmpty else { return }
        selected = (selected + delta + windows.count) % windows.count
        panel.update(selected: selected)
    }

    private func selectFromPanel(_ window: SwitcherWindow) {
        guard isOpen, let context else { return }
        close(reason: "committed")
        Task {
            let ok = (try? await context.performBackground {
                WindowActivator.activate(window: window)
            }) ?? false
            self.settingsModel?.append("activate \(window.appName): \(ok)")
        }
    }

    private func commit() {
        guard isOpen else { return }
        let target = windows.indices.contains(selected) ? windows[selected] : nil
        close(reason: "committed")
        guard let target, let context else { return }

        Task {
            let ok = (try? await context.performBackground {
                WindowActivator.activate(window: target)
            }) ?? false
            self.settingsModel?.append("activate \(target.appName): \(ok)")
        }
    }

    private func close(reason: String) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        openFlag.value = false
        isOpen = false
        windows = []
        selected = 0
        panel.hide()
        if reason != "deactivate", reason != "committed" {
            settingsModel?.append("closed: \(reason)")
        }
    }

    private func noteActivation(pid: pid_t) {
        appOrder.removeAll { $0 == pid }
        appOrder.insert(pid, at: 0)
        if appOrder.count > 32 {
            appOrder.removeLast(appOrder.count - 32)
        }
    }

    // MARK: - 缩略图

    private func loadThumbnailsIfNeeded(session: Int) {
        guard let model = settingsModel, let context else { return }
        guard model.mode == .thumbnails else { return }

        guard context.permissions.status(of: .screenCapture) else {
            model.append("thumbnails need screen recording; falling back to icons")
            return
        }
        guard !thumbnails.isCoolingDown else {
            model.append("thumbnail capture cooling down; icons only")
            return
        }

        let targets = Array(windows.prefix(max(1, model.maxThumbnails)))

        // 先贴缓存：同一批窗口再次打开时无需重新截图。
        for window in targets {
            if let cached = thumbnails.cached(window.windowID) {
                panel.setThumbnail(windowID: window.windowID, image: cached)
            }
        }

        thumbnailTask = Task { [weak self] in
            for window in targets {
                guard !Task.isCancelled, let self, self.thumbnails.currentGeneration == session else { return }
                guard self.thumbnails.shouldAttempt(window.windowID) else { continue }
                if let image = await self.thumbnails.capture(windowID: window.windowID, session: session) {
                    self.panel.setThumbnail(windowID: window.windowID, image: image)
                }
            }
        }
    }

    // MARK: - 权限（设置页用）

    var screenCaptureGranted: Bool {
        context?.permissions.status(of: .screenCapture) ?? false
    }

    func requestScreenCapture() {
        context?.permissions.request(.screenCapture)
        settingsModel?.append("requested screen recording")
    }

    // MARK: - 排序

    /// 最近激活的应用在前；同一应用内保持 CGWindowList 的前后顺序。
    private static func sorted(_ windows: [SwitcherWindow], by order: [pid_t]) -> [SwitcherWindow] {
        var rank: [pid_t: Int] = [:]
        for (index, pid) in order.enumerated() {
            rank[pid] = index
        }
        return windows.enumerated()
            .sorted { lhs, rhs in
                let left = rank[lhs.element.pid] ?? Int.max
                let right = rank[rhs.element.pid] ?? Int.max
                if left == right { return lhs.offset < rhs.offset }
                return left < right
            }
            .map(\.element)
    }
}

enum WindowSwitcherStrings {
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
