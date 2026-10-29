import AppKit
import ApplicationServices
import Foundation

/// 精确激活到指定窗口：应用级激活无法保证多窗口时目标窗口在最前。
/// 全部为 AX 跨进程调用，必须在 `performBackground` 内执行。
enum WindowActivator {
    @discardableResult
    static func activate(window: HoverWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return false }
        app.unhide()
        _ = app.activate()

        let axApp = AXUIElementCreateApplication(window.pid)
        guard let axWindows = windows(of: axApp) else { return true }

        if let target = axWindows.first(where: { windowNumber(of: $0) == window.windowID }) {
            raise(target)
            return true
        }
        if !window.title.isEmpty, let target = axWindows.first(where: { title(of: $0) == window.title }) {
            raise(target)
            return true
        }
        return true
    }

    private static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func windowNumber(of window: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.uint32Value
    }

    private static func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
