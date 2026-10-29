import AppKit
import Foundation
import Observation
import PluginAPI

struct AppUsage: Identifiable {
    let bundleID: String
    let name: String
    let seconds: Double

    var id: String { bundleID }
}

struct DayTotal: Identifiable {
    let day: String
    let seconds: Double

    var id: String { day }
}

/// 前台应用时长统计。
///
/// 纯本地：只用 `NSWorkspace` 的激活/休眠通知，不读窗口、不截图、不需要任何系统授权。
/// 数据按天聚合后存在插件自己的 suite 里，最多保留 30 天。
@MainActor
@Observable
final class UsageStatisticsModel {
    private struct DayUsage: Codable {
        var perApp: [String: Double] = [:]
    }

    private enum Key {
        static let days = "usage.days"
        static let enabled = "usage.enabled"
    }

    private let retentionDays = 30

    @ObservationIgnored private let store: PluginStore
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var days: [String: DayUsage] = [:]
    private var session: (bundleID: String, name: String, start: Date)?

    var enabled: Bool {
        didSet {
            store.set(enabled, forKey: Key.enabled)
            if !enabled {
                endSession(at: Date())
            }
        }
    }

    private(set) var today: [AppUsage] = []
    private(set) var week: [DayTotal] = []
    private(set) var daysRecorded = 0

    init(store: PluginStore) {
        self.store = store
        enabled = store.value(Bool.self, forKey: Key.enabled) ?? true
        days = store.value([String: DayUsage].self, forKey: Key.days) ?? [:]
        refresh(at: Date())
    }

    // MARK: - 会话

    func beginSession(bundleID: String, name: String, at date: Date = Date()) {
        guard enabled else { return }
        endSession(at: date)
        session = (bundleID, name, date)
    }

    func endSession(at date: Date = Date()) {
        guard let session else { return }
        self.session = nil

        let elapsed = date.timeIntervalSince(session.start)
        guard elapsed >= 1 else { return }

        let key = dayFormatter.string(from: session.start)
        var usage = days[key] ?? DayUsage()
        usage.perApp[session.bundleID, default: 0] += elapsed
        days[key] = usage
        persist()
    }

    /// 周期性结算：即使进程被强杀，最多也只丢失一个周期。
    func flush(at date: Date = Date()) {
        guard let session else { return }
        endSession(at: date)
        beginSession(bundleID: session.bundleID, name: session.name, at: date)
        refresh(at: date)
    }

    var currentBundleID: String? { session?.bundleID }

    // MARK: - 展示

    func refresh(at date: Date = Date()) {
        let todayKey = dayFormatter.string(from: date)
        let perApp = days[todayKey]?.perApp ?? [:]

        today = perApp
            .map { bundleID, seconds in
                AppUsage(bundleID: bundleID, name: Self.displayName(for: bundleID), seconds: seconds)
            }
            .sorted { $0.seconds > $1.seconds }

        var totals: [DayTotal] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { continue }
            let key = dayFormatter.string(from: day)
            let total = (days[key]?.perApp.values.reduce(0, +)) ?? 0
            totals.append(DayTotal(day: key, seconds: total))
        }
        week = totals
        daysRecorded = days.count
    }

    func resetData() {
        session = nil
        days = [:]
        store.set(days, forKey: Key.days)
        refresh(at: Date())
    }

    static func displayName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, total % 60) }
        return String(format: "%ds", total)
    }

    // MARK: - 持久化

    private func persist() {
        prune()
        store.set(days, forKey: Key.days)
    }

    private func prune() {
        guard let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let cutoffKey = dayFormatter.string(from: cutoff)
        days = days.filter { $0.key >= cutoffKey }
    }
}
