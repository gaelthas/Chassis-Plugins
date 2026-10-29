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

/// 切换器悬浮层：`.nonactivatingPanel` 保证不抢焦点（否则松开 ⌥ 时前台应用会先变成本应用）。
@MainActor
final class SwitcherPanel {
    let state = SwitcherState()
    private var panel: NSPanel?

    private let panelSize = NSSize(width: 720, height: 230)

    func show(windows: [SwitcherWindow], selected: Int, mode: WindowSwitcherModel.DisplayMode, showTitles: Bool) {
        state.windows = windows
        state.selected = selected
        state.mode = mode
        state.showTitles = showTitles
        state.thumbnails = [:]
        state.icons = Self.icons(for: windows)
        ensurePanel()
        positionUnderMouse()
        panel?.orderFrontRegardless()
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

        let hosting = NSHostingView(rootView: SwitcherView(state: state))
        hosting.frame = NSRect(origin: .zero, size: panelSize)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        self.panel = panel
    }

    private func positionUnderMouse() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
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
