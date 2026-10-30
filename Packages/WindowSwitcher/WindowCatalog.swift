import AppKit
import CoreGraphics
import Foundation

/// 一个可切换的窗口快照。全部字段是标量/String，可跨线程传递。
struct SwitcherWindow: Identifiable, Sendable, Hashable {
    let windowID: CGWindowID
    /// 归一后的**常规应用** pid（helper 子进程会被归到它所属的应用）。
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    /// 窗口服务器是否认为它在屏幕上。缩略图要优先处理屏上的窗口。
    let isOnScreen: Bool

    var id: CGWindowID { windowID }
}

/// 把 helper / XPC 子进程归一到所属的常规应用。
///
/// Dock2Min 踩过的坑：Steam Helper 会占住 `frontmostApplication`，Steam 的主窗口也由
/// helper 进程渲染，因此所有基于 pid 的窗口归属都必须先归一。
enum ProcessNormalizer {
    static func regularApplication(pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return regularApplication(resolving: app)
    }

    static func regularApplication(resolving app: NSRunningApplication) -> NSRunningApplication? {
        if app.activationPolicy == .regular { return app }

        let regulars = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        // 1) bundle id 前缀：com.valvesoftware.steam.helper → com.valvesoftware.steam
        let bundleID = app.bundleIdentifier ?? ""
        if !bundleID.isEmpty,
           let match = regulars.first(where: { candidate in
               guard let id = candidate.bundleIdentifier else { return false }
               return bundleID.hasPrefix(id + ".")
           }) {
            return match
        }

        // 2) helper 位于 X.app/Contents/... 内
        if let path = app.bundleURL?.standardizedFileURL.path,
           let match = regulars.first(where: { candidate in
               guard let root = candidate.bundleURL?.standardizedFileURL.path else { return false }
               return path == root || path.hasPrefix(root + "/")
           }) {
            return match
        }

        // 3) 名称前缀：Steam Helper → Steam（最后兜底）
        let name = app.localizedName ?? ""
        if !name.isEmpty,
           let match = regulars.first(where: { candidate in
               guard let candidateName = candidate.localizedName, !candidateName.isEmpty else { return false }
               return name.hasPrefix(candidateName)
           }) {
            return match
        }
        return nil
    }
}

/// 窗口枚举：**只用 CGWindowList**，不在这里调用 AX。
///
/// 这是 1.0.0 能用的实现，也是 1.0.1 换成「每个应用都做 AX 枚举」后 Alt-Tab 卡死的教训：
/// AX 是跨进程 IPC，遇到无响应/异常的应用会长时间阻塞，`performBackground` 是串行队列，
/// 一堵住面板就永远出不来，表现为「⌥Tab 没反应」。AX 只在**激活那一个窗口**时使用。
///
/// ⌘H 隐藏的应用：它的窗口不在屏上列表里，但仍在全量列表里，因此按 Dock2Min 的规则处理——
/// 优先用「该应用曾暴露过的真实窗口」过滤微信浮层/Steam 离屏窗口，没学到时只保留最大窗口。
enum WindowCatalog {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var knownRealWindows: [pid_t: Set<CGWindowID>] = [:]

