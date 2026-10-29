import AppKit
import CoreGraphics
import Foundation

/// 缩略图治理：缓存、代际取消、失败退避、冷却。
///
/// 这是 Dock2Min `ThumbnailService` 里最值钱的部分：屏幕录制授权被拒或不可用时，
/// 反复尝试会不断触发系统提示并拖慢界面。这里用「连续失败 4 次 → 冷却 300s」+ TTL 缓存收敛。
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

    private var cache: [CGWindowID: Entry] = [:]
    private var generation = 0
    private var consecutiveFailures = 0
    private var cooldownUntil: Date?
    private var inFlight: Set<CGWindowID> = []

    var isCoolingDown: Bool {
        guard let cooldownUntil else { return false }
        return Date() < cooldownUntil
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
        if isCoolingDown { return false }
        if cached(windowID) != nil { return false }
        return !inFlight.contains(windowID)
    }

    func capture(windowID: CGWindowID, session: Int) async -> NSImage? {
        guard session == generation else { return nil }
        guard shouldAttempt(windowID) else { return cached(windowID) }

        inFlight.insert(windowID)
        defer { inFlight.remove(windowID) }

        guard let image = await ThumbnailProvider.capture(windowID: windowID) else {
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailures {
                cooldownUntil = Date().addingTimeInterval(cooldownDuration)
            }
            return nil
        }

        consecutiveFailures = 0
        cache[windowID] = Entry(image: image, at: Date())
        return image
    }

    func clear() {
        cache.removeAll()
        inFlight.removeAll()
        generation += 1
    }
}
