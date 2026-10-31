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
            Section {
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

                if model.mode == .thumbnails, !plugin.screenCaptureGranted {
                    permissionNotice
                }
            } header: {
                Text(DockHoverStrings.t("section.behavior"))
            } footer: {
                Text(DockHoverStrings.t("hover.help"))
            }

            Section(DockHoverStrings.t("section.events")) {
                eventLog
            }

            Section {
                Button(DockHoverStrings.t("reset"), role: .destructive) {
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
                    Label(DockHoverStrings.t("events.clear"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.events.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(DockHoverStrings.t("events.empty"))
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

    /// 缺「屏幕录制」权限时的提示条：图标 + 说明 + 申请按钮。
    private var permissionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(DockHoverStrings.t("hover.permissionNeeded"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(DockHoverStrings.t("hover.requestPermission")) {
                plugin.requestScreenCapture()
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
