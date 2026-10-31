import PluginAPI
import SwiftUI

struct KeyboardStatisticsSettingsView: View {
    @Bindable private var model: KeyboardStatisticsModel

    init(model: KeyboardStatisticsModel) {
        _model = Bindable(wrappedValue: model)
    }

    private var snapshot: StatsSnapshot { model.snapshot }

    /// 60% 布局覆盖不到的键（F 键、小键盘…）。
    private var otherKeys: [(code: Int64, count: Int)] { model.keysOutsideLayout() }

    private var otherKeysSummary: String {
        otherKeys
            .map { "\(KeyboardLayout.label(for: $0.code)) \($0.count)" }
            .joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section {
                Toggle(KBStrings.t("kb.enabled"), isOn: $model.enabled)
            } header: {
                Text(KBStrings.t("section.behavior"))
            } footer: {
                // 长文案必须放 footer：作为行标签会把 grouped Form 的标签列撑宽，
                // 整页右侧内容随之被推出窗口（表现就是「UI 偏移、右侧被裁掉」）。
                Text(KBStrings.t("kb.privacy"))
            }

            Section {
                Picker(KBStrings.t("range.label"), selection: $model.range) {
                    ForEach(StatsRange.allCases) { range in
                        Text(verbatim: range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.range == .custom {
                    customRangeRow
                } else {
                    anchorDateRow
                }

                HStack {
                    Text(KBStrings.t("heatmap.total"))
                    Spacer()
                    Text(verbatim: String(format: KBStrings.t("count.format"), snapshot.total))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                KeyboardHeatmapView(counts: snapshot.counts, maxCount: snapshot.maxCount)

                KeyboardHeatmapLegend()

                if snapshot.total > 0 {
                    ForEach(model.topKeys(), id: \.code) { entry in
                        topKeyRow(code: entry.code, count: entry.count)
                    }
                }
            } header: {
                Text(KBStrings.t("section.heatmap"))
            } footer: {
                // 布局外的键放 footer：既不会被 60% 布局挡住，也不会像一排小标签那样把行撑宽。
                if snapshot.total == 0 {
                    Text(KBStrings.t("heatmap.empty"))
                } else if !otherKeys.isEmpty {
                    Text(verbatim: "\(KBStrings.t("heatmap.others"))：\(otherKeysSummary)")
                }
            }

            Section {
                if snapshot.total == 0 {
                    Text(KBStrings.t("daily.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(verbatim: snapshot.isHourly ? KBStrings.t("daily.hour") : KBStrings.t("daily.day"))
                        Spacer()
                        Text(verbatim: String(format: KBStrings.t("daily.peak"), snapshot.seriesMax))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    DailyBarChart(points: snapshot.series, maxValue: snapshot.seriesMax, isHourly: snapshot.isHourly)
                }
            } header: {
                Text(KBStrings.t("section.daily"))
            }

            Section {
                Button(KBStrings.t("kb.reset"), role: .destructive) {
                    model.reset()
                }
            } footer: {
                Text(verbatim: String(format: KBStrings.t("kb.note"), snapshot.daysRecorded))
            }
        }
        .formStyle(.grouped)
        .task {
            model.refresh()
        }
    }

    /// 预设范围：一个原生日期选择器选截止日。
    private var anchorDateRow: some View {
        HStack(spacing: 8) {
            DatePicker(
                KBStrings.t("range.date"),
                selection: $model.anchorDate,
                in: model.selectableDates,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .fixedSize()

            Spacer()

            if !model.isAnchorToday {
                Button(KBStrings.t("range.jumpToday")) {
                    model.anchorDate = Date()
                }
                .buttonStyle(.link)
            }
        }
    }

    /// 自定义范围：两个原生日期选择器，互相约束，且都落在保留期内。
    ///
    /// 关键约束：行的**第一个**视图不能是带标签的控件。grouped Form 会把行首那个控件
    /// 当成整行的「标签」，标签列宽度随之变成选择器的宽度（约 150pt），于是所有控件列
    /// 整体右移、右侧被裁，窗口还会被撑宽到 640pt。这里用 `labelsHidden()` 让行首
    /// 没有标签，Form 就不会切出标签列。
    private var customRangeRow: some View {
        HStack(spacing: 8) {
            DatePicker("", selection: $model.customStart, in: customStartRange, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: KBStrings.t("range.from")))

            Text(verbatim: "–")
                .foregroundStyle(.secondary)

            DatePicker("", selection: $model.customEnd, in: customEndRange, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: KBStrings.t("range.to")))

            Spacer(minLength: 0)
        }
    }

    /// `ClosedRange` 的上下界必须成立，否则运行时会崩；两端都朝合法区间夹一次。
    private var customStartRange: ClosedRange<Date> {
        let limits = model.selectableDates
        let upper = min(max(model.customEnd, limits.lowerBound), limits.upperBound)
        return limits.lowerBound...upper
    }

    private var customEndRange: ClosedRange<Date> {
        let limits = model.selectableDates
        let lower = min(max(model.customStart, limits.lowerBound), limits.upperBound)
        return lower...limits.upperBound
    }

    private func topKeyRow(code: Int64, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: KeyboardLayout.label(for: code))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            ProgressView(value: Double(count), total: Double(max(1, snapshot.maxCount)))
                .progressViewStyle(.linear)
            Text(verbatim: String(format: KBStrings.t("count.format"), count))
                .font(.caption.monospacedDigit())
                .frame(width: 68, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 每日柱状图

/// 手绘柱状图：不用 Swift Charts，避免插件包多依赖一个系统框架，
/// 也让「今天按小时 / 其它按天」两种粒度共用同一套绘制。
struct DailyBarChart: View {
    let points: [StatsPoint]
    let maxValue: Int
    let isHourly: Bool

    private let chartHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(points) { point in
                    bar(point)
                }
            }
            .frame(height: chartHeight)

            HStack(spacing: 2) {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    Text(verbatim: displayLabel(point.label, index: index))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 柱子多时列宽只有十几点，`10-31` 会被截成 `10-3`，所以长范围只显示「日」。
    private func displayLabel(_ label: String, index: Int) -> String {
        guard index % labelStride == 0 else { return " " }
        if points.count > 12, label.count == 5 { return String(label.suffix(2)) }
        return label
    }

    /// 柱子多的时候标签会重叠，按数量降采样。
    private var labelStride: Int {
        switch points.count {
        case ...8: return 1
        case ...14: return 2
        case ...24: return 3
        default: return 5
        }
    }

    private func bar(_ point: StatsPoint) -> some View {
        let height = maxValue > 0
            ? max(2, chartHeight * Double(point.value) / Double(maxValue))
            : 2
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(barFill(active: point.value > 0))
                .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .help(String(
            format: KBStrings.t(isHourly ? "daily.tooltipHour" : "daily.tooltipDay"),
            point.label,
            point.value
        ))
    }

    private func barFill(active: Bool) -> AnyShapeStyle {
        if active {
            AnyShapeStyle(LinearGradient(
                colors: [.accentColor, .accentColor.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            ))
        } else {
            AnyShapeStyle(Color.primary.opacity(0.08))
        }
    }
}
