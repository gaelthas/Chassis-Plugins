import PluginAPI
import SwiftUI

struct DockHoverPreviewSettingsView: View {
    let plugin: DockHoverPreviewPlugin

    @Bindable private var model: DockHoverModel

    init(plugin: DockHoverPreviewPlugin) {
        precondition(plugin.settingsModel != nil, "只有在 active 状态才会构建插件视图")
        self.plugin = plugin
        _model = Bindable(wrappedValue: plugin.settingsModel!)
    }

    var body: some View {
        Form {
            Section(DockHoverStrings.t("section.behavior")) {
                Toggle(DockHoverStrings.t("hover.enabled"), isOn: $model.enabled)

                Picker(DockHoverStrings.t("hover.mode"), selection: $model.mode) {
                    Text(DockHoverStrings.t("hover.mode.icons")).tag(DockHoverModel.DisplayMode.icons)
                    Text(DockHoverStrings.t("hover.mode.thumbnails")).tag(DockHoverModel.DisplayMode.thumbnails)
                }
                .pickerStyle(.segmented)

                Toggle(DockHoverStrings.t("hover.showTitles"), isOn: $model.showWindowTitles)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(DockHoverStrings.t("hover.delay"))
                        Spacer()
                        Text(String(format: "%.2f s", model.hoverDelay))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.hoverDelay, in: 0.05...0.8, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(DockHoverStrings.t("hover.maxWindows"))
                        Spacer()
                        Text(verbatim: "\(model.maxWindows)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.maxWindows) },
                            set: { model.maxWindows = Int($0) }
                        ),
                        in: 2...12,
                        step: 1
                    )
                }

                Text(DockHoverStrings.t("hover.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.mode == .thumbnails, !plugin.screenCaptureGranted {
                    HStack(spacing: 8) {
                        Text(DockHoverStrings.t("hover.permissionNeeded"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button(DockHoverStrings.t("hover.requestPermission")) {
                            plugin.requestScreenCapture()
                        }
                    }
                }
            }

            Section(DockHoverStrings.t("section.events")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(DockHoverStrings.t("events.empty"))
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

                Button(DockHoverStrings.t("events.clear")) {
                    model.clearEvents()
                }
            }

            Section {
                Button(DockHoverStrings.t("reset"), role: .destructive) {
                    model.resetAll()
                }
            }
        }
        .formStyle(.grouped)
    }
}
