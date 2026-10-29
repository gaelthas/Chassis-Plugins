import ApplicationServices
import Foundation

/// 窗口的最小化/可见性查询。全部是跨进程同步 AX 调用，**必须在 `performBackground` 内执行**。
enum AXWindowOps {
    /// 返回被最小化的窗口数量。
    static func minimizeAllWindows(pid: pid_t, exitFullScreenFirst: Bool) -> Int {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = windows(of: app) else { return 0 }

        var count = 0
        for window in windows {
            if exitFullScreenFirst, boolValue(window, "AXFullScreen") == true {
                // 先退出全屏再最小化：全屏窗口直接设 minimized 在部分版本上无效。
                _ = setBool(window, "AXFullScreen", false)
            }
            if setBool(window, kAXMinimizedAttribute as String, true) {
                count += 1
            }
        }
        return count
    }

    /// 是否有未最小化的窗口。用于「点击前的世界」判断：已经最小化的应用不该再被最小化。
    static func hasVisibleWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = windows(of: app) else { return false }

        for window in windows {
            if boolValue(window, kAXMinimizedAttribute as String) == false {
                return true
            }
        }
        return false
    }

    /// 前台应用的主窗口标题（仅用于事件日志，不写盘、不进诊断包）。
    static func windowCount(pid: pid_t) -> Int {
        windows(of: AXUIElementCreateApplication(pid))?.count ?? 0
    }

    // MARK: - 私有

    private static func windows(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean) == .success
    }
}
