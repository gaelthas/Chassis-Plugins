import AppKit
import Foundation
import PluginAPI
import SwiftUI

/// 悬停 Dock 图标时，在图标上方弹出该应用的窗口预览网格。
///
/// 与 Dock2Min 一致的细节：2pt 抖动阈值、悬停延时、0.3s 离开延时、缩略图治理。
/// 已知边界：无法与「窗口切换器」插件共享会话状态（插件互不可见），
/// 若两者同时打开，⌥Tab 期间指针停在 Dock 上时预览可能仍可见，移动即消失。
@MainActor
public final class DockHoverPreviewPlugin: FeaturePlugin {
    public static let manifest = PluginManifest(
        id: "com.gaelthas.plugin.dock-hover-preview",
        version: "1.0.0",
        minHostVersion: "1.0.0",
        title: "dockHover.title",
        summary: "dockHover.summary",
        iconSystemName: "dock.arrow.up.rectangle",
        // 指针移动监听与 Dock 命中判定都由辅助功能门控。
        requiredCapabilities: [.accessibility],
        optionalCapabilities: [.screenCapture],
        resourceBundle: .module
    )

    private var context: PluginContext?
    private var pointerSub: Subscription?
    private var interruptionSub: Subscription?
    private var activationObserver: NSObjectProtocol?

    private(set) var settingsModel: DockHoverModel?
    private let panel = HoverPanel()
    private let thumbnails = ThumbnailGovernor()

    private struct Candidate {
        let key: String
        let point: CGPoint
        let since: TimeInterval
        let frame: CGRect?
    }

    private var candidate: Candidate?
    private var currentKey: String?
    private var lastProbe: TimeInterval = 0
    private var showTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?

    private let dismissDelay: TimeInterval = 0.3
    private let probeInterval: TimeInterval = 0.12
    private let jitterTolerance: CGFloat = 3

    public init() {}

    // MARK: - 生命周期

