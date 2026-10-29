import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class HoverState {
    var windows: [HoverWindow] = []
    var icons: [pid_t: NSImage] = [:]
    var thumbnails: [CGWindowID: NSImage] = [:]
    var showTitles = true
    var appName = ""
}

/// 悬停预览悬浮层。
///
/// `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`：鼠标移入面板时能点击卡片，
/// 但不会把本应用变成前台，否则用户在 Dock 上的悬停语义会被打断。
@MainActor
final class HoverPanel {
    let state = HoverState()
    var onSelect: ((HoverWindow) -> Void)?

    private var panel: NSPanel?
    private var hosting: NSHostingView<HoverGrid>?

    var isVisible: Bool { panel?.isVisible ?? false }

    var frameInAppKit: CGRect? {
        panel?.frame
    }

    func show(windows: [HoverWindow], appName: String, appIcon: NSImage?, showTitles: Bool, anchor: CGRect) {
        state.windows = windows
        state.appName = appName
        state.showTitles = showTitles
        state.thumbnails = [:]
        state.icons = [:]
        if let appIcon, let pid = windows.first?.pid {
            state.icons[pid] = appIcon
        }

        ensurePanel()
        resize(for: windows.count)
        position(anchor: anchor)
        panel?.orderFrontRegardless()
    }

    func setThumbnail(windowID: CGWindowID, image: NSImage) {
        state.thumbnails[windowID] = image
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: HoverGrid(state: state, onSelect: { [weak self] window in
            self?.onSelect?(window)
        }))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // 需要接收卡片点击：允许点击时成为 key（nonactivating 保证不激活本应用）。
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        self.hosting = hosting
        self.panel = panel
    }

    private func resize(for count: Int) {
        guard let panel else { return }
        let columns = min(max(count, 1), 3)
        let width = CGFloat(columns) * 148 + 20
        let rows = (count + 2) / 3
        let height = CGFloat(max(rows, 1)) * 132 + 20
        panel.setContentSize(NSSize(width: width, height: height))
        hosting?.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    /// `anchor` 是 AX 的左上坐标（与 ClickContext 同系）。根据 Dock 贴边位置决定弹出方向。
    private func position(anchor: CGRect) {
        guard let panel else { return }

        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let appKitTop = primaryHeight - anchor.minY
        let appKitBottom = primaryHeight - anchor.maxY
        let size = panel.frame.size

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: appKitTop + 10
        )

        // Dock 在左/右时改为侧向展开。
        if anchor.minX - visible.minX < 120 {
            origin = NSPoint(x: anchor.maxX + 10, y: appKitBottom + anchor.height / 2 - size.height / 2)
        } else if visible.maxX - anchor.maxX < 120 {
            origin = NSPoint(x: anchor.minX - size.width - 10, y: appKitBottom + anchor.height / 2 - size.height / 2)
        }

        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - size.height - 8))
        panel.setFrameOrigin(origin)
    }
}

struct HoverGrid: View {
    var state: HoverState
    var onSelect: (HoverWindow) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 148), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(state.windows) { window in
                Button {
                    onSelect(window)
                } label: {
                    card(window)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func card(_ window: HoverWindow) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                if let thumbnail = state.thumbnails[window.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                } else if let icon = state.icons[window.pid] {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            if state.showTitles {
                Text(verbatim: window.title.isEmpty ? window.appName : window.title)
                    .font(.caption2)
                    .lineLimit(2)
                    .frame(height: 26, alignment: .top)
            }
        }
        .padding(6)
        .frame(width: 140, height: 122)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
