import AppKit
import Foundation

/// ⌘Q 的真正目标。
///
/// Dock2Min 的教训：`frontmostApplication` 可能是一个 accessory helper
/// （Steam 运行期间一直是 `Steam Helper` 占着这个位置）。直接 `terminate()`
/// 只会杀掉 helper，Steam 立刻把它拉起来，表现为「按了没反应」。
/// 这里把 helper 归一成它所属的常规应用。
enum SlowQuitTargetResolver {
    static func resolve(frontmost: NSRunningApplication?) -> NSRunningApplication? {
        guard let frontmost else { return nil }
        if frontmost.activationPolicy == .regular { return frontmost }

        let regulars = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        // 1) bundle id 前缀：com.valvesoftware.steam.helper → com.valvesoftware.steam
        let bundleID = frontmost.bundleIdentifier ?? ""
        if !bundleID.isEmpty,
           let match = regulars.first(where: { candidate in
               guard let id = candidate.bundleIdentifier else { return false }
               return bundleID.hasPrefix(id + ".")
           }) {
            return match
        }

        // 2) helper 位于 X.app/Contents/... 内
        if let path = frontmost.bundleURL?.standardizedFileURL.path {
            if let match = regulars.first(where: { candidate in
                guard let root = candidate.bundleURL?.standardizedFileURL.path else { return false }
                return path == root || path.hasPrefix(root + "/")
            }) {
                return match
            }
        }

        // 3) 名称前缀：Steam Helper → Steam
        let name = frontmost.localizedName ?? ""
        if !name.isEmpty,
           let match = regulars.first(where: { candidate in
               guard let candidateName = candidate.localizedName, !candidateName.isEmpty else { return false }
               return name.hasPrefix(candidateName)
           }) {
            return match
        }

        // 无法归一：保持原样（例如纯菜单栏工具，用户确实想退出它）。
        return frontmost
    }
}
