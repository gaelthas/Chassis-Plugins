import CoreGraphics
import Foundation
import Observation
import PluginAPI

/// 统计范围。窗口的右端点由 `anchorDate`（原生日期选择器）决定，默认今天；
/// 数据只保留最近 30 天，因此 `.all` 的实际上限也是 30 天。
enum StatsRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case all
    /// 由设置页的两个原生日期选择器指定起止日（含两端）。
    case custom

    var id: String { rawValue }

    var title: String { KBStrings.t("range.\(rawValue)") }

    /// 该范围包含的天数（含截止日）；`.all` 与 `.custom` 按实际记录/所选区间决定。
    var dayCount: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month, .all, .custom: return 30
        }
    }
}

/// 柱状图的一根柱子。`id` 用序号，避免小时/日期混用时冲突。
struct StatsPoint: Identifiable {
    let id: Int
    let label: String
    let value: Int
}

/// 供界面渲染的一次性快照。
struct StatsSnapshot {
    var counts: [Int64: Int] = [:]
    var total = 0
    var maxCount = 0
    var series: [StatsPoint] = []
    var seriesMax = 0
    var daysRecorded = 0
    /// 只选单日时柱状图按小时展示，其它范围按天。
    var isHourly = false

    static let empty = StatsSnapshot()
}

/// 每个按键的使用次数统计。
///
/// 只存「键位 → 次数」，不存时间序列明细、不存组合键、不存字符：
/// HID 键位与输入法无关，同一物理键在中文/英文输入下是同一个键。
@MainActor
@Observable
final class KeyboardStatisticsModel {
    /// 单日记录：按键次数 + 按小时的总次数（只有「今天」的柱状图需要）。
    private struct DayRecord: Codable {
        var keys: [String: Int] = [:]
        var hours: [String: Int] = [:]
    }

    private enum Key {
        static let days = "stats.days"
        static let enabled = "stats.enabled"
        static let range = "stats.range"
        static let customStart = "stats.customStart"
        static let customEnd = "stats.customEnd"
        static let schema = "_schemaVersion"
    }

    /// 数据保留天数。与 UsageStatistics 一致，避免 UserDefaults 无限增长。
    private let retentionDays = 30
    /// 落盘节流：打字很密，逐键写 UserDefaults 既慢又无意义。
    private let persistInterval: TimeInterval = 10

    @ObservationIgnored private let store: PluginStore
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @ObservationIgnored private var days: [String: DayRecord] = [:]
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var needsPersist = false
    @ObservationIgnored private var lastPersist = Date.distantPast

    private(set) var snapshot = StatsSnapshot.empty

    /// 统计窗口的截止日（含）。由设置页的原生日期选择器驱动，默认今天。
    var anchorDate = Date() {
        didSet { refresh() }
    }

    /// 自定义范围的起始日（含），只有 `range == .custom` 时生效。
    var customStart: Date {
        didSet {
            store.set(dayFormatter.string(from: customStart), forKey: Key.customStart)
            refresh()
        }
    }

    /// 自定义范围的结束日（含）。
    var customEnd: Date {
        didSet {
            store.set(dayFormatter.string(from: customEnd), forKey: Key.customEnd)
            refresh()
        }
    }

