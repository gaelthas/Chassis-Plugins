import AppKit
import PluginAPI
import SwiftUI

struct DockActionsSettingsView: View {
    let plugin: DockActionsPlugin

    @Bindable private var model: DockActionsModel

    init(plugin: DockActionsPlugin) {
        precondition(plugin.settingsModel != nil, "只有在 active 状态才会构建插件视图")
        self.plugin = plugin
        _model = Bindable(wrappedValue: plugin.settingsModel!)
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    DockActionsStrings.t("click.enabled"),
                    isOn: Binding(
                        get: { model.clickToMinimize },
                        set: { plugin.setClickToMinimize($0) }
                    )
                )
                Toggle(DockActionsStrings.t("click.exitFullScreenFirst"), isOn: $model.exitFullScreenFirst)
            } header: {
                Text(DockActionsStrings.t("section.click"))
            } footer: {
                Text(DockActionsStrings.t("click.help"))
            }

            Section {
                Toggle(
                    DockActionsStrings.t("shortcuts.enabled"),
                    isOn: Binding(
                        get: { model.shortcutsEnabled },
                        set: { plugin.setShortcutsEnabled($0) }
                    )
                )
                Picker(
                    DockActionsStrings.t("shortcuts.modifiers"),
                    selection: Binding(
                        get: { model.modifierPreset },
                        set: { plugin.updateShortcutPreset($0) }
                    )
                ) {
                    ForEach(DockActionsModel.ModifierPreset.allCases, id: \.self) { preset in
                        Text(verbatim: "\(preset.displayText)" + "\(DockActionsStrings.t("shortcuts.digitsSuffix"))")
                            .tag(preset)
                    }
                }
                .disabled(!model.shortcutsEnabled)
            } header: {
                Text(DockActionsStrings.t("section.shortcuts"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(DockActionsStrings.t("shortcuts.help \(model.modifierPreset.displayText)"))
                    if let error = model.lastError {
                        Text(verbatim: error)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Picker(DockActionsStrings.t("rules.mode"), selection: $model.rulesMode) {
                    Text(DockActionsStrings.t("rules.mode.off")).tag(DockActionsModel.RulesMode.off)
                    Text(DockActionsStrings.t("rules.mode.blacklist")).tag(DockActionsModel.RulesMode.blacklist)
                    Text(DockActionsStrings.t("rules.mode.whitelist")).tag(DockActionsModel.RulesMode.whitelist)
                }
                .pickerStyle(.segmented)

                if model.rulesMode != .off {
                    ForEach(model.ruleBundleIDs, id: \.self) { bundleID in
                        HStack {
                            if let icon = appIcon(for: bundleID) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                            }
                            Text(verbatim: displayName(for: bundleID))
                            Spacer()
                            Text(verbatim: bundleID)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button(role: .destructive) {
                                model.ruleBundleIDs.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button(DockActionsStrings.t("rules.addFrontmost")) {
                        addFrontmostApp()
                    }
                }
            } header: {
                Text(DockActionsStrings.t("section.rules"))
            } footer: {
                Text(DockActionsStrings.t("rules.help"))
            }

            Section(DockActionsStrings.t("section.events")) {
                eventLog
            }

            Section {
                Button(DockActionsStrings.t("reset"), role: .destructive) {
                    model.resetAll()
                    plugin.setShortcutsEnabled(model.shortcutsEnabled)
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
                    Label(DockActionsStrings.t("events.clear"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(model.events.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(DockActionsStrings.t("events.empty"))
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

    private func displayName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
    }

    private func addFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != "com.gaelthas.chassis",
              !model.ruleBundleIDs.contains(bundleID) else { return }
        model.ruleBundleIDs.append(bundleID)
    }
}
