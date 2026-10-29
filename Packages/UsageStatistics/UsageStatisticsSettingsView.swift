import PluginAPI
import SwiftUI

struct UsageStatisticsSettingsView: View {
    let plugin: UsageStatisticsPlugin

    @Bindable private var model: UsageStatisticsModel

    init(plugin: UsageStatisticsPlugin) {
        precondition(plugin.settingsModel != nil, "只有在 active 状态才会构建插件视图")
        self.plugin = plugin
        _model = Bindable(wrappedValue: plugin.settingsModel!)
    }

    private var todayTotal: Double {
        model.today.reduce(0) { $0 + $1.seconds }
    }

    private var maxToday: Double {
        max(model.today.first?.seconds ?? 1, 1)
    }

    private var maxWeek: Double {
        max(model.week.map(\.seconds).max() ?? 1, 1)
    }

    var body: some View {
        Form {
            Section(UsageStrings.t("section.today")) {
                Toggle(UsageStrings.t("usage.enabled"), isOn: $model.enabled)

                if model.today.isEmpty {
                    Text(UsageStrings.t("usage.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(UsageStrings.t("usage.todayTotal"))
                        Spacer()
                        Text(verbatim: UsageStatisticsModel.format(todayTotal))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.today) { usage in
                        usageRow(usage, maxSeconds: maxToday)
                    }
                }
            }

            Section(UsageStrings.t("section.week")) {
                ForEach(model.week) { total in
                    HStack(spacing: 8) {
                        Text(verbatim: total.day)
                            .font(.caption.monospaced())
                            .frame(width: 88, alignment: .leading)
                            .foregroundStyle(.secondary)
                        ProgressView(value: total.seconds, total: maxWeek)
                            .progressViewStyle(.linear)
                        Text(verbatim: UsageStatisticsModel.format(total.seconds))
                            .font(.caption.monospacedDigit())
                            .frame(width: 72, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button(UsageStrings.t("usage.reset"), role: .destructive) {
                    model.resetData()
                }
                Text(UsageStrings.t("usage.note \(model.daysRecorded)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task {
            model.refresh()
        }
    }

    private func usageRow(_ usage: AppUsage, maxSeconds: Double) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: usage.name)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            ProgressView(value: usage.seconds, total: maxSeconds)
                .progressViewStyle(.linear)
            Text(verbatim: UsageStatisticsModel.format(usage.seconds))
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}
