import AppKit
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

enum HoverWindowCatalog {
    /// 某个应用（含其 helper 进程）的所有可见窗口，按 CGWindowList 的前后顺序。
    static func windows(for appPID: pid_t, appName: String) -> [HoverWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownedPIDs = ownedProcessIDs(of: appPID)
        var result: [HoverWindow] = []

        for entry in list {
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0 else {
                continue
            }

            let ownerPID = pid_t(pidNumber.int32Value)
            guard ownedPIDs.contains(ownerPID) else { continue }

            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.2 else { continue }

            let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary
            let bounds = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            guard bounds.width >= 80, bounds.height >= 60 else { continue }

            let title = entry[kCGWindowName as String] as? String ?? ""
            result.append(
                HoverWindow(
                    windowID: windowID,
                    pid: appPID,
                    appName: appName,
                    title: title,
                    bounds: bounds
                )
            )
        }

        return result
    }

    /// 应用自身 pid + 同 bundle 的 helper 进程 pid。
    private static func ownedProcessIDs(of appPID: pid_t) -> Set<pid_t> {
        var pids: Set<pid_t> = [appPID]
        guard let app = NSRunningApplication(processIdentifier: appPID),
              let container = app.bundleURL?.standardizedFileURL else {
            return pids
        }
        let root = container.deletingLastPathComponent().deletingLastPathComponent().path
        for candidate in NSWorkspace.shared.runningApplications {
            guard let url = candidate.bundleURL?.standardizedFileURL.path, url.hasPrefix(root) else { continue }
            pids.insert(candidate.processIdentifier)
        }
        return pids
    }
}
