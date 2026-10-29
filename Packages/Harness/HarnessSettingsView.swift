import AppKit
import PluginAPI
import PluginSupport
import SwiftUI

/// 探针设置页。所有状态都来自插件实例持有的 model，因此切走再切回不会丢。
struct HarnessSettingsView: View {
    let plugin: HarnessPlugin

    @Bindable private var model: HarnessSettingsModel

    init(plugin: HarnessPlugin) {
        precondition(plugin.settingsModel != nil, "只有在 active 状态才会构建插件视图")
        self.plugin = plugin
        _model = Bindable(wrappedValue: plugin.settingsModel!)
    }

    var body: some View {
        Form {
            Section(HarnessStrings.t("section.input")) {
                Toggle(HarnessStrings.t("probe.click"), isOn: $model.clickProbeEnabled)
                Toggle(HarnessStrings.t("probe.key"), isOn: $model.keyProbeEnabled)
                Toggle(HarnessStrings.t("probe.pointer"), isOn: $model.pointerProbeEnabled)
                Toggle(HarnessStrings.t("probe.consume"), isOn: $model.keyConsumeEnabled)
                Text(HarnessStrings.t("probe.consume.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(HarnessStrings.t("section.events")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(HarnessStrings.t("events.empty"))
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
                .frame(height: 120)

                Button(HarnessStrings.t("events.clear")) {
                    model.clearEvents()
                }
            }

            Section(HarnessStrings.t("section.hotkey")) {
                HotKeyRecorder(
                    spec: $model.spec,
                    availability: { plugin.availability(of: $0) },
                    onCommit: { try plugin.updateHotKey($0) }
                )
            }

            Section(HarnessStrings.t("section.notification")) {
                HStack(spacing: 8) {
                    Button(HarnessStrings.t("probe.notification.burst")) {
                        plugin.postBurst()
                    }
                    Button(HarnessStrings.t("probe.notification.single")) {
                        plugin.postDistinct()
                    }
                    Button(HarnessStrings.t("probe.notification.requestAuth")) {
                        plugin.requestNotificationAuthorization()
                    }
                }
                Text(HarnessStrings.t("probe.notification.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(HarnessStrings.t("section.capture")) {
                HStack(spacing: 8) {
                    Button(HarnessStrings.t("probe.capture.take")) {
                        Task { await plugin.captureWindow() }
                    }
                    .disabled(model.isCapturing)
                    if let status = model.captureStatus {
                        Text(verbatim: status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let image = model.lastCapture {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Section(HarnessStrings.t("section.violation")) {
                Toggle(HarnessStrings.t("violation.skipCancel"), isOn: $model.skipCancelOnDeactivate)
                Toggle(HarnessStrings.t("violation.blockingAX"), isOn: $model.blockingAXOnMainThread)
                Text(HarnessStrings.t("violation.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(HarnessStrings.t("reset"), role: .destructive) {
                    model.resetAll()
                }
            }
        }
        .formStyle(.grouped)
    }
}
