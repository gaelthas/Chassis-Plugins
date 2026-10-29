import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 单窗口缩略图。屏幕录制是可选能力：没授权时插件完全走图标模式。
enum ThumbnailProvider {
    /// 一次会话内按窗口 ID 抓一张，返回 nil 表示该窗口不可截（最小化、已关闭、无权限）。
    static func capture(windowID: CGWindowID) async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale: CGFloat = 1.0
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
}
