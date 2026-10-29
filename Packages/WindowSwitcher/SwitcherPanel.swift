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
    var thumbnails: [CGWindowID: NSImage] = [:]
    var icons: [pid_t: NSImage] = [:]
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
        showTitles: Bool,
        onSelect: @escaping (SwitcherWindow) -> Void
    ) {
        state.windows = windows
        state.selected = selected
        state.showTitles = showTitles
        state.mode = mode
        state.thumbnails = [:]
        state.icons = Self.icons(for: windows)

        ensurePanel()
        // 重建内容视图：Dock2Min 用同样的方式保证每次弹出都播放淡入/上移。
        panel?.contentViewController = NSHostingController(
            rootView: SwitcherView(state: state, onSelect: onSelect)
        )
        position()
        panel?.makeKeyAndOrderFront(nil)
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

    private func position() {
        guard let panel,
              let contentView = panel.contentViewController?.view,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else {
            return
        }

        contentView.layout()
        let fitting = contentView.fittingSize
        let visible = screen.visibleFrame
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
