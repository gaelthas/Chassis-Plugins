import AppKit
import Foundation
import PluginAPI
import SwiftUI

/// 长按 ⌘Q 才退出前台应用。
///
/// 关键点：⌘Q 必须**始终**被吞掉——否则第一次按下就已经退出，长按无从谈起。
/// 吞键发生在 tap 线程（`syncIntercept`），是否启用由 `AtomicFlag` 传递。
@MainActor
public final class SlowQuitPlugin: FeaturePlugin {
    public static let manifest = PluginManifest(
        id: "com.gaelthas.plugin.slow-quit",
        version: "1.0.0",
        minHostVersion: "1.0.0",
        title: "slowQuit.title",
        summary: "slowQuit.summary",
        iconSystemName: "hourglass",
        // 只需要键盘 tap；终止应用走 NSRunningApplication，不需要 AX。
        requiredCapabilities: [.inputMonitoring],
        optionalCapabilities: [],
        resourceBundle: resourceBundle
    )

    private var context: PluginContext?
    private var keySub: Subscription?
    private var interruptionSub: Subscription?
    private var workspaceObserver: NSObjectProtocol?

    private(set) var settingsModel: SlowQuitModel?
    private let hud = SlowQuitHUD()

    private var sessionStart: TimeInterval?
    private var sessionThreshold: Double = 0
    private var tickTask: Task<Void, Never>?

    /// ⌘Q 的物理键位。
    private static let qKeyCode: Int64 = 0x0C

    public init() {}

    // MARK: - 生命周期

    public func activate(context: PluginContext) throws {
        self.context = context
        if settingsModel == nil {
            settingsModel = SlowQuitModel(store: context.store)
        }
        guard let model = settingsModel else { return }

        keySub = context.inputBus.subscribeToKey(
            KeyFilter(keyCodes: [Self.qKeyCode], requiredFlags: .maskCommand),
            syncIntercept: { [flag = model.consumeFlag] _ in
                // tap 线程：只读原子标量。松开也要吞，避免漏给系统。
                flag.value ? .consume : .passthrough
            },
            handler: { [weak self] event in
                self?.handle(event)
            }
        )

        interruptionSub = context.inputBus.subscribeToInterruptions { [weak self] interruption in
            guard let self, interruption.source == .keyboard else { return }
            self.cancelSession(reason: "input interrupted")
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelSession(reason: "app switched")
            }
        }
    }

    public func deactivate() {
        keySub?.cancel()
        interruptionSub?.cancel()
        keySub = nil
        interruptionSub = nil

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        workspaceObserver = nil

        tickTask?.cancel()
        tickTask = nil
        sessionStart = nil
        hud.hide()
        settingsModel?.consumeFlag.value = false
        context = nil
    }

    public func makeSettingsView() -> AnyView {
        guard settingsModel != nil else {
            return AnyView(Text(verbatim: SlowQuitStrings.t("plugin.inactive")))
        }
        return AnyView(SlowQuitSettingsView(plugin: self))
    }

    // MARK: - 按键处理

    private func handle(_ event: KeyEvent) {
        guard let model = settingsModel, model.enabled else { return }

        switch event.kind {
        case .flagsChanged:
            break
        case .keyDown:
            guard !event.isRepeat else { return }
            startSession()
        case .keyUp:
            releaseSession()
        }
    }

    private func startSession() {
        guard sessionStart == nil, let model = settingsModel else { return }

        let start = ProcessInfo.processInfo.systemUptime
        sessionStart = start
        sessionThreshold = max(0.5, min(5.0, model.threshold))

        if model.showProgressHUD {
            // Dock2Min 的 HUD 显示「即将被退出的应用图标」，从 bundle 兜底读取；
            // 前台可能是 helper，先归一成真正会被退出的应用。
            let target = SlowQuitTargetResolver.resolve(frontmost: NSWorkspace.shared.frontmostApplication)
            let icon = target?.icon
                ?? target?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            hud.show(icon: icon)
        }
        model.append(String(format: "hold started (%.1fs)", sessionThreshold))

        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                guard let self, let start = self.sessionStart else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                self.hud.update(progress: min(1, elapsed / self.sessionThreshold))
                if elapsed >= self.sessionThreshold {
                    self.commitQuit()
                    return
                }
            }
        }
    }

    private func releaseSession() {
        guard let start = sessionStart else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        endSession()
        settingsModel?.append(String(format: "released after %.2fs → cancelled", elapsed))
    }

    private func commitQuit() {
        guard let model = settingsModel else { return }
        // Steam 之类的应用由 helper 占住 frontmost：归一后再退，否则只会杀掉 helper。
        let target = SlowQuitTargetResolver.resolve(frontmost: NSWorkspace.shared.frontmostApplication)
        endSession()

        guard let target, target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            // 前台是基座自己：绝不 terminate 自己。
            model.append("skip quit: frontmost is this app")
            return
        }
        let name = target.localizedName ?? "-"
        let terminated = target.terminate()
        model.append("quit \(name): \(terminated)")
    }

    private func cancelSession(reason: String) {
        guard sessionStart != nil else { return }
        endSession()
        settingsModel?.append("cancelled: \(reason)")
    }

    private func endSession() {
        tickTask?.cancel()
        tickTask = nil
        sessionStart = nil
        hud.hide()
    }
}
