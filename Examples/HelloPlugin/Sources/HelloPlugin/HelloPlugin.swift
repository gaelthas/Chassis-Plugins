import AppKit
import Foundation
import PluginABI
import SwiftUI

/// 外部插件示例：只通过 C ABI 与基座交互。
///
/// 它做了四件事，覆盖最常用的服务：
/// 1. 订阅鼠标点击并写日志
/// 2. 注册一个全局快捷键（⌃⌥H）
/// 3. 读写自己的字符串配置（点击计数）
/// 4. 返回一个 SwiftUI 设置页
final class HelloInstance {
    var services: UnsafePointer<chassis_host_services_v1>?
    var clickSubscription: UnsafeRawPointer?
    var clickCount = 0
}

private let manifestJSON = """
{
  "schema": 1,
  "id": "com.example.chassis.hello",
  "version": "1.0.0",
  "minHostVersion": "1.0.0",
  "apiVersion": 1,
  "title": { "zh-Hans": "示例外部插件", "en": "Hello External Plugin" },
  "summary": { "zh-Hans": "演示外部插件包：点击计数 + 全局快捷键 + 设置页", "en": "Demo external plugin: click counter, hot key and settings page" },
  "iconSystemName": "hand.wave",
  "requiredCapabilities": [],
  "optionalCapabilities": [],
  "vendor": "Chassis Samples"
}
"""

private func cString(_ text: String) -> UnsafeMutablePointer<CChar> {
    strdup(text)!
}

private func withServices<T>(_ instance: UnsafeMutableRawPointer?, _ body: (HelloInstance, UnsafePointer<chassis_host_services_v1>) -> T) -> T? {
    guard let instance else { return nil }
    let object = Unmanaged<HelloInstance>.fromOpaque(instance).takeUnretainedValue()
    guard let services = object.services else { return nil }
    return body(object, services)
}

private let helloCreate: @convention(c) () -> UnsafeMutableRawPointer? = {
    Unmanaged.passRetained(HelloInstance()).toOpaque()
}

private let helloDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void = { instance in
    guard let instance else { return }
    Unmanaged<HelloInstance>.fromOpaque(instance).release()
}

private let helloActivate: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<chassis_host_services_v1>?) -> Int32 = { instance, services in
    guard let instance, let services else { return -1 }
    let object = Unmanaged<HelloInstance>.fromOpaque(instance).takeUnretainedValue()
    object.services = services

    services.pointee.log?(services.pointee.host, 1, cString("hello plugin activated"))

    // 点击订阅：只读事件值，业务在自己的回调里处理。
    let ctx = Unmanaged.passUnretained(object).toOpaque()
    object.clickSubscription = services.pointee.subscribe_click?(services.pointee.host, { ctx, event in
        guard let ctx, let event else { return }
        let object = Unmanaged<HelloInstance>.fromOpaque(ctx).takeUnretainedValue()
        object.clickCount += 1
        guard let services = object.services else { return }
        let text = "click #\(object.clickCount) at \(Int(event.pointee.x)),\(Int(event.pointee.y))"
        services.pointee.log?(services.pointee.host, 1, cString(text))
        services.pointee.store_set?(services.pointee.host, cString("click.count"), cString("\(object.clickCount)"))
    }, ctx)

    // 全局快捷键 ⌃⌥H（modifiers 位与基座的 HotKeyModifiers 一致：command 1, option 2, control 4, shift 8）
    let hotKeyStatus = services.pointee.register_hotkey?(services.pointee.host, 0x04, 4 | 2, { ctx in
        guard let ctx else { return }
        let object = Unmanaged<HelloInstance>.fromOpaque(ctx).takeUnretainedValue()
        guard let services = object.services else { return }
        services.pointee.post_notification?(
            services.pointee.host,
            cString("hello-hotkey"),
            cString("Hello Plugin"),
            cString("全局快捷键触发了")
        )
    }, ctx)

    services.pointee.log?(services.pointee.host, 1, cString("hotkey registration status: \(hotKeyStatus ?? -1)"))
    return 0
}

private let helloDeactivate: @convention(c) (UnsafeMutableRawPointer?) -> Void = { instance in
    guard let instance else { return }
    let object = Unmanaged<HelloInstance>.fromOpaque(instance).takeUnretainedValue()
    if let services = object.services {
        if let subscription = object.clickSubscription {
            services.pointee.unsubscribe?(services.pointee.host, subscription)
        }
        services.pointee.unregister_hotkeys?(services.pointee.host)
        services.pointee.log?(services.pointee.host, 1, cString("hello plugin deactivated"))
    }
    object.clickSubscription = nil
    object.services = nil
}

/// 裸指针不能直接送进 `assumeIsolated`（Swift 6 视其为数据竞争），用只读载体包一层。
private final class SettingsRequest: @unchecked Sendable {
    let instance: UnsafeMutableRawPointer
    var result: UnsafeMutableRawPointer?

    init(instance: UnsafeMutableRawPointer) {
        self.instance = instance
    }
}

private let helloMakeSettingsView: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? = { instance in
    guard let instance else { return nil }
    let request = SettingsRequest(instance: instance)
    // NSHostingController 是 UI 对象：必须在主线程创建。
    MainActor.assumeIsolated {
        let object = Unmanaged<HelloInstance>.fromOpaque(request.instance).takeUnretainedValue()
        let controller = NSHostingController(rootView: HelloSettingsView(instance: object))
        request.result = Unmanaged.passRetained(controller).toOpaque()
    }
    return request.result
}

/// 插件自带的设置页。基座只负责容器，内容完全由插件提供。
struct HelloSettingsView: View {
    let instance: HelloInstance

    @State private var stored = ""

    var body: some View {
        Form {
            Section("示例插件") {
                Text("这个插件通过 C ABI 与基座通信，不依赖 PluginAPI。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("本次会话点击计数：\(instance.clickCount)")
                Text("已持久化计数：\(stored)")
                Text("全局快捷键：⌃⌥H（触发一次通知）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        guard let services = instance.services else { return }
        var buffer = [CChar](repeating: 0, count: 64)
        let length = services.pointee.store_get?(services.pointee.host, cString("click.count"), &buffer, buffer.count) ?? -1
        if length >= 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            stored = String(decoding: bytes, as: UTF8.self)
        } else {
            stored = "-"
        }
    }
}

@_cdecl("chassis_plugin_entry")
public func chassisPluginEntry(_ hostABIVersion: UInt32) -> UnsafeMutablePointer<chassis_plugin_v1>? {
    guard hostABIVersion == UInt32(CHASSIS_PLUGIN_ABI_VERSION) else { return nil }

    // 清单字符串与 vtable 的生命周期与动态库一致，不需要释放。
    let table = UnsafeMutablePointer<chassis_plugin_v1>.allocate(capacity: 1)
    table.initialize(to: chassis_plugin_v1(
        struct_size: UInt32(MemoryLayout<chassis_plugin_v1>.size),
        manifest_json: UnsafePointer(cString(manifestJSON)),
        create: helloCreate,
        destroy: helloDestroy,
        activate: helloActivate,
        deactivate: helloDeactivate,
        make_settings_view: helloMakeSettingsView
    ))
    return table
}
