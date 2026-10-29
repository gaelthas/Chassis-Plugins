import AppKit
import PluginSupport
import ScreenCaptureKit

/// 截图探针：ScreenCaptureKit 的单窗口捕获。
///
/// 注意这不是基座能力：插件自己 import ScreenCaptureKit、自己判断权限、自己降级（§5.1）。
enum CaptureProbe {
    struct Result: Sendable {
        let image: NSImage?
        let summary: String
    }

    static func captureFirstOnScreenWindow() async throws -> Result {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let window = content.windows.first(where: { window in
            guard let app = window.owningApplication else { return false }
            return app.processID != ownPID && window.frame.width > 40 && window.frame.height > 40
        }) else {
            return Result(image: nil, summary: "no-window")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return Result(image: image, summary: "window-\(window.windowID)")
    }

    /// 缺屏幕录制权限时的降级路径：只列窗口，不给画面。
    static func degradedSummary() -> String {
        let windows = WindowList.onScreenWindows()
        return "windows=\(windows.count)"
    }
}
