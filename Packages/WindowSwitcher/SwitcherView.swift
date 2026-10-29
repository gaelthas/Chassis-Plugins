import AppKit
import SwiftUI

struct SwitcherView: View {
    var state: SwitcherState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(state.windows.enumerated()), id: \.element.id) { index, window in
                        SwitcherCard(window: window, isSelected: index == state.selected, state: state)
                            .id(window.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: state.selected) { _, newValue in
                guard state.windows.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(state.windows[newValue].id, anchor: .center)
                }
            }
        }
        .frame(width: 720, height: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct SwitcherCard: View {
    let window: SwitcherWindow
    let isSelected: Bool
    var state: SwitcherState

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))

                if let thumbnail = state.thumbnails[window.id] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                } else if let icon = state.icons[window.pid] {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 168, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if state.showTitles {
                Text(verbatim: window.title.isEmpty ? window.appName : window.title)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(width: 168, height: 32, alignment: .top)
            } else {
                Text(verbatim: window.appName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 168, height: 32, alignment: .top)
            }
        }
        .padding(8)
        .frame(width: 184, height: 190)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
    }
}
