import AppKit
import Foundation

/// Dock 上第 N 个位置对应的应用，用于「⌥⌘1~9 打开第 N 个应用」。
struct DockAppSlot: Sendable {
    let name: String
    let bundleID: String?
    let url: URL?
}

/// Dock 上应用的顺序。
///
/// 读 `com.apple.dock` 的 `persistent-apps` 而不是遍历 AX 树：无权限、无 IPC、O(1) 解析。
/// 语义边界：只包含被固定在 Dock 上的 .app，不包含「最近使用」区域的临时图标。
enum DockAppOrder {
    /// 访达永远停在 Dock 最左侧，却**不在** `persistent-apps` 里。
    ///
    /// 这是「按 1 却打开了启动台」的根因：只读偏好列表时第 1 个位置被启动台占走，
    /// 而视觉上的第 1 个是它左边的访达。Dock2Min 的 `getDockPersistentApps()` 同样在
    /// 读取结果前手动插入 `com.apple.finder`，这里沿用同一做法。
    static let finderBundleID = "com.apple.finder"
    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    static func apps() -> [DockAppSlot] {
        var slots: [DockAppSlot] = [finderSlot()]

        guard let raw = CFPreferencesCopyAppValue(
            "persistent-apps" as CFString,
            "com.apple.dock" as CFString
        ) as? [[String: Any]] else {
            return slots
        }

        for tile in raw {
            guard let slot = appSlot(from: tile) else { continue }
            // 访达理论上不会出现在这里；出现也不要让它占两个位置。
            if slot.bundleID == finderBundleID { continue }
            slots.append(slot)
        }
        return slots
    }

    // MARK: - 解析

    private static func finderSlot() -> DockAppSlot {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: finderBundleID)
            .first
        return DockAppSlot(
            name: running?.localizedName ?? "Finder",
            bundleID: finderBundleID,
            url: finderURL
        )
    }

    private static func appSlot(from tile: [String: Any]) -> DockAppSlot? {
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
        // 与应用包对不上时（例如所在宗卷尚未挂载）退回偏好里的 `bundle-identifier`。
        let bundleID = Bundle(url: url)?.bundleIdentifier
            ?? (tileData["bundle-identifier"] as? String)
        return DockAppSlot(name: label, bundleID: bundleID, url: url)
    }
}
