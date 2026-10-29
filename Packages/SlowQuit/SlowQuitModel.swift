import Foundation
import Observation
import PluginAPI

/// 「长按 ⌘Q 才退出」的配置。阈值来自 Dock2Min 的 0.5–5 秒区间。
@MainActor
@Observable
final class SlowQuitModel {
    private enum Key {
        static let enabled = "quit.enabled"
        static let threshold = "quit.threshold"
        static let showHUD = "quit.showHUD"
    }

    @ObservationIgnored private let store: PluginStore

    /// tap 线程唯一可读的状态：是否吞掉 ⌘Q。只能通过 AtomicFlag 共享。
    let consumeFlag = AtomicFlag(false)

    var enabled: Bool {
        didSet {
            store.set(enabled, forKey: Key.enabled)
            consumeFlag.value = enabled
        }
    }

    /// 需要持续按住的秒数。
    var threshold: Double {
        didSet { store.set(threshold, forKey: Key.threshold) }
    }

    var showProgressHUD: Bool {
        didSet { store.set(showProgressHUD, forKey: Key.showHUD) }
    }

    private(set) var events: [String] = []

    init(store: PluginStore) {
        self.store = store
        enabled = store.value(Bool.self, forKey: Key.enabled) ?? true
        threshold = store.value(Double.self, forKey: Key.threshold) ?? 1.0
        showProgressHUD = store.value(Bool.self, forKey: Key.showHUD) ?? true
        consumeFlag.value = enabled
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
        threshold = 1.0
        showProgressHUD = true
        events.removeAll()
    }
}
