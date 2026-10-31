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
    /// 实际是否按缩略图渲染：选的是「实时缩略图」但拿不到屏幕录制授权时为 false，
    /// 否则界面只剩一排灰色占位框——看起来就是「预览坏了」。
    var useThumbnails = false
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
        thumbnailsAvailable: Bool,
        showTitles: Bool,
        anchor: CGRect
    ) {
        state.windows = windows
        state.appName = appName
        state.showTitles = showTitles
        state.mode = mode
        state.useThumbnails = mode == .thumbnails && thumbnailsAvailable
        state.selected = 0
        state.thumbnails = [:]
        state.icons = [:]
        if let appIcon, let pid = windows.first?.pid {
            state.icons[pid] = appIcon
        }

        ensurePanel()
        // 每次重建内容视图，让入场动画每次都播放（与 Dock2Min 相同）。
        let hosting = NSHostingController(rootView: HoverGrid(state: state, onSelect: { [weak self] window in
            self?.onSelect?(window)
        }))
        panel?.contentViewController = hosting
        position(anchor: anchor, host: hosting)
        // 基座是常驻后台进程：仅 `makeKeyAndOrderFront` 在应用非激活时不一定把
        // 面板顶到最前，`orderFrontRegardless` 才是「无论如何都显示」的调用。
        panel?.orderFrontRegardless()
        panel?.makeKey()
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

    /// `anchor` 是 AX 左上坐标（主屏左上为原点）。
    ///
    /// 这里修掉两个「预览不弹出」的来源：
    /// 1. `fittingSize` 在视图尚未布局时可能是 0 → 面板 0×0，必须强制布局并给下限；
    /// 2. 原来固定用 `NSScreen.main` 和主屏高度做换算，多屏 / Dock 在副屏时面板会被
    ///    算到屏幕外 → 改为按锚点所在屏换算，并把面板夹进该屏可视区域。
    private func position(anchor: CGRect, host: NSViewController) {
        guard let panel else { return }

        let view = host.view
        view.layoutSubtreeIfNeeded()
        var fitting = view.fittingSize
        fitting.width = max(fitting.width, 240)
        fitting.height = max(fitting.height, 140)

        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let anchorCenterInAppKit = CGPoint(x: anchor.midX, y: primaryHeight - anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(anchorCenterInAppKit) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        fitting.width = min(fitting.width, visible.width - 16)
        fitting.height = min(fitting.height, visible.height - 16)

        let iconTopEdge = primaryHeight - anchor.minY       // 图标上沿（AppKit）

        var x = anchor.midX - fitting.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - fitting.width - 8)

        // 默认贴在图标上方 10pt；放不下就尽量往上贴，保证整块面板留在屏内。
        var y = iconTopEdge + 10
        y = min(y, visible.maxY - fitting.height - 8)
        y = max(y, visible.minY + 8)

        panel.setFrame(NSRect(x: x, y: y, width: fitting.width, height: fitting.height), display: false)
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
        state.useThumbnails ? 220 : 100
    }

    /// 悬停预览只展示单个应用：按窗口数收窄，最多 3 列，避免看起来像切换器。
    private var columns: [GridItem] {
        let count = max(1, min(state.windows.count, 3))
        return Array(repeating: GridItem(.fixed(itemWidth), spacing: 20), count: count)
    }

    var body: some View {
        VStack(spacing: 20) {
            LazyVGrid(columns: columns, spacing: 20) {
                // 用下标做身份：拿不到 `AXWindowNumber` 的窗口 `windowID` 会是 0，
                // 多个 0 会让 SwiftUI 认为 id 重复而漏画卡片。
                ForEach(Array(state.windows.enumerated()), id: \.offset) { index, window in
                    HoverItemView(
                        window: window,
                        isSelected: index == state.selected,
                        showThumbnail: state.useThumbnails,
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
                    } else if let icon = state.icons[window.pid] {
                        // 还没抓到缩略图：先显示应用图标，比灰底占位更能说明「这是谁的窗口」。
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: width - 20, height: (width - 20) * 0.75)
                            .overlay(
                                Image(nsImage: icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 64, height: 64)
                                    .opacity(0.9)
                            )
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
