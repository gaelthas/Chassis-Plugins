import PluginAPI
import SwiftUI

struct WindowSwitcherSettingsView: View {
    let plugin: WindowSwitcherPlugin

    @Bindable private var model: WindowSwitcherModel

    init(plugin: WindowSwitcherPlugin) {
        precondition(plugin.settingsModel != nil, "只有在 active 状态才会构建插件视图")
        self.plugin = plugin
        _model = Bindable(wrappedValue: plugin.settingsModel!)
    }

    var body: some View {
        Form {
            Section(WindowSwitcherStrings.t("section.usage")) {
                Text(WindowSwitcherStrings.t("usage.help"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(WindowSwitcherStrings.t("section.display")) {
                Picker(WindowSwitcherStrings.t("display.mode"), selection: $model.mode) {
                    Text(WindowSwitcherStrings.t("display.mode.icons")).tag(WindowSwitcherModel.DisplayMode.icons)
                    Text(WindowSwitcherStrings.t("display.mode.thumbnails")).tag(WindowSwitcherModel.DisplayMode.thumbnails)
                }
                .pickerStyle(.segmented)

                Toggle(WindowSwitcherStrings.t("display.showTitles"), isOn: $model.showWindowTitles)

                if model.mode == .thumbnails {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(WindowSwitcherStrings.t("display.maxThumbnails"))
                            Spacer()
                            Text(verbatim: "\(model.maxThumbnails)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(model.maxThumbnails) },
                                set: { model.maxThumbnails = Int($0) }
                            ),
                            in: 4...24,
                            step: 2
                        )
                    }

                    Text(WindowSwitcherStrings.t("display.thumbnailHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !plugin.screenCaptureGranted {
                        HStack(spacing: 8) {
                            Text(WindowSwitcherStrings.t("display.permissionNeeded"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button(WindowSwitcherStrings.t("display.requestPermission")) {
                                plugin.requestScreenCapture()
                            }
                        }
                    }
                }
            }

            Section(WindowSwitcherStrings.t("section.events")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(WindowSwitcherStrings.t("events.empty"))
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

                Button(WindowSwitcherStrings.t("events.clear")) {
                    model.clearEvents()
                }
            }

            Section {
                Button(WindowSwitcherStrings.t("reset"), role: .destructive) {
                    model.resetAll()
                }
            }
        }
        .formStyle(.grouped)
    }
}
