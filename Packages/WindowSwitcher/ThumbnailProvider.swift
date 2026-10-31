import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 单窗口缩略图。屏幕录制是可选能力：没授权时插件完全走图标模式。
///
/// 「一次会话只枚举一次 shareable content」是这里最关键的取舍：
/// 每个窗口各调一次 `SCShareableContent` 既慢（几十毫秒 × N），在 macOS 15 上还会
/// 反复触发授权流程，表现就是「缩略图一直不出现」。
enum ThumbnailProvider {
    enum CaptureError: Error {
        /// 窗口不在枚举快照里：新旧窗口交替时的正常情况，刷新枚举即可。
        case notInContent
    }

    /// 静默的授权探测：`CGPreflightScreenCaptureAccess()` 不会弹系统框，
    /// 而未授权时任何 ScreenCaptureKit 入口都可能各弹一个框。
    static var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 抓一张 480pt 宽的缩略图，保持窗口原始长宽比（不要压成 4:3）。
    static func capture(windowID: CGWindowID, content: SCShareableContent) async throws -> NSImage {
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.notInContent
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let source = filter.contentRect
        let width: CGFloat = 480
        let aspect = source.width > 1 ? source.height / source.width : 0.75
        configuration.width = Int(width)
        configuration.height = max(1, Int((width * aspect).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// `SCStreamError.userDeclined` (-3801) / `missingEntitlement` (-3808)：
    /// 再试只会继续弹授权框，必须让整个会话停下来。
    static func isConsentFailure(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == -3801 || code == -3808
    }
}

/// 一次会话的 shareable-content 快照。
///
/// `@unchecked Sendable` 是有意的：`SCShareableContent` 不是 Sendable，而把它当作
/// 主线程状态会触发「sending risks data races」；这里只在本类型的异步方法里**只读**使用，
/// 调用方（`ThumbnailGovernor`）保证串行访问，因此不需要再加锁。
final class ThumbnailSession: @unchecked Sendable {
    private let content: SCShareableContent

    private init(content: SCShareableContent) {
        self.content = content
    }

    /// 枚举一次（含离屏窗口）：最小化 / ⌘H 的窗口只有枚举离屏窗口才抓得到。
    static func make() async -> ThumbnailSession? {
        guard ThumbnailProvider.isAuthorized else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else {
            return nil
        }
        return ThumbnailSession(content: content)
    }

    func capture(windowID: CGWindowID) async throws -> NSImage {
        try await ThumbnailProvider.capture(windowID: windowID, content: content)
    }
}
