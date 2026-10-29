import AppKit
import Foundation
import PluginAPI
import SwiftUI

/// Dock 动作插件：把 Dock2Min 的「点击当前前台应用的图标 → 最小化」与
/// 「修饰键 + 1~9 / ↓ 操作 Dock 应用」合并为一个插件。
///
/// 两者共用同一套 Dock 命中判定、应用名单与 AX 最小化能力，拆成两个插件只会重复实现。
@MainActor
public final class DockActionsPlugin: FeaturePlugin {
    public static let manifest = PluginManifest(
        id: "com.gaelthas.plugin.dock-actions",
        version: "1.0.0",
        minHostVersion: "1.0.0",
        title: "dockActions.title",
        summary: "dockActions.summary",
        iconSystemName: "dock.rectangle",
        // 点击订阅走鼠标 tap、最小化走 AX，两者都由「辅助功能」门控（§5.4）。
        requiredCapabilities: [.accessibility],
        optionalCapabilities: [],
        resourceBundle: .module
    )

    private var context: PluginContext?
    private var clickSub: Subscription?
    private var pointerSub: Subscription?
    private var interruptionSub: Subscription?

    private(set) var settingsModel: DockActionsModel?

    /// 点击前的前台应用是否有可见窗口。点击会改变世界，必须提前取（§4.4.3）。
    private var snapshot: (pid: pid_t, hasVisibleWindow: Bool, at: TimeInterval)?
    private var lastProbeTime: TimeInterval = 0
    private var lastActionTime: TimeInterval = 0

    /// 与 Dock2Min 一致的 0.8s 去抖：避免 Dock 动画期间重复触发。
    private let actionCooldown: TimeInterval = 0.8

    public init() {}

    // MARK: - 生命周期

    public func activate(context: PluginContext) throws {
        self.context = context
        if settingsModel == nil {
            settingsModel = DockActionsModel(store: context.store)
        }

        interruptionSub = context.inputBus.subscribeToInterruptions { [weak self] _ in
            // 输入源失效后缓存的前台状态已不可信。
            self?.snapshot = nil
        }

        clickSub = context.inputBus.subscribeToClick { [weak self] click in
            self?.handleClick(click)
        }

        pointerSub = context.inputBus.subscribeToPointerMove { [weak self] point in
            self?.prefetchAround(point)
        }

        registerShortcuts()
    }

    public func deactivate() {
        clickSub?.cancel()
        pointerSub?.cancel()
        interruptionSub?.cancel()
        clickSub = nil
        pointerSub = nil
        interruptionSub = nil
        snapshot = nil
        context?.hotKeys.unregister()  // 基座也会清理，这里显式做一次
        context = nil
    }

    public func makeSettingsView() -> AnyView {
        guard settingsModel != nil else {
            return AnyView(Text(verbatim: DockActionsStrings.t("plugin.inactive")))
        }
        return AnyView(DockActionsSettingsView(plugin: self))
    }

    // MARK: - 点击最小化

    private func handleClick(_ click: ClickContext) {
        guard let model = settingsModel, model.clickToMinimize else { return }
        guard click.button == .left, click.clickCount == 1 else { return }
        guard let pid = click.frontmostPID else { return }
        guard DockGeometry.isNearDockBand(click.location) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActionTime > actionCooldown else { return }

        guard let app = NSRunningApplication(processIdentifier: pid),
              // helper / XPC 子进程占住 frontmost 时不做判定，避免「点了没反应」或最小化错对象。
              app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              let appName = app.localizedName else { return }
        guard model.allows(bundleID: bundleID) else { return }

        // 点击前已是「全部最小化」状态：这次点击会让系统原生地恢复窗口，不该再最小化一次。
        if let snapshot, snapshot.pid == pid, now - snapshot.at < 3, !snapshot.hasVisibleWindow {
            model.append("skip \(appName): no visible window before click")
            return
        }

        let point = click.location
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        guard let context else { return }

        Task { [weak self] in
            guard let self else { return }
            let hit = try? await context.performBackground {
                DockIconResolver.icon(at: point, dockPID: dockPID)
            }
            guard let hit, hit.isDock, let title = hit.title else { return }
            guard Self.namesMatch(title, appName) else { return }
            self.minimize(pid: pid, label: appName)
        }
    }

    /// 指针靠近 Dock 时预取「前台应用是否有可见窗口」，把跨进程查询挪到点击发生之前。
    private func prefetchAround(_ point: CGPoint) {
        guard let model = settingsModel, model.clickToMinimize else { return }
        guard DockGeometry.isNearDockBand(point) else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProbeTime >= 0.3 else { return }
        lastProbeTime = now

        guard let context, let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier

        Task { [weak self] in
            let visible = try? await context.performBackground {
                AXWindowOps.hasVisibleWindow(pid: pid)
            }
            guard let self, let visible else { return }
            self.snapshot = (pid, visible, ProcessInfo.processInfo.systemUptime)
        }
    }

