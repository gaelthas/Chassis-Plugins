import Foundation
import PluginAPI

/// 外部插件包入口：把 Swift 实例交给基座（基座侧按 `FeaturePlugin` 转换）。
/// 只在 `.chassisplugin` 动态库构建中生效；SwiftPM 静态构建时这个符号无人使用。
@_cdecl("chassis_swift_plugin_entry")
public func SlowQuitPluginEntry() -> UnsafeMutableRawPointer? {
    // 插件实例是 Main Actor 隔离的；裸指针不能直接穿过 assumeIsolated。
    final class Slot: @unchecked Sendable { var raw: UnsafeMutableRawPointer? }
    let slot = Slot()
    MainActor.assumeIsolated {
        slot.raw = Unmanaged.passRetained(SlowQuitPlugin() as AnyObject).toOpaque()
    }
    return slot.raw
}
