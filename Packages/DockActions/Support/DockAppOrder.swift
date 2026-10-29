import Foundation

/// Dock 上固定（非运行中）应用的顺序，用于「⌥⌘1~9 打开第 N 个应用」。
///
/// 读 `com.apple.dock` 的 `persistent-apps` 而不是遍历 AX 树：无权限、无 IPC、O(1) 解析。
/// 语义边界：只包含被固定在 Dock 上的 .app，不包含「最近使用」区域的临时图标。
struct DockAppSlot: Sendable {
    let name: String
    let bundleID: String?
    let url: URL?
}

enum DockAppOrder {
    static func apps() -> [DockAppSlot] {
        guard let raw = CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] else {
            return []
        }

        return raw.compactMap { tile -> DockAppSlot? in
            guard let tileData = tile["tile-data"] as? [String: Any],
                  let fileData = tileData["file-data"] as? [String: Any],
                  let urlString = fileData["_CFURLString"] as? String,
                  let url = URL(string: urlString), url.isFileURL else {
                return nil
            }
            // 只取应用程序（排除文件夹、分隔符、URL 等 tile）
            guard url.pathExtension.lowercased() == "app" else { return nil }

            let label = (tileData["file-label"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return DockAppSlot(name: label, bundleID: Bundle(url: url)?.bundleIdentifier, url: url)
        }
    }
}
