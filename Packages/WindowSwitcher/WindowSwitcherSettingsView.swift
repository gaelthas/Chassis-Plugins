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
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .padding(.top, 2)
                    Text(WindowSwitcherStrings.t("usage.help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
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

                    if !plugin.screenCaptureGranted {
                        permissionNotice
                    }
                }
            } header: {
                Text(WindowSwitcherStrings.t("section.display"))
            } footer: {
                Text(WindowSwitcherStrings.t("display.thumbnailHelp"))
            }

            Section(WindowSwitcherStrings.t("section.events")) {
                eventLog
            }

            Section {
                Button(WindowSwitcherStrings.t("reset"), role: .destructive) {
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
                    Label(WindowSwitcherStrings.t("events.clear"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.events.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(WindowSwitcherStrings.t("events.empty"))
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
            Text(WindowSwitcherStrings.t("display.permissionNeeded"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(WindowSwitcherStrings.t("display.requestPermission")) {
                plugin.requestScreenCapture()
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
