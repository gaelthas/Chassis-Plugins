import AppKit
import CoreGraphics

/// Dock 区域初筛：把「每次点击都做一次跨进程 AX 查询」压缩成一次纯几何判断。
/// Dock 只可能贴在屏幕的三条边，因此点击点必须落在某块屏幕的边缘带内。
enum DockGeometry {
    /// 边缘带厚度；Dock 图标本身约 60pt，取 180pt 覆盖放大/多项 Dock。
    static let band: CGFloat = 180

    /// 点是否落在任意屏幕的左/右/底边缘带内（左上原点坐标系，与 ClickContext 一致）。
    static func isNearDockBand(_ point: CGPoint, band: CGFloat = band) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        guard primaryHeight > 0 else { return true }  // 拿不到屏幕信息时不做过滤，交给 AX 判定

        for screen in NSScreen.screens {
            let frame = screen.frame
            let top = primaryHeight - frame.maxY
            let rect = CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height)

            guard rect.insetBy(dx: -1, dy: -1).contains(point) else { continue }
            let nearLeft = point.x - rect.minX <= band
            let nearRight = rect.maxX - point.x <= band
            let nearBottom = rect.maxY - point.y <= band
            if nearLeft || nearRight || nearBottom {
                return true
            }
        }
        return false
    }
}
