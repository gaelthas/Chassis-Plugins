import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class SwitcherState {
    var windows: [SwitcherWindow] = []
    var selected = 0
    var showTitles = true
    var mode: WindowSwitcherModel.DisplayMode = .icons
    /// 实际是否按缩略图渲染：`mode == .thumbnails` 但拿不到屏幕录制授权时保持 false，
    /// 否则界面只剩一排灰色占位框（看起来就是「预览坏了」）。
    var useThumbnails = false
    var thumbnails: [CGWindowID: NSImage] = [:]
    var icons: [pid_t: NSImage] = [:]

    /// 面板弹出时的鼠标位置。Windows 的 Alt-Tab 里，指针只是「停在那儿」不会把
    /// 选中挪到它下面的卡片上——面板正好在指针下方弹出时这一点尤其明显。
    @ObservationIgnored private var hoverOrigin: CGPoint = .zero
    /// 指针真正移动过之后，才允许鼠标悬停改变选中。
    @ObservationIgnored private var hoverArmed = false
    /// 视为「移动过」的最小位移（pt）：滤掉触控板抖动与面板弹出时的合成事件。
    private static let hoverArmThreshold: CGFloat = 4

    func resetHoverTracking(origin: CGPoint) {
        hoverOrigin = origin
        hoverArmed = false
    }

    /// 鼠标悬停到第 `index` 张卡片：只有指针确实移动过才生效。
    func hoverSelect(_ index: Int) {
        if !hoverArmed {
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - hoverOrigin.x
            let dy = mouse.y - hoverOrigin.y
            guard (dx * dx + dy * dy).squareRoot() >= Self.hoverArmThreshold else { return }
            hoverArmed = true
        }
        guard selected != index else { return }
        selected = index
    }
}

/// 面板行为对齐 Dock2Min 的 `AltTabManager.showPanel()`：
/// 每次显示重建 hosting controller（让入场动画每次都播放）、按内容 `fittingSize` 定尺寸、
/// 居中于主屏、`.floating` 层级且不参与窗口循环。
@MainActor
final class SwitcherPanel {
    let state = SwitcherState()
    private var panel: NSPanel?

    func show(
        windows: [SwitcherWindow],
        selected: Int,
        mode: WindowSwitcherModel.DisplayMode,
        thumbnailsAvailable: Bool,
        showTitles: Bool,
        onSelect: @escaping (SwitcherWindow) -> Void
    ) {
        state.windows = windows
        state.selected = selected
        state.showTitles = showTitles
        state.mode = mode
        state.useThumbnails = mode == .thumbnails && thumbnailsAvailable
        state.thumbnails = [:]
        state.icons = Self.icons(for: windows)
        // 在面板显示前记录指针位置：弹出瞬间如果指针正好压在某张卡片上，
        // 不能因此改掉「默认选中下一个窗口」。
        state.resetHoverTracking(origin: NSEvent.mouseLocation)

        ensurePanel()
        // 重建内容视图：Dock2Min 用同样的方式保证每次弹出都播放淡入/上移。
        let hosting = NSHostingController(rootView: SwitcherView(state: state, onSelect: onSelect))
        panel?.contentViewController = hosting
        position(host: hosting)
        // 应用是老后台的常驻进程：`makeKeyAndOrderFront` 不保证在非激活状态下顶到最前。
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    func update(selected: Int) {
        state.selected = selected
    }

    func setThumbnail(windowID: CGWindowID, image: NSImage) {
        state.thumbnails[windowID] = image
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        self.panel = panel
    }

    private func position(host: NSViewController) {
        guard let panel,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return
        }

        // SwiftUI 视图还没完成布局时 `fittingSize` 可能是 0：先强制布局再量，
        // 并给一个可用下限，否则面板是 0×0——表现就是「⌥Tab 没有任何反应」。
        let view = host.view
        view.layoutSubtreeIfNeeded()
        var fitting = view.fittingSize
        fitting.width = max(fitting.width, 360)
        fitting.height = max(fitting.height, 180)

        let visible = screen.visibleFrame
        fitting.width = min(fitting.width, visible.width - 16)
        // 窗口很多时卡片会超过屏幕高度：夹在可视区域内，保证标题栏不出屏。
        fitting.height = min(fitting.height, visible.height - 16)

        let origin = NSPoint(
            x: visible.origin.x + (visible.width - fitting.width) / 2,
            y: visible.origin.y + (visible.height - fitting.height) / 2
        )
        panel.setFrame(NSRect(origin: origin, size: fitting), display: false)
    }

    private static func icons(for windows: [SwitcherWindow]) -> [pid_t: NSImage] {
        var result: [pid_t: NSImage] = [:]
        for window in windows where result[window.pid] == nil {
            if let app = NSRunningApplication(processIdentifier: window.pid), let icon = app.icon {
                result[window.pid] = icon
            }
        }
        return result
    }
}
