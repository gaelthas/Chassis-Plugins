import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct HoverWindow: Identifiable, Sendable, Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect

    var id: CGWindowID { windowID }
}

/// 某个应用（含其 helper 进程）的窗口列表。
///
/// 主路径是该应用的 AX 窗口列表（一个应用一次跨进程查询，带 0.35s 超时兜底）：
/// 只有 AX 才能拿到**最小化**的窗口，而「悬停 Dock 图标还原某个最小化窗口」
/// 正是这个功能最常见的用法。AX 不可用（无响应、隐藏应用、Steam 这类由 helper
/// 渲染窗口的应用）时退回 CGWindowList，并按 Dock2Min 的规则过滤离屏浮层。
enum HoverWindowCatalog {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var knownRealWindows: [pid_t: Set<CGWindowID>] = [:]

    static func windows(for appPID: pid_t, appName: String) -> [HoverWindow] {
        let all = windowList([.optionAll, .excludeDesktopElements])
        let onScreen = windowList([.optionOnScreenOnly, .excludeDesktopElements])
        let onScreenIDs = Set(onScreen.compactMap(windowID(of:)))
        let ownedPIDs = ownedProcessIDs(of: appPID)

        var items = axWindows(
            appPID: appPID,
            appName: appName,
            all: all,
            onScreenIDs: onScreenIDs
        )

        if items.isEmpty {
            items = cgWindows(
                appPID: appPID,
                appName: appName,
                ownedPIDs: ownedPIDs,
                pool: onScreen,
                minSize: 80
            )
            if items.isEmpty {
                // 窗口全部最小化（或应用被 ⌘H）：退回全量列表并过滤离屏浮层。
                items = restrictToRealWindows(
                    cgWindows(
                        appPID: appPID,
                        appName: appName,
                        ownedPIDs: ownedPIDs,
                        pool: all,
                        minSize: 100
                    ),
                    pid: appPID
                )
            }
        }

        recordKnownWindows(pid: appPID, ids: items.map(\.windowID))
        pruneKnownWindows()

        // 与 Dock2Min 的单应用预览一致：按创建顺序（`windowID` 升序）稳定排列，
        // 没有 ID 的排最后。
        return items.sorted { lhs, rhs in
            let left = lhs.windowID == 0 ? UInt32.max : lhs.windowID
            let right = rhs.windowID == 0 ? UInt32.max : rhs.windowID
            return left < right
        }
    }

    // MARK: - AX 主路径

    private static func axWindows(
        appPID: pid_t,
        appName: String,
        all: [[String: Any]],
        onScreenIDs: Set<CGWindowID>
    ) -> [HoverWindow] {
        let app = AXUIElementCreateApplication(appPID)
        // 目标应用无响应时 AX 默认会阻塞数秒，而调用方在串行后台队列里。
        AXUIElementSetMessagingTimeout(app, 0.35)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement], !axWindows.isEmpty else {
            return []
        }

        var result: [HoverWindow] = []
        for axWindow in axWindows {
            // 只要标准窗口：系统对话框与浮动面板不属于可切换的窗口。
            let role = DockIconResolver.stringValue(axWindow, kAXRoleAttribute as String)
            guard role == kAXWindowRole else { continue }
            let subrole = DockIconResolver.stringValue(axWindow, kAXSubroleAttribute as String)
            if subrole == kAXSystemDialogSubrole || subrole == kAXFloatingWindowSubrole { continue }

            guard let frame = DockIconResolver.rect(of: axWindow),
                  frame.width >= 40, frame.height >= 40 else { continue }

            let windowID = axWindowNumber(of: axWindow)
                ?? matchingWindowID(axBounds: frame, pool: all)
                ?? 0
            let title = DockIconResolver.stringValue(axWindow, kAXTitleAttribute as String)
                ?? titleFromCG(windowID: windowID, pool: all)
                ?? ""

            result.append(
                HoverWindow(
                    windowID: windowID,
                    pid: appPID,
                    appName: appName,
                    title: title,
                    bounds: frame
                )
            )
        }
        return result
    }

    private static func axWindowNumber(of window: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.uint32Value
    }

    // MARK: - CGWindowList 兜底

    private static func cgWindows(
        appPID: pid_t,
        appName: String,
        ownedPIDs: Set<pid_t>,
        pool: [[String: Any]],
        minSize: CGFloat
    ) -> [HoverWindow] {
        pool.compactMap { entry -> HoverWindow? in
            guard let ownerPID = ownerPID(of: entry), ownedPIDs.contains(ownerPID),
                  layer(of: entry) == 0,
                  let windowID = windowID(of: entry),
                  let bounds = bounds(of: entry),
                  bounds.width >= minSize, bounds.height >= minSize else {
                return nil
            }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha >= 0.05 else { return nil }

            return HoverWindow(
                windowID: windowID,
                pid: appPID,
                appName: appName,
                title: entry[kCGWindowName as String] as? String ?? "",
                bounds: bounds
            )
        }
    }

    /// 全量列表里混着 staging 面板（微信浮层、Steam 离屏 helper）：
    /// 已知真实窗口 > 最大窗口，两级兜底与 Dock2Min 一致。
    private static func restrictToRealWindows(_ items: [HoverWindow], pid: pid_t) -> [HoverWindow] {
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

    // MARK: - 归属

    /// 应用自身 pid + **位于该 app 包内**的 helper 进程 pid。
    ///
    /// 注意不能向上退两级目录：`/Applications/Safari.app` 退两级会变成 `/`，
    /// 那样会把所有应用都算进来，悬停预览就退化成了窗口切换器。
    private static func ownedProcessIDs(of appPID: pid_t) -> Set<pid_t> {
        var pids: Set<pid_t> = [appPID]
        guard let app = NSRunningApplication(processIdentifier: appPID),
              let bundlePath = app.bundleURL?.standardizedFileURL.path else {
            return pids
        }
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        for candidate in NSWorkspace.shared.runningApplications {
            guard let path = candidate.bundleURL?.standardizedFileURL.path,
                  path == bundlePath || path.hasPrefix(prefix) else { continue }
            pids.insert(candidate.processIdentifier)
        }
        return pids
    }

    // MARK: - 记录

    private static func recordKnownWindows(pid: pid_t, ids: [CGWindowID]) {
        let real = ids.filter { $0 != 0 }
        guard !real.isEmpty else { return }
        stateLock.lock()
        knownRealWindows[pid, default: []].formUnion(real)
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

    /// AX 窗口拿不到 `AXWindowNumber` 时，用位置匹配回 CG 窗口 ID（缩略图要用它）。
    private static func matchingWindowID(axBounds: CGRect, pool: [[String: Any]]) -> CGWindowID? {
        for entry in pool {
            guard let id = windowID(of: entry),
                  layer(of: entry) == 0,
                  let cgBounds = bounds(of: entry) else { continue }
            if abs(cgBounds.minX - axBounds.minX) < 5, abs(cgBounds.minY - axBounds.minY) < 5 {
                return id
            }
        }
        return nil
    }

    private static func titleFromCG(windowID: CGWindowID, pool: [[String: Any]]) -> String? {
        guard windowID != 0 else { return nil }
        for entry in pool where self.windowID(of: entry) == windowID {
            if let title = entry[kCGWindowName as String] as? String, !title.isEmpty { return title }
        }
        return nil
    }
}
