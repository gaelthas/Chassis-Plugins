import AppKit
import Foundation
import Observation
import PluginAPI

/// 探针插件的设置状态。挂在插件实例上，因此切换设置页不会丢（§6.1）。
@MainActor
@Observable
final class HarnessSettingsModel {
    private enum Key {
        static let clickProbe = "probe.click"
        static let keyProbe = "probe.key"
        static let pointerProbe = "probe.pointer"
        static let consume = "probe.consume"
        static let skipCancel = "violation.skipCancel"
        static let blockingAX = "violation.blockingAX"
        static let hotkey = "hotkey"
    }

    @ObservationIgnored private let store: PluginStore

    /// tap 线程可读的标量：`syncIntercept` 只允许读 AtomicFlag。
    let consumeFlag = AtomicFlag(false)

    var clickProbeEnabled: Bool {
        didSet { store.set(clickProbeEnabled, forKey: Key.clickProbe) }
    }

    var keyProbeEnabled: Bool {
        didSet { store.set(keyProbeEnabled, forKey: Key.keyProbe) }
    }

    var pointerProbeEnabled: Bool {
        didSet { store.set(pointerProbeEnabled, forKey: Key.pointerProbe) }
    }

    var keyConsumeEnabled: Bool {
        didSet {
            consumeFlag.value = keyConsumeEnabled
            store.set(keyConsumeEnabled, forKey: Key.consume)
        }
    }

    /// 违规对照：故意不在 deactivate 中取消订阅，用于验证基座强制清理（D1）。
    var skipCancelOnDeactivate: Bool {
        didSet { store.set(skipCancelOnDeactivate, forKey: Key.skipCancel) }
    }

    /// 违规对照：在 Main Actor 上直接发起 AX 调用，用于感知 UI 冻结（B11）。
    var blockingAXOnMainThread: Bool {
        didSet { store.set(blockingAXOnMainThread, forKey: Key.blockingAX) }
    }

    var spec: HotKeySpec {
        didSet { store.set(spec, forKey: Key.hotkey) }
    }

    private(set) var events: [String] = []
    private(set) var lastCapture: NSImage?
    private(set) var captureStatus: String?
    var isCapturing = false

    init(store: PluginStore) {
        self.store = store
        clickProbeEnabled = store.value(Bool.self, forKey: Key.clickProbe) ?? true
        keyProbeEnabled = store.value(Bool.self, forKey: Key.keyProbe) ?? true
        pointerProbeEnabled = store.value(Bool.self, forKey: Key.pointerProbe) ?? false
        keyConsumeEnabled = store.value(Bool.self, forKey: Key.consume) ?? false
        skipCancelOnDeactivate = store.value(Bool.self, forKey: Key.skipCancel) ?? false
        blockingAXOnMainThread = store.value(Bool.self, forKey: Key.blockingAX) ?? false
        spec = store.value(HotKeySpec.self, forKey: Key.hotkey) ?? .harnessDefault
        consumeFlag.value = keyConsumeEnabled
    }

    func append(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        events.append("\(formatter.string(from: Date()))  \(line)")
        if events.count > 200 {
            events.removeFirst(events.count - 200)
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    func setCaptureStatus(_ text: String?) {
        captureStatus = text
    }

    func setCaptureImage(_ image: NSImage?) {
        lastCapture = image
    }

    func resetAll() {
        store.removeAll()
        clickProbeEnabled = true
        keyProbeEnabled = true
        pointerProbeEnabled = false
        keyConsumeEnabled = false
        skipCancelOnDeactivate = false
        blockingAXOnMainThread = false
        spec = .harnessDefault
        clearEvents()
        captureStatus = nil
        lastCapture = nil
    }
}

extension HotKeySpec {
    /// 插件自己的默认快捷键：基座不提供任何默认值。
    static let harnessDefault = HotKeySpec(keyCode: 0x23, modifiers: [.option, .command])  // ⌥⌘P
}
