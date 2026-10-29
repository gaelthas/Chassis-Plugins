import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 点击/悬停点对应的 Dock 图标：标题 + 图标在屏幕上的位置（AX 左上坐标系）。
struct DockIconHit: Sendable {
    let isDock: Bool
    let title: String?
    let frame: CGRect?
}

/// Dock 边缘带初筛：悬停事件频率高，能不做跨进程查询就不做。
enum DockGeometry {
    static let band: CGFloat = 180

    static func isNearDockBand(_ point: CGPoint, band: CGFloat = band) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        guard primaryHeight > 0 else { return true }

        for screen in NSScreen.screens {
            let frame = screen.frame
            let top = primaryHeight - frame.maxY
            let rect = CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height)
            guard rect.insetBy(dx: -1, dy: -1).contains(point) else { continue }
            if point.x - rect.minX <= band || rect.maxX - point.x <= band || rect.maxY - point.y <= band {
                return true
            }
        }
        return false
    }
}

/// 读取 Dock 图标节点：`AXUIElementCopyElementAtPosition` 一次穿透，避免遍历 UI 树。
/// **必须在 `performBackground` 内执行。**
enum DockIconResolver {
    static func icon(at point: CGPoint, dockPID: pid_t) -> DockIconHit {
        guard dockPID > 0 else { return DockIconHit(isDock: false, title: nil, frame: nil) }

        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else {
            return DockIconHit(isDock: false, title: nil, frame: nil)
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == dockPID else { return DockIconHit(isDock: false, title: nil, frame: nil) }

        // 标题与位置可能在同一节点，也可能分别落在父节点上。
        var titleNode: AXUIElement? = element
        var title: String?
        for _ in 0..<4 {
            guard let node = titleNode else { break }
            if let value = stringValue(node, kAXTitleAttribute as String), !value.isEmpty {
                title = value
                break
            }
            titleNode = parent(of: node)
        }

        let frameNode = titleNode ?? element
        let frame = rect(of: frameNode)
        return DockIconHit(isDock: true, title: title, frame: frame)
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let parent = value else { return nil }
        return (parent as! AXUIElement)
    }

    private static func rect(of element: AXUIElement) -> CGRect? {
        guard let origin = pointValue(element, kAXPositionAttribute as String),
              let size = sizeValue(element, kAXSizeAttribute as String),
              size.width > 1, size.height > 1 else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func pointValue(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeValue(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}

/// helper / XPC 子进程归一到所属常规应用（与切换器内实现一致）。
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

/// Dock 图标标题与运行中应用的匹配（Dock 展示的是 `file-label`，可能被重命名）。
enum AppNameMatcher {
    static func app(matchingTitle title: String) -> NSRunningApplication? {
        let target = normalize(title)
        guard !target.isEmpty else { return nil }

        let candidates = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let exact = candidates.first(where: { normalize($0.localizedName ?? "") == target }) {
            return exact
        }
        return candidates.first { app in
            let name = normalize(app.localizedName ?? "")
            let fileName = normalize(app.bundleURL?.deletingPathExtension().lastPathComponent ?? "")
            return (!name.isEmpty && (name.contains(target) || target.contains(name)))
                || (!fileName.isEmpty && (fileName.contains(target) || target.contains(fileName)))
        }
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".app", with: "")
            .lowercased()
    }
}
