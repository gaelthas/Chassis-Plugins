import AppKit
import ApplicationServices
import Foundation

/// 精确激活到指定窗口：应用级激活无法保证多窗口时目标窗口在最前。
/// 全部为 AX 跨进程调用，必须在 `performBackground` 内执行。
enum WindowActivator {
    @discardableResult
    static func activate(window: HoverWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return false }
        let wasHidden = app.isHidden
        app.unhide()
        _ = app.activate()

        if raiseIfFound(window: window) { return true }

        // 隐藏应用：unhide 是异步的，AX 需要一点时间才重新暴露窗口。
        guard wasHidden else { return true }
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.2)
            if raiseIfFound(window: window) { return true }
        }
        return true
    }

    private static func raiseIfFound(window: HoverWindow) -> Bool {
        let axApp = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        guard let axWindows = windows(of: axApp) else { return false }

        if let target = axWindows.first(where: { windowNumber(of: $0) == window.windowID }) {
            raise(target)
            return true
        }
        if let target = axWindows.first(where: { axFrame(of: $0).map { matches($0, window.bounds) } ?? false }) {
            raise(target)
            return true
        }
        if !window.title.isEmpty, let target = axWindows.first(where: { title(of: $0) == window.title }) {
            raise(target)
            return true
        }
        return false
    }

    private static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 5 && abs(lhs.minY - rhs.minY) < 5
    }

    private static func raise(_ window: AXUIElement) {
        // 最小化窗口必须先还原，否则 raise 只会在 Dock 里闪一下。
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
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

    private static func axFrame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var value: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let positionValue = value else {
            return nil
        }
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)

        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
           let sizeValue = value {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }
}
