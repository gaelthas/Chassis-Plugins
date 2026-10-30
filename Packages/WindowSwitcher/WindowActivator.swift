import AppKit
import ApplicationServices
import Foundation

/// 精确激活到「某一个窗口」而不是只激活应用。
///
/// 对齐 Dock2Min `WindowActivator` 的两条关键行为：
/// 1. 先 `unhide()` 再激活——⌘H 隐藏的应用不 unhide 的话，窗口根本不会回来；
/// 2. 隐藏应用刚 unhide 时 AX 还没暴露窗口，需要等一小会儿再按 frame 重试匹配。
enum WindowActivator {
    @discardableResult
    static func activate(window: SwitcherWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return false }

        let wasHidden = app.isHidden
        if wasHidden {
            app.unhide()
        }
        _ = app.activate()

        if raiseIfFound(window: window) { return true }

        // 隐藏应用：unhide 是异步的，AX 需要一点时间才重新暴露窗口。
        // 调用方在 performBackground 的串行队列里，这里的等待不会卡主线程。
        guard wasHidden else { return true }
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.2)
            if raiseIfFound(window: window) { return true }
        }
        // 实在匹配不到：unhide + activate 已经把应用带到前台，剩余由系统决定焦点窗口。
        return true
    }

    private static func raiseIfFound(window: SwitcherWindow) -> Bool {
        let axApp = AXUIElementCreateApplication(window.pid)
        guard let axWindows = windows(of: axApp) else { return false }

        // 优先 AXWindowNumber（少数应用不提供），其次 bounds，最后标题。
        if let target = axWindows.first(where: { windowNumber(of: $0) == window.windowID }) {
            raise(target)
            return true
        }
        if let target = axWindows.first(where: { axFrame(of: $0).map { matches($0, window.bounds) } ?? false }) {
            raise(target)
            return true
        }
        if !window.title.isEmpty,
           let target = axWindows.first(where: { title(of: $0) == window.title }) {
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
