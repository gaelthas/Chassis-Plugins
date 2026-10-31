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
            Section {
                Toggle(HarnessStrings.t("probe.click"), isOn: $model.clickProbeEnabled)
                Toggle(HarnessStrings.t("probe.key"), isOn: $model.keyProbeEnabled)
                Toggle(HarnessStrings.t("probe.pointer"), isOn: $model.pointerProbeEnabled)
                Toggle(HarnessStrings.t("probe.consume"), isOn: $model.keyConsumeEnabled)
            } header: {
                Text(HarnessStrings.t("section.input"))
            } footer: {
                Text(HarnessStrings.t("probe.consume.help"))
            }

            Section(HarnessStrings.t("section.events")) {
                eventLog
            }

            Section(HarnessStrings.t("section.hotkey")) {
                HotKeyRecorder(
                    spec: $model.spec,
                    availability: { plugin.availability(of: $0) },
                    onCommit: { try plugin.updateHotKey($0) }
                )
            }

            Section {
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
            } header: {
                Text(HarnessStrings.t("section.notification"))
            } footer: {
                Text(HarnessStrings.t("probe.notification.help"))
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

            Section {
                Toggle(HarnessStrings.t("violation.skipCancel"), isOn: $model.skipCancelOnDeactivate)
                Toggle(HarnessStrings.t("violation.blockingAX"), isOn: $model.blockingAXOnMainThread)
            } header: {
                Text(HarnessStrings.t("section.violation"))
            } footer: {
                Text(HarnessStrings.t("violation.help"))
            }

            Section {
                Button(HarnessStrings.t("reset"), role: .destructive) {
                    model.resetAll()
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 事件日志：浅底等宽日志框，新事件自动滚到底部（探针事件量大，用更高一点）。
    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    model.clearEvents()
                } label: {
                    Label(HarnessStrings.t("events.clear"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.events.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(HarnessStrings.t("events.empty"))
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
                .frame(height: 132)
                .onChange(of: model.events.count) { _, _ in
                    if let last = model.events.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}
