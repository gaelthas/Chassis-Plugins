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
}