    static func windows(excludingPID ownPID: pid_t) -> [SwitcherWindow] {
        let all = windowList([.optionAll, .excludeDesktopElements])
        let onScreen = windowList([.optionOnScreenOnly, .excludeDesktopElements])
        let onScreenIDs = Set(onScreen.compactMap(windowID(of:)))

        var helperOwner: [pid_t: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .regular {
            if let parent = ProcessNormalizer.regularApplication(resolving: app) {
                helperOwner[app.processIdentifier] = parent.processIdentifier
            }
        }

        var result: [SwitcherWindow] = []
        var seen = Set<CGWindowID>()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid != ownPID, pid != selfPID else { continue }

            let appName = app.localizedName ?? "Unknown"
            let owned = ownedProcessIDs(app: app, helperOwner: helperOwner)

            var items: [SwitcherWindow] = []
            if app.isHidden {
                // ⌘H：只能用全量列表，再按「已知真实窗口」过滤。
                items = compact(all, app: app, appName: appName, owned: owned, onScreenIDs: onScreenIDs, minSize: 100)
                items = restrictToRealWindows(items, pid: pid)
            } else {
                items = compact(onScreen, app: app, appName: appName, owned: owned, onScreenIDs: onScreenIDs, minSize: 60)
                if items.isEmpty {
                    // 窗口全部最小化：同样退回全量列表。
                    items = compact(all, app: app, appName: appName, owned: owned, onScreenIDs: onScreenIDs, minSize: 100)
                    items = restrictToRealWindows(items, pid: pid)
                }
            }

            guard !items.isEmpty else { continue }
            recordKnownWindows(pid: pid, ids: items.map(\.windowID))
            for item in items where seen.insert(item.windowID).inserted {
                result.append(item)
            }
        }

        pruneKnownWindows()
        return result
    }

    // MARK: - 过滤

    private static func compact(
        _ pool: [[String: Any]],
        app: NSRunningApplication,
        appName: String,
        owned: Set<pid_t>,
        onScreenIDs: Set<CGWindowID>,
        minSize: CGFloat
    ) -> [SwitcherWindow] {
        pool.compactMap { entry in
            guard let owner = ownerPID(of: entry), owned.contains(owner),
                  let id = windowID(of: entry), layer(of: entry) == 0,
                  let bounds = bounds(of: entry),
                  bounds.width >= minSize, bounds.height >= minSize else {
                return nil
            }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha >= 0.05 else { return nil }

            return SwitcherWindow(
                windowID: id,
                pid: app.processIdentifier,
                appName: appName,
                title: entry[kCGWindowName as String] as? String ?? "",
                bounds: bounds,
                isOnScreen: onScreenIDs.contains(id)
            )
        }
    }

    /// 全量列表里混着 staging 面板（微信浮层、Steam 离屏 helper）。
    /// 已知真实窗口 > 最大窗口，两级兜底与 Dock2Min 一致。
    private static func restrictToRealWindows(_ items: [SwitcherWindow], pid: pid_t) -> [SwitcherWindow] {
        guard !items.isEmpty else { return [] }
        let known = knownWindowIDs(pid: pid)
        if !known.isEmpty {
            let matched = items.filter { known.contains($0.windowID) }
            if !matched.isEmpty { return matched }
        }
        if let largest = items.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
            return [largest]
        }
        return []
    }

    // MARK: - 归属与记录

    private static func ownedProcessIDs(app: NSRunningApplication, helperOwner: [pid_t: pid_t]) -> Set<pid_t> {
        var pids: Set<pid_t> = [app.processIdentifier]
        for (helper, owner) in helperOwner where owner == app.processIdentifier {
            pids.insert(helper)
        }
        return pids
    }

    private static func recordKnownWindows(pid: pid_t, ids: [CGWindowID]) {
        guard !ids.isEmpty else { return }
        stateLock.lock()
        knownRealWindows[pid, default: []].formUnion(ids)
        stateLock.unlock()
    }

    private static func knownWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return knownRealWindows[pid] ?? []
    }

    private static func pruneKnownWindows() {
        stateLock.lock()
        knownRealWindows = knownRealWindows.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        stateLock.unlock()
    }

    // MARK: - CG 字段读取

    private static func windowList(_ options: CGWindowListOption) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func windowID(of entry: [String: Any]) -> CGWindowID? {
        (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    private static func ownerPID(of entry: [String: Any]) -> pid_t? {
        (entry[kCGWindowOwnerPID as String] as? NSNumber).map { pid_t($0.int32Value) }
    }

    private static func layer(of entry: [String: Any]) -> Int {
        (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    }

    private static func bounds(of entry: [String: Any]) -> CGRect? {
        (entry[kCGWindowBounds as String] as? NSDictionary)
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }
}