    /// 可选日期：数据只留 `retentionDays` 天，且不允许选未来。
    var selectableDates: ClosedRange<Date> {
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) ?? today
        return earliest...today
    }

    var isAnchorToday: Bool {
        calendar.isDateInToday(anchorDate)
    }

    var enabled: Bool {
        didSet { store.set(enabled, forKey: Key.enabled) }
    }

    var range: StatsRange {
        didSet {
            store.set(range.rawValue, forKey: Key.range)
            refresh()
        }
    }

    init(store: PluginStore) {
        self.store = store
        enabled = store.value(Bool.self, forKey: Key.enabled) ?? true
        range = store.value(String.self, forKey: Key.range).flatMap(StatsRange.init(rawValue:)) ?? .day
        days = store.value([String: DayRecord].self, forKey: Key.days) ?? [:]

        let today = calendar.startOfDay(for: Date())
        customEnd = store.value(String.self, forKey: Key.customEnd)
            .flatMap(dayFormatter.date(from:)) ?? today
        customStart = store.value(String.self, forKey: Key.customStart)
            .flatMap(dayFormatter.date(from:))
            ?? calendar.date(byAdding: .day, value: -6, to: today)
            ?? today

        store.set(1, forKey: Key.schema)
        // 保留期是滚动的，隔几天再打开时旧的起止日可能已经越界。
        clampCustomRange()
        refresh()
    }

    /// 把自定义起止日夹进可选区间；只在初始化时调用，避免每次刷新都与选择器打架。
    private func clampCustomRange() {
        let limits = selectableDates
        var start = min(max(calendar.startOfDay(for: customStart), limits.lowerBound), limits.upperBound)
        var end = min(max(calendar.startOfDay(for: customEnd), limits.lowerBound), limits.upperBound)
        if start > end { swap(&start, &end) }
        if start != customStart { customStart = start }
        if end != customEnd { customEnd = end }
    }

    // MARK: - 计数

    /// 修饰键的按下在 tap 里表现为 `flagsChanged`，需要靠 flags 判断「按下」还是「松开」。
    /// 不在 keyDown 里计修饰键：部分外接键盘会同时发 flagsChanged 与 keyDown，会重复计一次。
    nonisolated static func modifierFlag(for keyCode: Int64) -> CGEventFlags? {
        switch keyCode {
        case 0x37, 0x36: return .maskCommand
        case 0x3A, 0x3D: return .maskAlternate
        case 0x3B, 0x3E: return .maskControl
        case 0x38, 0x3C: return .maskShift
        case 0x39: return .maskAlphaShift
        case 0x3F: return .maskSecondaryFn
        default: return nil
        }
    }

    func record(keyCode: Int64, at date: Date = Date()) {
        guard enabled else { return }
        let dayKey = dayFormatter.string(from: date)
        var record = days[dayKey] ?? DayRecord()
        record.keys[String(keyCode), default: 0] += 1
        record.hours[String(calendar.component(.hour, from: date)), default: 0] += 1
        days[dayKey] = record
        needsRefresh = true
        needsPersist = true
    }

    /// 由插件的秒级任务驱动：合并高频按键，最多每秒刷新一次界面、每 10 秒落盘一次。
    func tick(at date: Date = Date()) {
        if needsRefresh {
            needsRefresh = false
            refresh()
        }
        if needsPersist, date.timeIntervalSince(lastPersist) >= persistInterval {
            persist(at: date)
        }
    }

    // MARK: - 聚合

    func refresh() {
        let dayKeys = self.dayKeys(for: range)

        var counts: [Int64: Int] = [:]
        for dayKey in dayKeys {
            guard let record = days[dayKey] else { continue }
            for (code, value) in record.keys {
                guard let code = Int64(code) else { continue }
                counts[code, default: 0] += value
            }
        }

        var snapshot = StatsSnapshot()
        snapshot.counts = counts
        snapshot.total = counts.values.reduce(0, +)
        snapshot.maxCount = counts.values.max() ?? 0
        snapshot.daysRecorded = days.count

        let sortedKeys = dayKeys.sorted()
        if sortedKeys.count == 1, let only = sortedKeys.first {
            // 只有一个自然日时按小时展示：否则柱状图只剩一根柱子，信息量太低。
            // 「当天」范围和起止日相同的自定义范围都落到这里。
            snapshot.isHourly = true
            let record = days[only]
            snapshot.series = (0..<24).map { hour in
                StatsPoint(id: hour, label: String(hour), value: record?.hours[String(hour)] ?? 0)
            }
        } else {
            snapshot.series = sortedKeys.enumerated().map { index, dayKey in
                StatsPoint(id: index, label: Self.shortLabel(dayKey), value: total(of: dayKey))
            }
        }
        snapshot.seriesMax = snapshot.series.map(\.value).max() ?? 0

        self.snapshot = snapshot
    }

    /// 最常用的若干键（含修饰键）。空格通常排第一，这是真实分布，不做过滤。
    func topKeys(limit: Int = 5) -> [(code: Int64, count: Int)] {
        snapshot.counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (code: $0.key, count: $0.value) }
    }

    /// 60% 布局覆盖不到的键（F 键、小键盘、JIS 键等），单独列出避免数据「看起来丢了」。
    func keysOutsideLayout(limit: Int = 12) -> [(code: Int64, count: Int)] {
        snapshot.counts
            .filter { !KeyboardLayout.inLayout($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (code: $0.key, count: $0.value) }
    }

    private func dayKeys(for range: StatsRange) -> [String] {
        let anchorKey = dayFormatter.string(from: anchorDate)
        switch range {
        case .day:
            return [anchorKey]

        case .week, .month, .all:
            let window = (0..<range.dayCount).compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: anchorDate)
            }
            .map { dayFormatter.string(from: $0) }

            guard range == .all else { return window }
            // 「全部」不画满 30 根空柱子：从最早有记录的那天开始。
            guard let earliest = days.keys.min() else { return [anchorKey] }
            let filtered = window.filter { $0 >= earliest }
            return filtered.isEmpty ? [anchorKey] : filtered

        case .custom:
            // 选择器已把两端限制在保留期内，这里再夹一次：store 里的旧值可能越界。
            let limits = selectableDates
            let start = max(calendar.startOfDay(for: customStart), limits.lowerBound)
            let end = min(calendar.startOfDay(for: customEnd), limits.upperBound)
            guard start <= end else { return [dayFormatter.string(from: end)] }

            var keys: [String] = []
            var cursor = start
            while cursor <= end, keys.count < retentionDays {
                keys.append(dayFormatter.string(from: cursor))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return keys
        }
    }

    private func total(of dayKey: String) -> Int {
        days[dayKey]?.keys.values.reduce(0, +) ?? 0
    }

    private static func shortLabel(_ dayKey: String) -> String {
        // "2026-10-31" → "10-31"，柱状图下面只放得下这么宽。
        dayKey.count == 10 ? String(dayKey.dropFirst(5)) : dayKey
    }

    // MARK: - 持久化

    func persist(at date: Date = Date()) {
        prune(at: date)
        store.set(days, forKey: Key.days)
        needsPersist = false
        lastPersist = date
    }

    func reset() {
        days = [:]
        needsPersist = false
        store.set(days, forKey: Key.days)
        refresh()
    }

    private func prune(at date: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: date) else { return }
        let cutoffKey = dayFormatter.string(from: cutoff)
        days = days.filter { $0.key >= cutoffKey }
    }
}
