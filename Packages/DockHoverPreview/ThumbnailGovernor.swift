import AppKit
import CoreGraphics
import Foundation

/// 缩略图治理：缓存、代际取消、失败退避、冷却。
///
/// 这是 Dock2Min `CaptureService` 里最值钱的部分：屏幕录制授权被拒或不可用时，
/// 反复尝试会不断触发系统提示并拖慢界面。这里用「一次会话一次枚举 + 逐张失败退避
/// + 连续失败 4 次冷却 300s」收敛，并且**授权不可用时直接报告不可用**，
/// 让界面退回图标模式，而不是留一排灰色占位。
///
/// 说明：与 `DockHoverPreview` 中的同名实现逐字一致。按当前约定共享库只放无状态纯函数，
/// 这类有状态治理暂留各插件内；出现第三个消费者时应抽成插件侧共享 target。
@MainActor
final class ThumbnailGovernor {
    private struct Entry {
        let image: NSImage
        let at: Date
    }

    private let cacheTTL: TimeInterval = 120
    private let maxConsecutiveFailures = 4
    private let cooldownDuration: TimeInterval = 300
    private let retryBackoff: TimeInterval = 60
    private let missingWindowBackoff: TimeInterval = 30
    private let sessionTTL: TimeInterval = 2

    private var cache: [CGWindowID: Entry] = [:]
    private var generation = 0
    private var consecutiveFailures = 0
    private var cooldownUntil: Date?
    private var retryAfter: [CGWindowID: Date] = [:]
    private var session: ThumbnailSession?
    private var sessionAt: Date?

    var isCoolingDown: Bool {
        guard let cooldownUntil else { return false }
        return Date() < cooldownUntil
    }

    /// 能否截图：既要有屏幕录制授权，也没有在失败冷却期里。
    var isAvailable: Bool {
        ThumbnailProvider.isAuthorized && !isCoolingDown
    }

    /// 每次打开界面调用一次：代际递增，旧会话的异步结果会被丢弃。
    @discardableResult
    func beginSession() -> Int {
        generation += 1
        return generation
    }

    var currentGeneration: Int { generation }

    func cached(_ windowID: CGWindowID) -> NSImage? {
        guard let entry = cache[windowID] else { return nil }
        guard Date().timeIntervalSince(entry.at) < cacheTTL else {
            cache.removeValue(forKey: windowID)
            return nil
        }
        return entry.image
    }

    func shouldAttempt(_ windowID: CGWindowID) -> Bool {
        guard isAvailable else { return false }
        if cached(windowID) != nil { return false }
        return (retryAfter[windowID] ?? .distantPast) <= Date()
    }

    /// 批量抓取：一次枚举，逐张回调（界面可以逐张填进去，而不是等全部完成）。
    ///
    /// `onImage` 在主线程被调用；`session` 与当前代际不一致时立即停止，
    /// 避免快速连按时把上一轮的截图贴到新的窗口列表上。
    func captureAll(
        _ windowIDs: [CGWindowID],
        session requestedSession: Int,
        onImage: @escaping @MainActor (CGWindowID, NSImage) -> Void
    ) async {
        guard requestedSession == generation, isAvailable else { return }

        let now = Date()
        if retryAfter.count > 32 {
            retryAfter = retryAfter.filter { $0.value > now }
        }
        let targets = windowIDs.filter { windowID in
            windowID != 0 && shouldAttempt(windowID)
        }
        guard !targets.isEmpty else { return }

        guard let session = await sharedSession() else {
            // 枚举失败：授权被撤或 SCK 拒绝。整轮放弃，冷却期内不再触碰。
            cooldownUntil = Date().addingTimeInterval(cooldownDuration)
            return
        }

        for windowID in targets {
            guard requestedSession == generation, !Task.isCancelled else { return }
            guard isAvailable else { return }

            do {
                let image = try await session.capture(windowID: windowID)
                consecutiveFailures = 0
                cache[windowID] = Entry(image: image, at: Date())
                onImage(windowID, image)
            } catch ThumbnailProvider.CaptureError.notInContent {
                // 枚举快照过期：刷新，下一轮再来（不算失败，不冷却）。
                invalidateSession()
                retryAfter[windowID] = Date().addingTimeInterval(missingWindowBackoff)
            } catch {
                if ThumbnailProvider.isConsentFailure(error) {
                    cooldownUntil = Date().addingTimeInterval(cooldownDuration)
                    invalidateSession()
                    return
                }
                retryAfter[windowID] = Date().addingTimeInterval(retryBackoff)
                consecutiveFailures += 1
                if consecutiveFailures >= maxConsecutiveFailures {
                    cooldownUntil = Date().addingTimeInterval(cooldownDuration)
                    return
                }
            }
        }
    }

    func clear() {
        cache.removeAll()
        retryAfter.removeAll()
        invalidateSession()
        generation += 1
    }

    // MARK: - 枚举快照

    private func sharedSession() async -> ThumbnailSession? {
        if let session, let sessionAt, Date().timeIntervalSince(sessionAt) < sessionTTL {
            return session
        }
        guard let fresh = await ThumbnailSession.make() else { return nil }
        session = fresh
        sessionAt = Date()
        return fresh
    }

    private func invalidateSession() {
        session = nil
        sessionAt = nil
    }
}
