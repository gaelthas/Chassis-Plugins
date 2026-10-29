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
            Section(DockActionsStrings.t("section.click")) {
                Toggle(
                    DockActionsStrings.t("click.enabled"),
                    isOn: Binding(
                        get: { model.clickToMinimize },
                        set: { plugin.setClickToMinimize($0) }
                    )
                )
                Toggle(DockActionsStrings.t("click.exitFullScreenFirst"), isOn: $model.exitFullScreenFirst)
                Text(DockActionsStrings.t("click.help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(DockActionsStrings.t("section.shortcuts")) {
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

                Text(DockActionsStrings.t("shortcuts.help \(model.modifierPreset.displayText)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = model.lastError {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(DockActionsStrings.t("section.rules")) {
                Picker(DockActionsStrings.t("rules.mode"), selection: $model.rulesMode) {
                    Text(DockActionsStrings.t("rules.mode.off")).tag(DockActionsModel.RulesMode.off)
                    Text(DockActionsStrings.t("rules.mode.blacklist")).tag(DockActionsModel.RulesMode.blacklist)
                    Text(DockActionsStrings.t("rules.mode.whitelist")).tag(DockActionsModel.RulesMode.whitelist)
                }
                .pickerStyle(.segmented)

                if model.rulesMode != .off {
                    ForEach(model.ruleBundleIDs, id: \.self) { bundleID in
                        HStack {
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
                    Text(DockActionsStrings.t("rules.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(DockActionsStrings.t("section.events")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.events.isEmpty {
                            Text(DockActionsStrings.t("events.empty"))
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

                Button(DockActionsStrings.t("events.clear")) {
                    model.clearEvents()
                }
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

    private func displayName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID
    }

    private func addFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != "com.gaelthas.chassis",
              !model.ruleBundleIDs.contains(bundleID) else { return }
        model.ruleBundleIDs.append(bundleID)
    }
}
