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
            Section(SlowQuitStrings.t("section.behavior")) {
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

                Text(SlowQuitStrings.t("quit.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(SlowQuitStrings.t("section.events")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(SlowQuitStrings.t("events.empty"))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.events.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)

                Button(SlowQuitStrings.t("events.clear")) {
                    model.clearEvents()
                }
            }

            Section {
                Button(SlowQuitStrings.t("reset"), role: .destructive) {
                    model.resetAll()
                }
            }
        }
        .formStyle(.grouped)
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
