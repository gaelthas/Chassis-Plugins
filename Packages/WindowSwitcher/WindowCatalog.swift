import AppKit
import CoreGraphics
import Foundation

/// 一个可切换的窗口快照。全部字段是标量/String，可跨线程传递。
struct SwitcherWindow: Identifiable, Sendable, Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect

    var id: CGWindowID { windowID }
}

/// 窗口枚举。
///
/// `CGWindowListCopyWindowInfo` 与 AX 不同，不需要辅助功能授权；但读取窗口标题需要屏幕录制，
/// 因此标题为空时退回应用名。整段调用放进 `performBackground`（可能是跨进程 IPC）。
enum WindowCatalog {
    /// 系统 UI 进程，不应出现在切换列表里。
    private static let excludedOwners: Set<String> = [
        "Dock", "Window Server", "Control Center", "Notification Center", "Spotlight",
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

            let pid = pid_t(pidNumber.int32Value)
            guard pid != ownPID else { continue }

            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            guard !excludedOwners.contains(ownerName) else { continue }

            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.2 else { continue }

            let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary
            let bounds = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard bounds.width >= 60, bounds.height >= 60 else { continue }

            let title = entry[kCGWindowName as String] as? String ?? ""
            result.append(
                SwitcherWindow(
                    windowID: windowID,
                    pid: pid,
                    appName: ownerName,
                    title: title,
                    bounds: bounds
                )
            )
        }

        return result
    }
}