    private func minimize(pid: pid_t, label: String) {
        guard let context, let model = settingsModel else { return }
        lastActionTime = ProcessInfo.processInfo.systemUptime
        let exitFullScreen = model.exitFullScreenFirst

        Task {
            let count = (try? await context.performBackground {
                AXWindowOps.minimizeAllWindows(pid: pid, exitFullScreenFirst: exitFullScreen)
            }) ?? 0
            model.append("minimized \(count) window(s) of \(label)")
            self.snapshot = nil
        }
    }

    // MARK: - Dock 快捷键

    private func registerShortcuts() {
        guard let context, let model = settingsModel else { return }
        context.hotKeys.unregister()
        model.setError(nil)
        guard model.shortcutsEnabled else { return }

        var failures: [String] = []
        let modifiers = model.modifierPreset.modifiers

        // 物理键位 1~9（kVK_ANSI_1..9），顺序不连续是键盘布局的历史原因。
        let digits: [(keyCode: UInt32, slot: Int)] = [
            (0x12, 1), (0x13, 2), (0x14, 3), (0x15, 4), (0x17, 5),
            (0x16, 6), (0x1A, 7), (0x1C, 8), (0x19, 9),
        ]

        for item in digits {
            let spec = HotKeySpec(keyCode: item.keyCode, modifiers: modifiers)
            do {
                try context.hotKeys.register(spec) { [weak self] in
                    self?.openDockSlot(item.slot)
                }
            } catch {
                failures.append("\(model.modifierPreset.displayText)\(item.slot) \(describe(error))")
            }
        }

        let minimizeSpec = HotKeySpec(keyCode: 0x7D, modifiers: modifiers)  // ↓
        do {
            try context.hotKeys.register(minimizeSpec) { [weak self] in
                self?.minimizeFrontmost()
            }
        } catch {
            failures.append("\(model.modifierPreset.displayText)↓ \(describe(error))")
        }

        if !failures.isEmpty {
            model.setError("\(DockActionsStrings.t("shortcuts.conflict")) \(failures.joined(separator: "，"))")
        }
        model.append("registered \(digits.count + 1) hot keys with \(model.modifierPreset.displayText)")
    }

    func updateShortcutPreset(_ preset: DockActionsModel.ModifierPreset) {
        guard let model = settingsModel, model.modifierPreset != preset else { return }
        let previous = model.modifierPreset
        model.modifierPreset = preset
        registerShortcuts()

        // 全部注册失败时回滚，避免「设置显示已改但一个键都不生效」。
        if model.lastError != nil {
            model.modifierPreset = previous
            registerShortcuts()
        }
    }

    func setShortcutsEnabled(_ enabled: Bool) {
        guard let model = settingsModel, model.shortcutsEnabled != enabled else { return }
        model.shortcutsEnabled = enabled
        registerShortcuts()
    }

    func setClickToMinimize(_ enabled: Bool) {
        settingsModel?.clickToMinimize = enabled
    }

    private func openDockSlot(_ index: Int) {
        let apps = DockAppOrder.apps()
        guard apps.indices.contains(index - 1) else {
            settingsModel?.append("dock slot \(index) is empty")
            return
        }
        let slot = apps[index - 1]
        let front = NSWorkspace.shared.frontmostApplication

        if let bundleID = slot.bundleID, front?.bundleIdentifier == bundleID, let pid = front?.processIdentifier {
            minimize(pid: pid, label: slot.name)
            return
        }

        if let bundleID = slot.bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           !running.isTerminated {
            activate(bundleID: bundleID, label: slot.name)
            return
        }

        guard let url = slot.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.settingsModel?.append("open \(slot.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func activate(bundleID: String, label: String) {
        guard let context else { return }
        Task {
            let ok = (try? await context.performBackground {
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
                    return false
                }
                app.unhide()
                return app.activate()
            }) ?? false
            settingsModel?.append("activate \(label): \(ok)")
        }
    }

    private func minimizeFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        minimize(pid: front.processIdentifier, label: front.localizedName ?? "-")
    }

    // MARK: - 工具

    /// Dock 显示的标签是 `file-label`，与 `localizedName` 可能不完全一致（如被重命名）。
    static func namesMatch(_ dockTitle: String, _ appName: String) -> Bool {
        let a = normalize(dockTitle)
        let b = normalize(appName)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".app", with: "")
            .lowercased()
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let HotKeyError.conflict(ownerTitle): return "conflict:\(ownerTitle)"
        case HotKeyError.reservedBySystem: return "reserved"
        case let HotKeyError.invalid(reason): return "invalid:\(reason)"
        default: return "error"
        }
    }
}
