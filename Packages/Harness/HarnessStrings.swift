import Foundation

/// 插件文案一律查自己的 bundle；基座渲染插件信息时用 `manifest.resourceBundle`，插件内部用这里。
enum HarnessStrings {
    static func t(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }
}
