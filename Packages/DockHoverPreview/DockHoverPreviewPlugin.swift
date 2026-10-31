import AppKit
import Foundation
import PluginAPI
import SwiftUI

/// 悬停 Dock 图标时，在图标上方弹出该应用的窗口预览网格。
///
/// 与 Dock2Min 一致的细节：抖动阈值、悬停延时、0.3s 离开延时、缩略图治理。
/// 命中判定比 Dock2Min 多一层：元素穿透拿不到「标题 + 图标矩形」时，退回 Dock 图标
/// 快照做几何命中——这是悬停预览「时灵时不灵」的主要修复点。
@MainActor
public final class DockHoverPreviewPlugin: FeaturePlugin {
    public static let manifest = PluginManifest(
        id: "com.gaelthas.plugin.dock-hover-preview",
        version: "1.0.1",
        minHostVersion: "1.0.0",
        title: "dockHover.title",
        summary: "dockHover.summary",
        iconSystemName: "dock.arrow.up.rectangle",
        // 指针移动监听与 Dock 命中判定都由辅助功能门控。
        requiredCapabilities: [.accessibility],
        optionalCapabilities: [.screenCapture],
        resourceBundle: resourceBundle
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
        let frame: CGRect
        let bundleID: String?
        let url: URL?
    }

    private var candidate: Candidate?
    private var currentKey: String?
    private var lastProbe: TimeInterval = 0
    private var showTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    /// 被节流吃掉的那一跳的补偿探测（指针停下后不会再有 move 事件）。
    private var deferredProbe: Task<Void, Never>?

    /// Dock 图标快照：命中失败时的几何兜底。枚举一次十几毫秒，按 TTL 复用。
    private var catalog: [DockItem] = []
    private var catalogAt: TimeInterval = 0
    private var catalogFetchAt: TimeInterval = 0
    private var catalogFetching = false
    private let catalogTTL: TimeInterval = 1.5
    /// 连续未命中时不要每次都重扫整棵树。
    private let catalogRefetchInterval: TimeInterval = 0.6

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
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // 用户点到别处去了，预览没有继续存在的理由。
                    // 自己成为激活应用（面板取 key）不算「点了别处」。
                    guard let self, self.panel.isVisible,
                          pid != ProcessInfo.processInfo.processIdentifier else { return }
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
        deferredProbe?.cancel()
        showTask = nil
        thumbnailTask = nil
        dismissTask = nil
        deferredProbe = nil
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
        if let frame = panel.frameInAppKit, frame.insetBy(dx: -2, dy: -2).contains(mouse) {
            dismissTask?.cancel()
            dismissTask = nil
            return
        }

        guard DockGeometry.isNearDockBand(point) else {
            scheduleDismiss()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastProbe
        guard elapsed >= probeInterval else {
            // 指针停下后不会再有 move 事件：这一跳如果被节流吞掉，预览就一直不弹。
            // 补一次延迟探测，保证「最后一跳」也能命中。
            deferredProbe?.cancel()
            let wait = probeInterval - elapsed
            deferredProbe = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.probe(at: point, now: ProcessInfo.processInfo.systemUptime)
            }
            return
        }
        probe(at: point, now: now)
    }

    private func probe(at point: CGPoint, now: TimeInterval) {
        lastProbe = now
        guard let context else { return }
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        guard dockPID > 0 else { return }

        Task { [weak self] in
            guard let self else { return }
            let catalog = await self.catalogSnapshot(context: context, dockPID: dockPID, now: now)
            let hit = (try? await context.performBackground {
                DockHoverProbe.probe(point: point, dockPID: dockPID, catalog: catalog)
            }) ?? .miss

            guard let model = self.settingsModel, model.enabled else { return }

            // 没有「标题 + 图标矩形」就没法锚定面板：清掉候选并准备收起。
            guard hit.isDock, let title = hit.title, let frame = hit.frame else {
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

            self.candidate = Candidate(
                key: title,
                point: point,
                since: now,
                frame: frame,
                bundleID: hit.bundleID,
                url: hit.url
            )
            self.scheduleShow(after: model.hoverDelay)
        }
    }

    private func scheduleShow(after delay: TimeInterval) {
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, delay)))
            guard !Task.isCancelled, let self, let candidate = self.candidate else { return }
            // 计时期间指针已离开这个图标（或滑到别的图标上）：不弹。
            let mouse = NSEvent.mouseLocation
            let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
            let axPoint = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
            guard candidate.frame.insetBy(dx: -6, dy: -6).contains(axPoint) else { return }
            self.show(candidate)
        }
    }

    private func show(_ candidate: Candidate) {
        guard let context, let model = settingsModel else { return }
        guard let app = AppNameMatcher.app(
            matchingTitle: candidate.key,
            bundleID: candidate.bundleID,
            url: candidate.url
        ) else {
            model.append("no running app for \(candidate.key)")
            return
        }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? candidate.key
        let anchor = candidate.frame
        let session = thumbnails.beginSession()
        let thumbnailsAvailable = thumbnails.isAvailable

        Task { [weak self] in
            let windows = (try? await context.performBackground {
                HoverWindowCatalog.windows(for: pid, appName: appName)
            }) ?? []

            guard let self, let model = self.settingsModel else { return }
            guard !windows.isEmpty else {
                model.append("\(appName): no windows")
                // 上一个应用的面板还开着的话要收掉，否则会停在早已离开的图标上。
                self.dismiss(reason: "no windows for \(appName)", silent: true)
                return
            }

            let limited = Array(windows.prefix(max(1, model.maxWindows)))
            self.currentKey = candidate.key
            self.panel.show(
                windows: limited,
                appName: appName,
                appIcon: app.icon,
                mode: model.mode,
                thumbnailsAvailable: thumbnailsAvailable,
                showTitles: model.showWindowTitles,
                anchor: anchor
            )
            model.append("show \(appName): \(limited.count) window(s)")
            self.loadThumbnails(for: limited, session: session)
        }
    }

    private func loadThumbnails(for windows: [HoverWindow], session: Int) {
        guard let model = settingsModel else { return }
        guard model.mode == .thumbnails else { return }
        // 授权 / 冷却判定统一交给 governor（先做静默 preflight）；不可用时面板已经是图标模式。
        guard thumbnails.isAvailable else {
            model.append("thumbnails unavailable; icons only")
            return
        }

        for window in windows {
            if let cached = thumbnails.cached(window.windowID) {
                panel.setThumbnail(windowID: window.windowID, image: cached)
            }
        }

        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            await self.thumbnails.captureAll(windows.map(\.windowID), session: session) { [weak self] windowID, image in
                self?.panel.setThumbnail(windowID: windowID, image: image)
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
        deferredProbe?.cancel()
        showTask = nil
        thumbnailTask = nil
        dismissTask = nil
        deferredProbe = nil
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

    // MARK: - Dock 图标快照

    private func catalogSnapshot(context: PluginContext, dockPID: pid_t, now: TimeInterval) async -> [DockItem] {
        if !catalog.isEmpty, now - catalogAt < catalogTTL {
            return catalog
        }
        guard !catalogFetching else { return catalog }
        guard now - catalogFetchAt >= catalogRefetchInterval else { return catalog }

        catalogFetching = true
        catalogFetchAt = now
        let fresh = (try? await context.performBackground {
            DockItemCatalog.items(dockPID: dockPID)
        }) ?? []
        catalogFetching = false

        if !fresh.isEmpty {
            catalog = fresh
            catalogAt = ProcessInfo.processInfo.systemUptime
        }
        return catalog
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
