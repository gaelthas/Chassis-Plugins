import AppKit
import SwiftUI

/// 视觉与交互完全对齐 Dock2Min 的 `AltTabOverlayView`：
/// 半屏宽、`ultraThinMaterial` 圆角 24 卡片、图标 64pt / 缩略图 220pt 两档、
/// 选中项 accent 0.22 底 + 2pt 描边 + 1.05 缩放，入场淡入并上移 16pt。
struct SwitcherView: View {
    var state: SwitcherState
    var onSelect: (SwitcherWindow) -> Void

    @State private var appeared = false

    private var idealWidth: CGFloat {
        (NSScreen.main?.visibleFrame.width ?? 1200) * 0.5
    }

    private var itemWidth: CGFloat {
        state.mode == .thumbnails ? 220 : 100
    }

    private var columns: [GridItem] {
        // 与 Dock2Min 相同的容量计算：外层 24 + 网格 30 的内边距、20 的间距。
        let availableWidth = idealWidth - 60
        let maxColumns = Int(max(1, floor(availableWidth / (itemWidth + 20))))
        let count = state.windows.isEmpty ? 1 : min(state.windows.count, maxColumns)
        return Array(repeating: GridItem(.fixed(itemWidth), spacing: 20), count: count)
    }

    var body: some View {
        VStack(spacing: 20) {
            if state.windows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("switcher.noWindows")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(state.windows.enumerated()), id: \.element.id) { index, window in
                        SwitcherItemView(
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
        }
        .padding(24)
        .frame(maxWidth: idealWidth)
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

private struct SwitcherItemView: View {
    let window: SwitcherWindow
    let isSelected: Bool
    let showThumbnail: Bool
    let width: CGFloat
    var state: SwitcherState
    let index: Int
    var onSelect: (SwitcherWindow) -> Void

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
