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
        version: "1.0.5",
        minHostVersion: "1.0.0",
        title: "windowSwitcher.title",
        summary: "windowSwitcher.summary",
        iconSystemName: "rectangle.on.rectangle",
        // 键盘 tap → 输入监控（必需）。
        // 辅助功能只影响「精确置顶到某个窗口 / 枚举隐藏与最小化窗口」；
        // 屏上窗口走 CGWindowList，没有辅助功能也能切换，因此改为可选，
        // 避免仅因缺辅助功能就整个插件不可用（表现为 ⌥Tab 没反应）。
        requiredCapabilities: [.inputMonitoring],
        optionalCapabilities: [.accessibility, .screenCapture],
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

            guard let self, self.isOpen else { return }

            // 枚举为空也把面板显示出来（Dock2Min 的「No Windows」空态）：
            // 否则用户只会看到「按了没反应」，分不清是插件没生效还是真的没有窗口。
            self.windows = Self.sorted(list, by: knownOrder)
            // 与 Dock2Min/系统 Alt-Tab 一致：默认选中「下一个窗口」而不是当前窗口，
            // 否则按一次 ⌥Tab 松手只是在原地激活自己，看起来像「没反应」。
            let initial = self.windows.count > 1 ? 1 : 0
            self.selected = initial
            let session = self.thumbnails.beginSession()
            let available = self.thumbnails.isAvailable
            self.panel.show(
                windows: self.windows,
                selected: initial,
                mode: model.mode,
                thumbnailsAvailable: available,
                showTitles: model.showWindowTitles,
                onSelect: { [weak self] window in
                    // 点击卡片立即切换：与 Dock2Min 的 mouseHover 触发源行为一致。
                    self?.selectFromPanel(window)
                }
            )
            model.append("opened with \(self.windows.count) window(s)")
            guard !self.windows.isEmpty else { return }

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

        // 授权 / 冷却状态一律由 governor 判定（它会先做静默 preflight）：
        // 不可用时面板已经退回图标模式，这里只负责记一条原因。
        guard thumbnails.isAvailable else {
            model.append(
                context.permissions.status(of: .screenCapture)
                    ? "thumbnail capture cooling down; icons only"
                    : "thumbnails need screen recording; icons only"
            )
            return
        }

        // 屏上窗口优先：最小化/隐藏应用的窗口没有 backing surface，抓取更容易失败。
        let ordered = windows.filter(\.isOnScreen) + windows.filter { !$0.isOnScreen }
        let targets = Array(ordered.prefix(max(1, model.maxThumbnails)))

        // 先贴缓存：同一批窗口再次打开时无需重新截图。
        for window in targets {
            if let cached = thumbnails.cached(window.windowID) {
                panel.setThumbnail(windowID: window.windowID, image: cached)
            }
        }

        // 一次枚举批量抓取，逐张回流；旧会话的结果由代际号丢弃。
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            await self.thumbnails.captureAll(targets.map(\.windowID), session: session) { [weak self] windowID, image in
                self?.panel.setThumbnail(windowID: windowID, image: image)
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