    public func activate(context: PluginContext) throws {
        self.context = context
        if settingsModel == nil {
            settingsModel = DockHoverModel(store: context.store)
        }
        guard settingsModel != nil else { return }

        panel.onSelect = { [weak self] window in
            self?.select(window)
        }

        pointerSub = context.inputBus.subscribeToPointerMove { [weak self] point in
            self?.handleMove(point)
        }

        interruptionSub = context.inputBus.subscribeToInterruptions { [weak self] _ in
            self?.dismiss(reason: "input interrupted")
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 用户点到别处去了，预览没有继续存在的理由。
                    guard let self, self.panel.isVisible else { return }
                    self.dismiss(reason: "app activated")
                }
            }
        }
    }

    public func deactivate() {
        pointerSub?.cancel()
        interruptionSub?.cancel()
        pointerSub = nil
        interruptionSub = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil

        showTask?.cancel()
        thumbnailTask?.cancel()
        dismissTask?.cancel()
        showTask = nil
        thumbnailTask = nil
        dismissTask = nil
        dismiss(reason: "deactivate", silent: true)
        context = nil
    }

    public func makeSettingsView() -> AnyView {
        guard settingsModel != nil else {
            return AnyView(Text(verbatim: DockHoverStrings.t("plugin.inactive")))
        }
        return AnyView(DockHoverPreviewSettingsView(plugin: self))
    }

    // MARK: - 悬停

    private func handleMove(_ point: CGPoint) {
        guard let model = settingsModel, model.enabled else { return }

        // 指针移进预览面板本身：保持显示，否则点不到卡片。
        let mouse = NSEvent.mouseLocation
        if let frame = panel.frameInAppKit, frame.contains(mouse) {
            dismissTask?.cancel()
            dismissTask = nil
            return
        }

        guard DockGeometry.isNearDockBand(point) else {
            scheduleDismiss()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProbe >= probeInterval else { return }
        lastProbe = now

        guard let context else { return }
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0

        Task { [weak self] in
            let hit = (try? await context.performBackground {
                DockIconResolver.icon(at: point, dockPID: dockPID)
            }) ?? DockIconHit(isDock: false, title: nil, frame: nil)
            guard let self, let model = self.settingsModel, model.enabled else { return }

            guard hit.isDock, let title = hit.title else {
                self.clearCandidate()
                self.scheduleDismiss()
                return
            }

            if self.currentKey == title, self.panel.isVisible {
                self.dismissTask?.cancel()
                self.dismissTask = nil
                return
            }

            // 同一图标内的小幅抖动不重置计时。
            if let candidate = self.candidate, candidate.key == title,
               hypot(point.x - candidate.point.x, point.y - candidate.point.y) < self.jitterTolerance {
                return
            }

            self.candidate = Candidate(key: title, point: point, since: now, frame: hit.frame)
            self.scheduleShow(after: model.hoverDelay)
        }
    }

    private func scheduleShow(after delay: TimeInterval) {
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, delay)))
            guard !Task.isCancelled, let self, let candidate = self.candidate else { return }
            self.show(key: candidate.key, frame: candidate.frame)
        }
    }

    private func show(key: String, frame: CGRect?) {
        guard let context, let model = settingsModel else { return }
        guard let anchor = frame else {
            model.append("no icon frame for \(key)")
            return
        }
        guard let app = AppNameMatcher.app(matchingTitle: key) else {
            model.append("no running app for \(key)")
            return
        }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? key

        Task { [weak self] in
            let windows = (try? await context.performBackground {
                HoverWindowCatalog.windows(for: pid, appName: appName)
            }) ?? []

            guard let self, let model = self.settingsModel else { return }
            guard !windows.isEmpty else {
                model.append("\(appName): no windows")
                return
            }

            let limited = Array(windows.prefix(max(1, model.maxWindows)))
            self.currentKey = key
            self.panel.show(
                windows: limited,
                appName: appName,
                appIcon: app.icon,
                showTitles: model.showWindowTitles,
                anchor: anchor
            )
            model.append("show \(appName): \(limited.count) window(s)")
            self.loadThumbnails(for: limited, session: self.thumbnails.beginSession())
        }
    }

    private func loadThumbnails(for windows: [HoverWindow], session: Int) {
        guard let model = settingsModel, let context else { return }
        guard model.mode == .thumbnails else { return }
        guard context.permissions.status(of: .screenCapture) else {
            model.append("thumbnails need screen recording; icons only")
            return
        }
        guard !thumbnails.isCoolingDown else {
            model.append("thumbnail capture cooling down")
            return
        }

        for window in windows {
            if let cached = thumbnails.cached(window.windowID) {
                panel.setThumbnail(windowID: window.windowID, image: cached)
            }
        }

        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            for window in windows {
                guard !Task.isCancelled, let self, self.thumbnails.currentGeneration == session else { return }
                guard self.thumbnails.shouldAttempt(window.windowID) else { continue }
                if let image = await self.thumbnails.capture(windowID: window.windowID, session: session) {
                    self.panel.setThumbnail(windowID: window.windowID, image: image)
                }
            }
        }
    }

    private func scheduleDismiss() {
        guard panel.isVisible else {
            clearCandidate()
            return
        }
        guard dismissTask == nil else { return }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled, let self else { return }
            let mouse = NSEvent.mouseLocation
            if let frame = self.panel.frameInAppKit, frame.contains(mouse) { return }
            self.dismiss(reason: "pointer left dock")
        }
    }

    private func dismiss(reason: String, silent: Bool = false) {
        showTask?.cancel()
        thumbnailTask?.cancel()
        dismissTask?.cancel()
        showTask = nil
        thumbnailTask = nil
        dismissTask = nil
        candidate = nil
        let wasVisible = panel.isVisible
        panel.hide()
        currentKey = nil
        thumbnails.beginSession()
        if wasVisible, !silent {
            settingsModel?.append("hide: \(reason)")
        }
    }

    private func clearCandidate() {
        candidate = nil
        showTask?.cancel()
        showTask = nil
    }

    // MARK: - 选择窗口

    private func select(_ window: HoverWindow) {
        guard let context else { return }
        dismiss(reason: "selected", silent: true)
        Task {
            let ok = (try? await context.performBackground {
                WindowActivator.activate(window: window)
            }) ?? false
            self.settingsModel?.append("activate \(window.appName): \(ok)")
        }
    }

    // MARK: - 设置页用

    var screenCaptureGranted: Bool {
        context?.permissions.status(of: .screenCapture) ?? false
    }

    func requestScreenCapture() {
        context?.permissions.request(.screenCapture)
        settingsModel?.append("requested screen recording")
    }
}

enum DockHoverStrings {
    static func t(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }
}
