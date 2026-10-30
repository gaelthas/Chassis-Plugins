import AppKit
import ApplicationServices
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
        if let url = app.bundleURL?.standardizedFileURL {
            let path = url.path
            if let match = regulars.first(where: { candidate in
                guard let root = candidate.bundleURL?.standardizedFileURL.path else { return false }
                return path == root || path.hasPrefix(root + "/")
            }) {
                return match
            }
        }

        // 3) 名称前缀：Steam Helper → Steam（最后兜底，可能误配，放在最后）
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

/// 窗口枚举。
///
/// 与 Dock2Min `WindowProvider.getWindows` 对齐的三段式：
/// 1. AX 枚举每个常规应用的真实窗口（含最小化窗口；可见应用最容易拿到）；
/// 2. 用 bounds 把 AX 窗口匹配到 CGWindowID；
/// 3. AX 拿不到（⌘H 隐藏、Steam 只暴露 1×1 假窗口）时退回 CGWindowList：
///    隐藏应用用全量列表，并且优先用「该应用曾经暴露过的真实窗口」过滤掉
///    微信浮层、Steam 离屏 helper 这类假窗口；没有记录时只保留最大窗口。
///
/// 整段调用放进 `performBackground`（AX 是跨进程 IPC）。
enum WindowCatalog {
    /// 每个应用最近一次通过 AX 确认过的真实窗口。隐藏应用的 CG 回退用它过滤假窗口。
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var knownRealWindows: [pid_t: Set<CGWindowID>] = [:]

    private struct AXWindowSnapshot {
        let bounds: CGRect
        let title: String
    }

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

