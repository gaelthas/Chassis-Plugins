import Foundation
import Observation
import PluginAPI

@MainActor
@Observable
final class DockHoverModel {
    enum DisplayMode: String, Codable, CaseIterable {
        case icons
        case thumbnails
    }

    private enum Key {
        static let enabled = "hover.enabled"
        static let mode = "hover.mode"
        static let maxWindows = "hover.maxWindows"
        static let delay = "hover.delay"
        static let titles = "hover.showTitles"
    }

    @ObservationIgnored private let store: PluginStore

    var enabled: Bool {
        didSet { store.set(enabled, forKey: Key.enabled) }
    }

    var mode: DisplayMode {
        didSet { store.set(mode.rawValue, forKey: Key.mode) }
    }

    var maxWindows: Int {
        didSet { store.set(maxWindows, forKey: Key.maxWindows) }
    }

    /// 悬停多久才弹出（秒）。太短会在扫过 Dock 时连续闪现。
    var hoverDelay: Double {
        didSet { store.set(hoverDelay, forKey: Key.delay) }
    }

    var showWindowTitles: Bool {
        didSet { store.set(showWindowTitles, forKey: Key.titles) }
    }

    private(set) var events: [String] = []

    init(store: PluginStore) {
        self.store = store
        enabled = store.value(Bool.self, forKey: Key.enabled) ?? true
        mode = store.value(String.self, forKey: Key.mode).flatMap(DisplayMode.init(rawValue:)) ?? .icons
        maxWindows = store.value(Int.self, forKey: Key.maxWindows) ?? 6
        hoverDelay = store.value(Double.self, forKey: Key.delay) ?? 0.25
        showWindowTitles = store.value(Bool.self, forKey: Key.titles) ?? true
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
        enabled = true
        mode = .icons
        maxWindows = 6
        hoverDelay = 0.25
        showWindowTitles = true
        events.removeAll()
    }
}
