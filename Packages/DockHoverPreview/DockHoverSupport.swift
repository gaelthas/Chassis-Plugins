import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 悬停点对应的 Dock 图标：标题 + 图标在屏幕上的位置（AX 左上坐标系）+ 应用身份。
struct DockIconHit: Sendable {
    let isDock: Bool
    let title: String?
    let frame: CGRect?
    let bundleID: String?
    let url: URL?

    static let miss = DockIconHit(isDock: false, title: nil, frame: nil, bundleID: nil, url: nil)
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

/// 点击/悬停点对应的 Dock 图标节点。
///
/// `AXUIElementCopyElementAtPosition` 一次穿透命中节点，比遍历 UI 树便宜得多；
/// 但它只保证「这个点属于某个节点」，标题与位置可能都读不到（图标边缘、徽标、
/// 放大动画中）。因此命中结果由 `DockHoverProbe` 再兜一层几何查询。
enum DockIconResolver {
    static func icon(at point: CGPoint, dockPID: pid_t) -> DockIconHit {
        guard dockPID > 0 else { return .miss }

        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else {
            return .miss
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid == dockPID else { return .miss }

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
        return DockIconHit(
            isDock: true,
            title: title,
            frame: frame,
            bundleID: nil,
            url: urlValue(of: frameNode)
        )
    }

    static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let parent = value else { return nil }
        return (parent as! AXUIElement)
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    static func urlValue(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        if let url = raw as? URL { return url }
        if let string = raw as? String { return URL(string: string) }
        return nil
    }

    static func rect(of element: AXUIElement) -> CGRect? {
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

/// Dock 上的一个应用图标（位置 + 身份），可跨线程传递。
struct DockItem: Sendable {
    let title: String
    let bundleID: String?
    let url: URL?
    /// AX 左上坐标。
    let frame: CGRect
}

/// 枚举 Dock 的 UI 树（application → list → item），拿到每个图标的矩形与身份。
///
/// 为什么需要它：`AXUIElementCopyElementAtPosition` 在图标边缘、Dock 放大动画、
/// 图标徽标上经常只返回一个「没有标题也没有位置」的子节点，这正是悬停预览
/// 「时灵时不灵」的主因。整棵树一次枚举（十几毫秒）换来的是一份可直接几何命中的快照，
/// 同时也顺手把 Dock 标签解析成 bundle id，应用匹配不再依赖名字。
/// **跨进程同步调用，必须在 `performBackground` 内执行。**
enum DockItemCatalog {
    private static let applicationSubrole = "AXApplicationDockItem"

    static func items(dockPID: pid_t) -> [DockItem] {
        guard dockPID > 0 else { return [] }
        let dock = AXUIElementCreateApplication(dockPID)
        // Dock 正常响应很快；给个上限，避免异常时把串行队列堵住。
        AXUIElementSetMessagingTimeout(dock, 0.5)

        // Dock 的层级是 application → list（persistent-apps / persistent-others /
        // recent-apps / minimize）→ item，但不同系统版本会多包一层：按深度遍历更稳。
        var items: [DockItem] = []
        var queue: [(element: AXUIElement, depth: Int)] = [(dock, 0)]
        var visited = 0

        while let (element, depth) = queue.first, visited < 400 {
            queue.removeFirst()
            visited += 1
            for child in DockIconResolver.children(of: element) {
                if let item = dockItem(from: child) {
                    items.append(item)   // 命中图标后不再向下钻
                } else if depth < 3 {
                    queue.append((child, depth + 1))
                }
            }
        }
        return items
    }

    private static func dockItem(from element: AXUIElement) -> DockItem? {
        let subrole = DockIconResolver.stringValue(element, kAXSubroleAttribute as String)
        let url = DockIconResolver.urlValue(of: element)
        // 只收应用图标：文件夹、废纸篓、最小化窗口都没有窗口预览可给。
        let isApplication = subrole == applicationSubrole
            || (url?.pathExtension.lowercased() == "app")
        guard isApplication, let frame = DockIconResolver.rect(of: element) else { return nil }

        let title = DockIconResolver.stringValue(element, kAXTitleAttribute as String)
            ?? url?.deletingPathExtension().lastPathComponent
            ?? ""
        guard !title.isEmpty else { return nil }

        return DockItem(
            title: title,
            bundleID: url.flatMap { Bundle(url: $0)?.bundleIdentifier },
            url: url,
            frame: frame
        )
    }
}

/// 悬停命中：元素穿透优先（最精确），失败时按图标矩形做几何命中。
enum DockHoverProbe {
    /// `catalog` 由调用方按需缓存（见 `DockHoverPreviewPlugin`）。
    static func probe(point: CGPoint, dockPID: pid_t, catalog: [DockItem]) -> DockIconHit {
        let elementHit = DockIconResolver.icon(at: point, dockPID: dockPID)
        let catalogHit = catalog.first { $0.frame.insetBy(dx: -4, dy: -4).contains(point) }

        if elementHit.isDock {
            let title = elementHit.title ?? catalogHit?.title
            let frame = elementHit.frame ?? catalogHit?.frame
            if let title, !title.isEmpty, let frame {
                return DockIconHit(
                    isDock: true,
                    title: title,
                    frame: frame,
                    bundleID: catalogHit?.bundleID,
                    url: elementHit.url ?? catalogHit?.url
                )
            }
        }

        if let catalogHit {
            return DockIconHit(
                isDock: true,
                title: catalogHit.title,
                frame: catalogHit.frame,
                bundleID: catalogHit.bundleID,
                url: catalogHit.url
            )
        }
        return .miss
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
    /// 优先按 bundle id / 应用包路径精确解析，名字只作兜底。
    static func app(matchingTitle title: String, bundleID: String?, url: URL?) -> NSRunningApplication? {
        let regulars = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        if let bundleID,
           let app = regulars.first(where: { $0.bundleIdentifier == bundleID }) {
            return app
        }
        if let url {
            let path = url.standardizedFileURL
            if let app = regulars.first(where: { $0.bundleURL?.standardizedFileURL == path }) {
                return app
            }
            if let id = Bundle(url: path)?.bundleIdentifier,
               let app = regulars.first(where: { $0.bundleIdentifier == id }) {
                return app
            }
        }
        return app(matchingTitle: title)
    }

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
