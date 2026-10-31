import PluginAPI
import SwiftUI

struct SlowQuitSettingsView: View {
    let plugin: SlowQuitPlugin

    @Bindable private var model: SlowQuitModel

    init(plugin: SlowQuitPlugin) {
        precondition(plugin.settingsModel != nil, "只有在 active 状态才会构建插件视图")
        self.plugin = plugin
        _model = Bindable(wrappedValue: plugin.settingsModel!)
    }

    var body: some View {
        Form {
            Section {
                Toggle(SlowQuitStrings.t("quit.enabled"), isOn: $model.enabled)
                Toggle(SlowQuitStrings.t("quit.showHUD"), isOn: $model.showProgressHUD)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(SlowQuitStrings.t("quit.threshold"))
                        Spacer()
                        Text(String(format: "%.1f s", model.threshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.threshold, in: 0.5...5.0, step: 0.1)
                }
            } header: {
                Text(SlowQuitStrings.t("section.behavior"))
            } footer: {
                Text(SlowQuitStrings.t("quit.help"))
            }

            Section(SlowQuitStrings.t("section.events")) {
                eventLog
            }

            Section {
                Button(SlowQuitStrings.t("reset"), role: .destructive) {
                    model.resetAll()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 事件日志：浅底等宽日志框，新事件自动滚到底部。
    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    model.clearEvents()
                } label: {
                    Label(SlowQuitStrings.t("events.clear"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.events.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(SlowQuitStrings.t("events.empty"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 72)
                        } else {
                            ForEach(model.events.indices, id: \.self) { index in
                                Text(verbatim: model.events[index])
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .frame(height: 104)
                .onChange(of: model.events.count) { _, _ in
                    if let last = model.events.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}

enum SlowQuitStrings {
    static func t(_ key: String) -> String {
        resourceBundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// SwiftPM 构建用 `Bundle.module`；作为 `.chassisplugin` 动态库构建时，
/// `Bundle(for:)` 会向上找到插件包自己的 `Contents/Info.plist`。
final class PluginResourceToken {}

let resourceBundle: Bundle = {
    #if SWIFT_PACKAGE
    return .module
    #else
    return Bundle(for: PluginResourceToken.self)
    #endif
}()
