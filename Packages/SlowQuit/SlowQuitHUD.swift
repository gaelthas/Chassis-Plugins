import AppKit
import Observation
import SwiftUI

/// 进度状态单独持有：HUD 每帧只改一个标量，避免重建 SwiftUI 视图树。
@MainActor
@Observable
final class SlowQuitHUDState {
    var progress: Double = 0
}

private struct SlowQuitRing: View {
    var state: SlowQuitHUDState
    var caption: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, state.progress)))
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 84, height: 84)

            Text(verbatim: caption)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(20)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(width: 148, height: 148)
    }
}

/// 插件自带的悬浮层：不进 PluginSupport（那里只能放无状态纯函数）。
/// `.nonactivatingPanel` 保证 HUD 不抢焦点，`ignoresMouseEvents` 保证不挡点击。
@MainActor
final class SlowQuitHUD {
    private let state = SlowQuitHUDState()
    private var panel: NSPanel?

    func show(caption: String) {
        state.progress = 0
        if panel == nil {
            let hosting = NSHostingView(rootView: SlowQuitRing(state: state, caption: caption))
            hosting.frame = NSRect(x: 0, y: 0, width: 148, height: 148)

            let panel = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hosting
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }

        positionCenter()
        panel?.orderFrontRegardless()
    }

    func update(progress: Double) {
        state.progress = progress
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionCenter() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}
