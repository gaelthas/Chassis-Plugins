import Foundation

enum DockActionsStrings {
    static func t(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }
}
