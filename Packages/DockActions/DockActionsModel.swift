import Foundation
import Observation
import PluginAPI

/// Dock2Min 的「点击最小化 + Dock 快捷键」合并为一个插件：两者共用 Dock 命中判定、
/// 应用名单与 AX 最小化能力，拆成两个插件只会重复一份实现。
@MainActor
@Observable
final class DockActionsModel {
    enum RulesMode: String, Codable, CaseIterable {
        case off
        case blacklist
        case whitelist
    }

    enum ModifierPreset: String, Codable, CaseIterable {
        case optionCommand
        case controlOption
        case commandShift
        case controlOptionCommand

        var modifiers: HotKeyModifiers {
            switch self {
            case .optionCommand: [.option, .command]
            case .controlOption: [.control, .option]
            case .commandShift: [.command, .shift]
            case .controlOptionCommand: [.control, .option, .command]
            }
        }

        var displayText: String {
            switch self {
            case .optionCommand: "⌥⌘"
            case .controlOption: "⌃⌥"
            case .commandShift: "⌘⇧"
            case .controlOptionCommand: "⌃⌥⌘"
            }
        }
    }

    private enum Key {
        static let clickToMinimize = "click.enabled"
        static let shortcutsEnabled = "shortcuts.enabled"
        static let exitFullScreenFirst = "click.exitFullScreenFirst"
        static let rulesMode = "rules.mode"
        static let ruleBundleIDs = "rules.bundleIDs"
        static let modifierPreset = "shortcuts.modifiers"
    }

    @ObservationIgnored private let store: PluginStore

    var clickToMinimize: Bool {
        didSet { store.set(clickToMinimize, forKey: Key.clickToMinimize) }
    }

    var shortcutsEnabled: Bool {
        didSet { store.set(shortcutsEnabled, forKey: Key.shortcutsEnabled) }
    }

    var exitFullScreenFirst: Bool {
        didSet { store.set(exitFullScreenFirst, forKey: Key.exitFullScreenFirst) }
    }

    var rulesMode: RulesMode {
        didSet { store.set(rulesMode.rawValue, forKey: Key.rulesMode) }
    }

    var ruleBundleIDs: [String] {
        didSet { store.set(ruleBundleIDs, forKey: Key.ruleBundleIDs) }
    }

    var modifierPreset: ModifierPreset {
        didSet { store.set(modifierPreset.rawValue, forKey: Key.modifierPreset) }
    }

    private(set) var lastError: String?
    private(set) var events: [String] = []

    init(store: PluginStore) {
        self.store = store
        clickToMinimize = store.value(Bool.self, forKey: Key.clickToMinimize) ?? true
        shortcutsEnabled = store.value(Bool.self, forKey: Key.shortcutsEnabled) ?? true
        exitFullScreenFirst = store.value(Bool.self, forKey: Key.exitFullScreenFirst) ?? true
        rulesMode = store.value(String.self, forKey: Key.rulesMode).flatMap(RulesMode.init(rawValue:)) ?? .off
        ruleBundleIDs = store.value([String].self, forKey: Key.ruleBundleIDs) ?? []
        modifierPreset = store.value(String.self, forKey: Key.modifierPreset).flatMap(ModifierPreset.init(rawValue:)) ?? .optionCommand
    }

    /// 名单只影响「点击最小化」；快捷键是用户显式操作，不做拦截。
    func allows(bundleID: String?) -> Bool {
        guard let bundleID, rulesMode != .off else { return true }
        let listed = ruleBundleIDs.contains(bundleID)
        return rulesMode == .blacklist ? !listed : listed
    }

    func setError(_ message: String?) {
        lastError = message
    }

    func append(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        events.append("\(formatter.string(from: Date()))  \(line)")
        if events.count > 40 {
            events.removeFirst(events.count - 40)
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    func resetAll() {
        store.removeAll()
        clickToMinimize = true
        shortcutsEnabled = true
        exitFullScreenFirst = true
        rulesMode = .off
        ruleBundleIDs = []
        modifierPreset = .optionCommand
        lastError = nil
        events.removeAll()
    }
}
