import Foundation
import Observation
import PluginAPI

@MainActor
@Observable
final class WindowSwitcherModel {
    enum DisplayMode: String, Codable, CaseIterable {
        /// 方案 A：只显示应用图标 + 窗口标题，零截图开销。
        case icons
        /// 方案 B：实时缩略图，需要屏幕录制授权。
        case thumbnails
    }

    private enum Key {
        static let mode = "display.mode"
        static let titles = "display.showTitles"
        static let maxThumbnails = "display.maxThumbnails"
    }

    @ObservationIgnored private let store: PluginStore

    var mode: DisplayMode {
        didSet { store.set(mode.rawValue, forKey: Key.mode) }
    }

    var showWindowTitles: Bool {
        didSet { store.set(showWindowTitles, forKey: Key.titles) }
    }

    /// 截图数量上限：一次会话最多抓这么多张，避免几十个窗口同时截图拖慢打开速度。
    var maxThumbnails: Int {
        didSet { store.set(maxThumbnails, forKey: Key.maxThumbnails) }
    }

    private(set) var events: [String] = []

    init(store: PluginStore) {
        self.store = store
        mode = store.value(String.self, forKey: Key.mode).flatMap(DisplayMode.init(rawValue:)) ?? .icons
        showWindowTitles = store.value(Bool.self, forKey: Key.titles) ?? true
        maxThumbnails = store.value(Int.self, forKey: Key.maxThumbnails) ?? 12
    }

    func append(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        events.append("\(formatter.string(from: Date()))  \(line)")
        if events.count > 30 {
            events.removeFirst(events.count - 30)
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    func resetAll() {
        store.removeAll()
        mode = .icons
        showWindowTitles = true
        maxThumbnails = 12
        events.removeAll()
    }
}
