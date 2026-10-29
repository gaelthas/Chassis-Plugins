import AppKit
import Observation
import SwiftUI

/// HUD 的运行时状态：只改标量，避免每帧重建视图树。
@MainActor
@Observable
final class SlowQuitHUDState {
    var progress: Double = 0
    var icon: NSImage?
}

/// 与 Dock2Min `SlowQuitHUDView` 完全一致的样式：
/// 目标应用图标居中，外面是半透明黑底 + 白色进度环；没有卡片、没有文字。
/// 环直径 114、线宽 6、图标 60（Dock2Min 是原始 76pt 设计的 150%）。
private struct SlowQuitRing: View {
    var state: SlowQuitHUDState

    private let ringDiameter: CGFloat = 114
    private let lineWidth: CGFloat = 6
    private let iconSize: CGFloat = 60
    private let strokePadding: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.4))

            Circle()
                .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: lineWidth))

            Circle()
                .trim(from: 0, to: max(0.001, min(1, state.progress)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            if let icon = state.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: iconSize, height: iconSize)
            } else {
                Image(systemName: "app")
                    .resizable()
                    .frame(width: iconSize - 4, height: iconSize - 4)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: ringDiameter, height: ringDiameter)
        // 描边会超出 frame 半条线宽，不留内边距会被 hosting view 裁掉几个像素。
        .padding(strokePadding)
    }
}

@MainActor
final class SlowQuitHUD {
    private let state = SlowQuitHUDState()
    private var panel: NSPanel?

    func show(icon: NSImage?) {
        state.progress = 0
        state.icon = icon

        if panel == nil {
            let hosting = NSHostingView(rootView: SlowQuitRing(state: state))
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            self.panel = panel
        }

        position()
        panel?.orderFrontRegardless()
    }

    func update(progress: Double) {
        state.progress = progress
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2
            )
        )
    }
}
