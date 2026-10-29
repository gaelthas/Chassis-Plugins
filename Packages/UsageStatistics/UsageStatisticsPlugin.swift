import AppKit
import Foundation
import PluginAPI
import SwiftUI

/// 应用使用时长统计：唯一一个「零权限」的业务插件——不读窗口、不截图、不监听输入，
/// 只订阅 `NSWorkspace` 的激活与休眠通知。
@MainActor
public final class UsageStatisticsPlugin: FeaturePlugin {
    public static let manifest = PluginManifest(
        id: "com.gaelthas.plugin.usage-statistics",
        version: "1.0.0",
        minHostVersion: "1.0.0",
        title: "usage.title",
        summary: "usage.summary",
        iconSystemName: "chart.bar.xaxis",
        requiredCapabilities: [],
        optionalCapabilities: [],
        resourceBundle: resourceBundle
    )

    private var context: PluginContext?
    private var observers: [NSObjectProtocol] = []
    private var flushTask: Task<Void, Never>?

    private(set) var settingsModel: UsageStatisticsModel?

    /// 结算周期：进程被强杀时最多丢 20 秒。
    private let flushInterval: TimeInterval = 20

    public init() {}

    // MARK: - 生命周期

    public func activate(context: PluginContext) throws {
        self.context = context
        if settingsModel == nil {
            settingsModel = UsageStatisticsModel(store: context.store)
        }
        guard let model = settingsModel else { return }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else {
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleActivation(pid: pid) }
            }
        })

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.pause(at: Date()) }
                }
            })
        }

        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.resume(at: Date()) }
                }
            })
        }

        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.flushInterval ?? 20))
                guard let self else { return }
                self.settingsModel?.flush(at: Date())
            }
        }

        resume(at: Date())
        model.refresh(at: Date())
    }

    public func deactivate() {
        settingsModel?.endSession(at: Date())
        settingsModel?.refresh(at: Date())

        flushTask?.cancel()
        flushTask = nil

        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        context = nil
    }

    public func makeSettingsView() -> AnyView {
        guard settingsModel != nil else {
            return AnyView(Text(verbatim: UsageStrings.t("plugin.inactive")))
        }
        return AnyView(UsageStatisticsSettingsView(plugin: self))
    }

    // MARK: - 会话

    private func handleActivation(pid: pid_t) {
        guard let model = settingsModel, model.enabled else { return }
        guard let app = Self.regularApplication(pid: pid), let bundleID = app.bundleIdentifier else { return }

        // 不统计基座自己：设置窗口在前台时不该计入任何应用。
        guard bundleID != Bundle.main.bundleIdentifier else {
            model.endSession(at: Date())
            return
        }
        model.beginSession(bundleID: bundleID, name: app.localizedName ?? bundleID, at: Date())
    }

    private func pause(at date: Date) {
        settingsModel?.endSession(at: date)
        settingsModel?.refresh(at: date)
    }

    private func resume(at date: Date) {
        guard let model = settingsModel, model.enabled else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        model.beginSession(bundleID: bundleID, name: front.localizedName ?? bundleID, at: date)
    }

    /// helper 进程（如浏览器渲染进程）不该单独计数，归一到它的常规应用。
    private static func regularApplication(pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if app.activationPolicy == .regular { return app }

        if let url = app.bundleURL?.standardizedFileURL,
           let owner = NSWorkspace.shared.runningApplications.first(where: {
               $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL == url
           }) {
            return owner
        }
        if let bundleID = app.bundleIdentifier,
           let owner = NSWorkspace.shared.runningApplications.first(where: {
               $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
           }) {
            return owner
        }
        return nil
    }
}

enum UsageStrings {
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
