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

    var id: CGWindowID { windowID }
}

/// 把 helper / XPC 子进程归一到所属的常规应用。
///
/// 不归一就会出现 Dock2Min 反复踩的坑：Steam Helper 之类的子进程占住 frontmost，
/// 于是窗口列表里出现无法激活的条目、⌘Q 退错对象。
enum ProcessNormalizer {
    static func regularApplication(pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if app.activationPolicy == .regular { return app }

        if let url = app.bundleURL?.standardizedFileURL {
            if let owner = NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL == url
            }) {
                return owner
            }
            // helper 通常位于 X.app/Contents/Library/...：用上两级目录兜底。
            let container = url.deletingLastPathComponent().deletingLastPathComponent()
            if let owner = NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular
                    && ($0.bundleURL?.standardizedFileURL.path.hasPrefix(container.path) ?? false)
            }) {
                return owner
            }
        }

        if let bundleID = app.bundleIdentifier,
           let owner = NSWorkspace.shared.runningApplications.first(where: {
               $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
           }) {
            return owner
        }
        return nil
    }
}

/// 窗口枚举。
///
/// `CGWindowListCopyWindowInfo` 与 AX 不同，不需要辅助功能授权；但读取窗口标题需要屏幕录制，
/// 因此标题为空时退回应用名。整段调用放进 `performBackground`（可能是跨进程 IPC）。
enum WindowCatalog {
    /// 系统 UI 进程，不应出现在切换列表里。
    private static let excludedOwners: Set<String> = [
        "Dock", "Window Server", "Control Center", "Notification Center", "Spotlight",
        "TextInputMenuAgent", "Universal Control",
    ]

    static func windows(excludingPID ownPID: pid_t) -> [SwitcherWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result: [SwitcherWindow] = []
        result.reserveCapacity(list.count)

        for entry in list {
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0 else {
                continue
            }

            let ownerPID = pid_t(pidNumber.int32Value)
            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            guard ownerPID != ownPID, !excludedOwners.contains(ownerName) else { continue }

            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.2 else { continue }

            let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary
            let bounds = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard bounds.width >= 60, bounds.height >= 60 else { continue }

            // 归一：过滤掉无法激活的 helper 窗口，并把 pid 换成真正要激活的应用。
            guard let app = ProcessNormalizer.regularApplication(pid: ownerPID),
                  app.processIdentifier != ownPID else {
                continue
            }

            let title = entry[kCGWindowName as String] as? String ?? ""
            result.append(
                SwitcherWindow(
                    windowID: windowID,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? ownerName,
                    title: title,
                    bounds: bounds
                )
            )
        }

        return result
    }
}
