import AppKit
import Foundation
import PluginAPI
import PluginSupport
import SwiftUI

/// 基座探针插件：不是产品功能，仅 Debug 构建注册。
///
/// 五组探针与五项基座能力一一对应，另有两组「违规对照」开关，
/// 用于现场验证基座的强制清理与线程契约（M1）。
@MainActor
public final class HarnessPlugin: FeaturePlugin {
    public static let manifest = PluginManifest(
        id: "com.gaelthas.plugin.harness",
        version: "1.0.0",
        minHostVersion: "1.0.0",
        title: "harness.title",
        summary: "harness.summary",
        iconSystemName: "waveform.path.ecg",
        // 点击/指针走 .accessibility，键盘 tap 走 .inputMonitoring（§5.4）。
        requiredCapabilities: [.accessibility, .inputMonitoring],
        optionalCapabilities: [.screenCapture],
        resourceBundle: .module
    )

    private var context: PluginContext?
    private var clickSub: Subscription?
    private var keySub: Subscription?
    private var pointerSub: Subscription?
    private var interruptionSub: Subscription?

    private(set) var settingsModel: HarnessSettingsModel?

    /// 探针订阅的键码集合：覆盖主键盘区，便于任意按键都能看到事件。
    private static let probeKeyCodes: Set<Int64> = Set((0...50).map(Int64.init))

    public init() {}

    // MARK: - 生命周期

    public func activate(context: PluginContext) throws {
        self.context = context
        if settingsModel == nil {
            settingsModel = HarnessSettingsModel(store: context.store)
        }
        guard let model = settingsModel else { return }

        interruptionSub = context.inputBus.subscribeToInterruptions { [weak self] interruption in
            let source = interruption.source == .keyboard ? "keyboard" : "pointer"
            let reason: String
            switch interruption.reason {
            case .timeoutDisabled: reason = "timeoutDisabled"
            case .permissionRevoked: reason = "permissionRevoked"
            case .tapCreationFailed: reason = "tapCreationFailed"
            }
            self?.settingsModel?.append("interruption \(source)/\(reason) recovered=\(interruption.recovered)")
        }

        clickSub = context.inputBus.subscribeToClick { [weak self] click in
            self?.handleClick(click)
        }

        pointerSub = context.inputBus.subscribeToPointerMove { [weak self] point in
            guard let self, let model = self.settingsModel, model.pointerProbeEnabled else { return }
            model.append(String(format: "pointer %.0f,%.0f", point.x, point.y))
        }

        // 阶段二的闭包只能读 AtomicFlag：显式捕获，避免隐式捕获 @MainActor 的 self。
        keySub = context.inputBus.subscribeToKey(
            KeyFilter(keyCodes: Self.probeKeyCodes),
            syncIntercept: { [flag = model.consumeFlag] _ in
                flag.value ? .consume : .passthrough
            },
            handler: { [weak self] event in
                guard let self, let model = self.settingsModel, model.keyProbeEnabled else { return }
                model.append("key keyCode=\(event.keyCode) flags=\(event.flags.rawValue) repeat=\(event.isRepeat)")
            }
        )

        try context.hotKeys.register(model.spec) { [weak self] in
            self?.settingsModel?.append("hotkey fired \(HotKeyRecorder.display(self?.settingsModel?.spec ?? .harnessDefault))")
        }
    }

    public func deactivate() {
        // 违规对照：开关打开时故意不取消订阅，用来验证「基座强制清理后 tap 引用计数仍归零」。
        if settingsModel?.skipCancelOnDeactivate != true {
            clickSub?.cancel()
            keySub?.cancel()
            pointerSub?.cancel()
            interruptionSub?.cancel()
        }
        clickSub = nil
        keySub = nil
        pointerSub = nil
        interruptionSub = nil
        context = nil
        // 注意：不销毁 settingsModel —— 它是实例状态，重新启用后设置页要继续读同一份。
    }

    public func makeSettingsView() -> AnyView {
        guard settingsModel != nil else {
            return AnyView(Text(verbatim: HarnessStrings.t("harness.inactive")))
        }
        return AnyView(HarnessSettingsView(plugin: self))
    }

    // MARK: - 探针动作

    private func handleClick(_ click: ClickContext) {
        guard let model = settingsModel, model.clickProbeEnabled else { return }

        let app = click.frontmostPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        let button: String
        switch click.button {
        case .left: button = "left"
        case .right: button = "right"
        case .other: button = "other"
        }

        var suffix = ""
        if model.blockingAXOnMainThread, let pid = click.frontmostPID {
            // 违规对照：主线程直接发起同步 AX 调用。目标应用卡住时整个 UI（含菜单栏）会冻结。
            let started = ProcessInfo.processInfo.systemUptime
            _ = AXQuery.windows(of: pid).count
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            suffix = String(format: " blockingAX=%.1fms", elapsed)
        }

        model.append(
            String(
                format: "click %@ x%d @ %.0f,%.0f frontmost=%@%@",
                button,
                click.clickCount,
                click.location.x,
                click.location.y,
                app?.localizedName ?? "-",
                suffix
            )
        )
    }

    func updateHotKey(_ spec: HotKeySpec) throws {
        guard let context else { throw HotKeyError.invalid("inactive") }
        try context.hotKeys.update(spec)
        settingsModel?.spec = spec
        settingsModel?.append("hotkey updated \(HotKeyRecorder.display(spec))")
    }

    func availability(of spec: HotKeySpec) -> HotKeyAvailability {
        context?.hotKeys.availability(of: spec) ?? .invalid(reason: "inactive")
    }

    func postBurst() {
        guard let context else { return }
        for index in 1...3 {
            context.notifier.post(
                PluginNotification(
                    id: "burst",
                    title: HarnessStrings.t("probe.notification.burst"),
                    body: "#\(index)",
                    priority: .low,
                    coalescingKey: "burst"
                )
            )
        }
        settingsModel?.append("posted 3 notifications (throttle should drop 2)")
    }

    func postDistinct() {
        guard let context else { return }
        context.notifier.post(
            PluginNotification(
                id: "distinct-\(Int(Date().timeIntervalSince1970))",
                title: HarnessStrings.t("probe.notification.title"),
                body: HarnessStrings.t("probe.notification.body"),
                priority: .normal
            )
        )
        settingsModel?.append("posted 1 notification")
    }

    func requestNotificationAuthorization() {
        guard let context, let model = settingsModel else { return }
        Task {
            let granted = await context.notifier.requestAuthorization()
            model.append("notification authorization granted=\(granted)")
        }
    }

    func captureWindow() async {
        guard let context, let model = settingsModel, !model.isCapturing else { return }
        model.isCapturing = true
        defer { model.isCapturing = false }

        guard context.permissions.status(of: .screenCapture) else {
            let summary = (try? await context.performBackground { CaptureProbe.degradedSummary() }) ?? nil
            model.setCaptureStatus("\(HarnessStrings.t("probe.capture.noPermission")) \(summary ?? "")")
            return
        }

        do {
            let result = try await CaptureProbe.captureFirstOnScreenWindow()
            model.setCaptureImage(result.image)
            model.setCaptureStatus(result.summary)
        } catch {
            model.setCaptureStatus("\(HarnessStrings.t("probe.capture.failed")) \(error.localizedDescription)")
        }
    }
}
