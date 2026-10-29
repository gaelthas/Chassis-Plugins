import ApplicationServices
import CoreGraphics
import Foundation

/// 点击点对应的 Dock 图标标题。
///
/// 用 `AXUIElementCopyElementAtPosition` 从坐标直接穿透到最底层节点，而不是遍历 Dock 的 UI 树：
/// 一次 O(1) 查询代替整棵树遍历，是 Dock2Min 最关键的性能取舍。
/// **这是跨进程同步调用，必须在 `performBackground` 内执行。**
struct DockHit: Sendable {
    let isDock: Bool
    let title: String?
}

enum DockIconResolver {
    /// `dockPID` 由调用方在主线程取好传入：`NSRunningApplication` 不是 Sendable，不能跨线程带。
    static func icon(at point: CGPoint, dockPID: pid_t) -> DockHit {
        guard dockPID > 0 else { return DockHit(isDock: false, title: nil) }

        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)
        guard status == .success, let element = elementRef else {
            return DockHit(isDock: false, title: nil)
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == dockPID else { return DockHit(isDock: false, title: nil) }

        return DockHit(isDock: true, title: title(of: element))
    }

    /// 先读节点自身标题，再向上找父节点：不同 macOS 版本上标题所在的层级并不一致。
    private static func title(of element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let node = current else { return nil }
            if let value = stringAttribute(node, kAXTitleAttribute as String), !value.isEmpty {
                return value
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else {
                return nil
            }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