            // 快路径：屏上窗口直接取 CGWindowList（毫秒级）。
            // AX 只对「没有屏上窗口」的应用使用（⌘H 隐藏、窗口全部最小化）；
            // 否则每个应用一次 AX IPC 会让 ⌥Tab 明显变慢，甚至错过松开 ⌥ 的时机。
            var items = visibleWindows(
                in: onScreen,
                app: app,
                appName: appName,
                owned: owned
            )
            if items.isEmpty {
                items = matchedAXWindows(
                    app: app,
                    appName: appName,
                    pool: all,
                    onScreenIDs: onScreenIDs,
                    owned: owned
                )
            }
            if items.isEmpty {
                items = fallbackWindows(
                    app: app,
                    appName: appName,
                    all: all,
                    onScreen: onScreen,
                    onScreenIDs: onScreenIDs,
                    owned: owned
                )
            }
            if !items.isEmpty {
                recordKnownWindows(pid: pid, ids: items.map(\.windowID))
            }
            for item in items where seen.insert(item.windowID).inserted {
                result.append(item)
            }
        }

        pruneKnownWindows()
        return result
    }

    // MARK: - 快路径

    /// 屏上窗口：CG 列表本身就是前到后的 z 序，不需要 AX。
    private static func visibleWindows(
        in pool: [[String: Any]],
        app: NSRunningApplication,
        appName: String,
        owned: Set<pid_t>
    ) -> [SwitcherWindow] {
        pool.compactMap { entry in
            guard let owner = ownerPID(of: entry), owned.contains(owner),
                  let id = windowID(of: entry), layer(of: entry) == 0,
                  let bounds = bounds(of: entry), bounds.width >= 60, bounds.height >= 60 else {
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
                isOnScreen: true
            )
        }
    }

    // MARK: - AX 路径

    private static func matchedAXWindows(
        app: NSRunningApplication,
        appName: String,
        pool: [[String: Any]],
        onScreenIDs: Set<CGWindowID>,
        owned: Set<pid_t>
    ) -> [SwitcherWindow] {
        let snapshots = axSnapshots(pid: app.processIdentifier)
        guard !snapshots.isEmpty else { return [] }

        var items: [SwitcherWindow] = []
        var used = Set<CGWindowID>()

        for snapshot in snapshots {
            let match = pool.first { entry in
                guard let owner = ownerPID(of: entry), owned.contains(owner),
                      let id = windowID(of: entry), !used.contains(id),
                      layer(of: entry) == 0,
                      let bounds = bounds(of: entry),
                      // AX 与 CG 的坐标都相对主屏左上角，5pt 容差足够区分同应用的窗口。
                      abs(bounds.minX - snapshot.bounds.minX) < 5,
                      abs(bounds.minY - snapshot.bounds.minY) < 5 else {
                    return false
                }
                return true
            }
            guard let match, let id = windowID(of: match) else { continue }

            used.insert(id)
            let cgTitle = match[kCGWindowName as String] as? String ?? ""
            items.append(
                SwitcherWindow(
                    windowID: id,
                    pid: app.processIdentifier,
                    appName: appName,
                    title: snapshot.title.isEmpty ? cgTitle : snapshot.title,
                    bounds: snapshot.bounds,
                    isOnScreen: onScreenIDs.contains(id)
                )
            )
        }
        return items
    }

    /// AX 枚举真实窗口：排除对话框/浮动面板，跳过 1×1 假窗口（Steam 会停一个在屏幕外）。
    private static func axSnapshots(pid: pid_t) -> [AXWindowSnapshot] {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }

        var result: [AXWindowSnapshot] = []
        result.reserveCapacity(windows.count)

        for window in windows {
            guard let role = stringAttribute(window, kAXRoleAttribute), role == kAXWindowRole else { continue }

            let subrole = stringAttribute(window, kAXSubroleAttribute)
            if subrole == kAXSystemDialogSubrole || subrole == kAXFloatingWindowSubrole { continue }

            var position = CGPoint.zero
            var size = CGSize.zero
            if let positionValue = pointAttribute(window, kAXPositionAttribute) { position = positionValue }
            if let sizeValue = sizeAttribute(window, kAXSizeAttribute) { size = sizeValue }

            // 1×1 占位窗口：Steam 的真实窗口由 helper 渲染，AX 只给这个。
            guard size.width >= 2, size.height >= 2 else { continue }

            result.append(
                AXWindowSnapshot(
                    bounds: CGRect(origin: position, size: size),
                    title: stringAttribute(window, kAXTitleAttribute) ?? ""
                )
            )
        }
        return result
    }

    // MARK: - CGWindowList 回退

    private static func fallbackWindows(
        app: NSRunningApplication,
        appName: String,
        all: [[String: Any]],
        onScreen: [[String: Any]],
        onScreenIDs: Set<CGWindowID>,
        owned: Set<pid_t>
    ) -> [SwitcherWindow] {
        func poolItems(_ pool: [[String: Any]]) -> [SwitcherWindow] {
            pool.compactMap { entry in
                guard let owner = ownerPID(of: entry), owned.contains(owner),
                      let id = windowID(of: entry), layer(of: entry) == 0,
                      let bounds = bounds(of: entry), bounds.width >= 100, bounds.height >= 100 else {
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

        // 可见应用只用屏上窗口：这样微信的浮层、Steam 的离屏 helper 不会混进来。
        // 隐藏应用（⌘H）根本没有屏上窗口，只能用全量列表，再靠「曾经的真实窗口」过滤。
        var items = poolItems(app.isHidden ? all : onScreen)
        var usedFullList = app.isHidden

        if items.isEmpty {
            items = poolItems(all)
            usedFullList = true
        }

        if usedFullList, !items.isEmpty {
            let known = knownWindowIDs(pid: app.processIdentifier)
            let matched = items.filter { known.contains($0.windowID) }
            if !matched.isEmpty {
                items = matched
            } else if let largest = items.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                // 还没学到真实窗口集合：只暴露最大窗口，避免把 staging 面板列出来。
                items = [largest]
            }
        }

        return items
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

    // MARK: - AX 字段读取

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}
