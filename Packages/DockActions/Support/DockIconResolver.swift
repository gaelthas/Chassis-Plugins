import ApplicationServices
import CoreGraphics
import Foundation

/// 点击点对应的 Dock 图标：所属应用包 URL + 标题。
///
/// 用 `AXUIElementCopyElementAtPosition` 从坐标直接穿透到最底层节点，而不是遍历 Dock 的 UI 树：
/// 一次 O(1) 查询代替整棵树遍历，是 Dock2Min 最关键的性能取舍。
/// **这是跨进程同步调用，必须在 `performBackground` 内执行。**
struct DockHit: Sendable {
    let isDock: Bool
    let title: String?
    /// 图标对应的应用包（`AXURL`）。Dock 标签可能被重命名/本地化，
    /// 拿 URL 与应用路径比对比名字匹配可靠得多。
    let url: URL?
}

enum DockIconResolver {
    /// `dockPID` 由调用方在主线程取好传入：`NSRunningApplication` 不是 Sendable，不能跨线程带。
    static func icon(at point: CGPoint, dockPID: pid_t) -> DockHit {
        guard dockPID > 0 else { return DockHit(isDock: false, title: nil, url: nil) }

        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)
        guard status == .success, let element = elementRef else {
            return DockHit(isDock: false, title: nil, url: nil)
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == dockPID else { return DockHit(isDock: false, title: nil, url: nil) }

        return DockHit(isDock: true, title: title(of: element), url: url(of: element))
    }

    /// 先读节点自身标题，再向上找父节点：不同 macOS 版本上标题所在的层级并不一致。
    private static func title(of element: AXUIElement) -> String? {
        for node in ancestors(of: element) {
            if let value = stringAttribute(node, kAXTitleAttribute as String), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// 图标 URL 同样可能落在任意一层：与 Dock2Min 一致向上找 8 层。
    private static func url(of element: AXUIElement) -> URL? {
        for node in ancestors(of: element, depth: 8) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &value) == .success,
                  let raw = value else { continue }
            if let url = raw as? URL { return url }
            if let string = raw as? String, let url = URL(string: string) { return url }
        }
        return nil
    }

    private static func ancestors(of element: AXUIElement, depth: Int = 4) -> [AXUIElement] {
        var nodes: [AXUIElement] = []
        var current: AXUIElement? = element
        for _ in 0..<depth {
            guard let node = current else { break }
            nodes.append(node)
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else {
                break
            }
            current = (parent as! AXUIElement)
        }
        return nodes
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
