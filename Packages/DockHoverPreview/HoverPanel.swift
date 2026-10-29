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
    var mode: DockHoverModel.DisplayMode = .icons
    var selected = 0
    var appName = ""
}

/// 悬停预览沿用 Dock2Min 的做法：**同一套 Alt-Tab 卡片**，只是把面板锚到 Dock 图标上方。
/// 面板配置与 `AltTabManager.showPanel()` 一致：非激活面板、`fittingSize` 定尺寸、
/// `.floating`、不参与窗口循环；图标顶部再加 10pt 间距。
@MainActor
final class HoverPanel {
    let state = HoverState()
    var onSelect: ((HoverWindow) -> Void)?

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    var frameInAppKit: CGRect? { panel?.frame }

    func show(
        windows: [HoverWindow],
        appName: String,
        appIcon: NSImage?,
        mode: DockHoverModel.DisplayMode,
        showTitles: Bool,
        anchor: CGRect
    ) {
        state.windows = windows
        state.appName = appName
        state.showTitles = showTitles
        state.mode = mode
        state.selected = 0
        state.thumbnails = [:]
        state.icons = [:]
        if let appIcon, let pid = windows.first?.pid {
            state.icons[pid] = appIcon
        }

        ensurePanel()
        // 每次重建内容视图，让入场动画每次都播放（与 Dock2Min 相同）。
        panel?.contentViewController = NSHostingController(
            rootView: HoverGrid(state: state, onSelect: { [weak self] window in
                self?.onSelect?(window)
            })
        )
        position(anchor: anchor)
        panel?.makeKeyAndOrderFront(nil)
    }

    func setThumbnail(windowID: CGWindowID, image: NSImage) {
        state.thumbnails[windowID] = image
    }

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

    /// `anchor` 是 AX 左上坐标。Dock2Min 的换算：`screenHeight - anchor.minY` 得到图标上沿的
    /// 底左坐标，再上移 10pt 作为面板底边。
    private func position(anchor: CGRect) {
        guard let panel, let contentView = panel.contentViewController?.view, let screen = NSScreen.main else {
            return
        }

        contentView.layout()
        let fitting = contentView.fittingSize
        let screenHeight = screen.frame.height
        let iconTopEdgeFromBottom = screenHeight - anchor.minY

        var x = anchor.midX - fitting.width / 2
        let visible = screen.visibleFrame
        x = max(visible.minX + 8, min(x, visible.maxX - fitting.width - 8))

        panel.setFrame(
            NSRect(x: x, y: iconTopEdgeFromBottom + 10, width: fitting.width, height: fitting.height),
            display: false
        )
    }
}

/// 与 Dock2Min `AltTabOverlayView` 相同的视觉：半透明材质圆角卡片、
/// 图标 64pt / 缩略图 220pt、选中 accent 0.22 + 2pt 描边 + 1.05 缩放、入场淡入上移。
struct HoverGrid: View {
    var state: HoverState
    var onSelect: (HoverWindow) -> Void

    @State private var appeared = false

    private var idealWidth: CGFloat {
        (NSScreen.main?.visibleFrame.width ?? 1200) * 0.5
    }

    private var itemWidth: CGFloat {
        state.mode == .thumbnails ? 220 : 100
    }

    /// 悬停预览只展示单个应用：按窗口数收窄，最多 3 列，避免看起来像切换器。
    private var columns: [GridItem] {
        let count = max(1, min(state.windows.count, 3))
        return Array(repeating: GridItem(.fixed(itemWidth), spacing: 20), count: count)
    }

    var body: some View {
        VStack(spacing: 20) {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(Array(state.windows.enumerated()), id: \.element.id) { index, window in
                    HoverItemView(
                        window: window,
                        isSelected: index == state.selected,
                        showThumbnail: state.mode == .thumbnails,
                        width: itemWidth,
                        state: state,
                        index: index,
                        onSelect: onSelect
                    )
                }
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .padding(24)
        .fixedSize()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    appeared = true
                }
            }
        }
    }
}

private struct HoverItemView: View {
    let window: HoverWindow
    let isSelected: Bool
    let showThumbnail: Bool
    let width: CGFloat
    var state: HoverState
    let index: Int
    var onSelect: (HoverWindow) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if showThumbnail {
                    if let thumbnail = state.thumbnails[window.id] {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: width - 20, height: (width - 20) * 0.75)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: width - 20, height: (width - 20) * 0.75)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.title)
                                    .foregroundStyle(.gray)
                            )
                    }

                    if let icon = state.icons[window.pid] {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 36, height: 36)
                            .offset(x: 12, y: 12)
                            .shadow(color: .black.opacity(0.3), radius: 4)
                    }
                } else if let icon = state.icons[window.pid] {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .shadow(color: .black.opacity(0.1), radius: 4)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, height: 64)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isSelected)

            if state.showTitles {
                Text(verbatim: window.title.isEmpty ? window.appName : window.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: width)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .padding(4)
        .onTapGesture {
            state.selected = index
            onSelect(window)
        }
        .onHover { hovering in
            guard hovering else { return }
            state.selected = index
        }
    }
}
