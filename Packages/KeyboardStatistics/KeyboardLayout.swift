import SwiftUI

/// 一颗键帽。`width` 以「1u（普通字母键）」为单位，便于按比例缩放。
struct KeyCap: Identifiable {
    let code: Int64?
    let label: String
    let width: CGFloat

    var id: String {
        guard let code else { return "spacer-\(label)-\(width)" }
        return "\(code)-\(label)"
    }
}

/// US ANSI 60% 布局。键位用 HID usage（即 `CGEvent` 的 keyCode）标注，
/// 与键盘语言/输入源无关——这里统计的是物理位置，不是字符。
enum KeyboardLayout {
    static let unit: CGFloat = 30
    static let spacing: CGFloat = 3
    static let keyHeight: CGFloat = 27
    static let rowCount = 5

    static var height: CGFloat {
        CGFloat(rowCount) * keyHeight + CGFloat(rowCount - 1) * spacing
    }

    static let rows: [[KeyCap]] = [
        // ` 1 2 3 4 5 6 7 8 9 0 - = ⌫
        [
            KeyCap(code: 0x32, label: "`", width: 1),
            KeyCap(code: 0x12, label: "1", width: 1),
            KeyCap(code: 0x13, label: "2", width: 1),
            KeyCap(code: 0x14, label: "3", width: 1),
            KeyCap(code: 0x15, label: "4", width: 1),
            KeyCap(code: 0x17, label: "5", width: 1),
            KeyCap(code: 0x16, label: "6", width: 1),
            KeyCap(code: 0x1A, label: "7", width: 1),
            KeyCap(code: 0x1C, label: "8", width: 1),
            KeyCap(code: 0x19, label: "9", width: 1),
            KeyCap(code: 0x1D, label: "0", width: 1),
            KeyCap(code: 0x1B, label: "-", width: 1),
            KeyCap(code: 0x18, label: "=", width: 1),
            KeyCap(code: 0x33, label: "⌫", width: 2),
        ],
        // ⇥ Q W E R T Y U I O P [ ] \
        [
            KeyCap(code: 0x30, label: "⇥", width: 1.5),
            KeyCap(code: 0x0C, label: "Q", width: 1),
            KeyCap(code: 0x0D, label: "W", width: 1),
            KeyCap(code: 0x0E, label: "E", width: 1),
            KeyCap(code: 0x0F, label: "R", width: 1),
            KeyCap(code: 0x11, label: "T", width: 1),
            KeyCap(code: 0x10, label: "Y", width: 1),
            KeyCap(code: 0x20, label: "U", width: 1),
            KeyCap(code: 0x22, label: "I", width: 1),
            KeyCap(code: 0x1F, label: "O", width: 1),
            KeyCap(code: 0x23, label: "P", width: 1),
            KeyCap(code: 0x21, label: "[", width: 1),
            KeyCap(code: 0x1E, label: "]", width: 1),
            KeyCap(code: 0x2A, label: "\\", width: 1.5),
        ],
        // ⇪ A S D F G H J K L ; ' ⏎
        [
            KeyCap(code: 0x39, label: "⇪", width: 1.75),
            KeyCap(code: 0x00, label: "A", width: 1),
            KeyCap(code: 0x01, label: "S", width: 1),
            KeyCap(code: 0x02, label: "D", width: 1),
            KeyCap(code: 0x03, label: "F", width: 1),
            KeyCap(code: 0x05, label: "G", width: 1),
            KeyCap(code: 0x04, label: "H", width: 1),
            KeyCap(code: 0x26, label: "J", width: 1),
            KeyCap(code: 0x28, label: "K", width: 1),
            KeyCap(code: 0x25, label: "L", width: 1),
            KeyCap(code: 0x29, label: ";", width: 1),
            KeyCap(code: 0x27, label: "'", width: 1),
            KeyCap(code: 0x24, label: "⏎", width: 2.25),
        ],
        // ⇧ Z X C V B N M , . / ⇧
        [
            KeyCap(code: 0x38, label: "⇧", width: 2.25),
            KeyCap(code: 0x06, label: "Z", width: 1),
            KeyCap(code: 0x07, label: "X", width: 1),
            KeyCap(code: 0x08, label: "C", width: 1),
            KeyCap(code: 0x09, label: "V", width: 1),
            KeyCap(code: 0x0B, label: "B", width: 1),
            KeyCap(code: 0x2D, label: "N", width: 1),
            KeyCap(code: 0x2E, label: "M", width: 1),
            KeyCap(code: 0x2B, label: ",", width: 1),
            KeyCap(code: 0x2F, label: ".", width: 1),
            KeyCap(code: 0x2C, label: "/", width: 1),
            KeyCap(code: 0x3C, label: "⇧", width: 2.75),
        ],
        // fn ⌃ ⌥ ⌘ space ⌘ ⌥ ← ↑ ↓ →
        [
            KeyCap(code: 0x3F, label: "fn", width: 1),
            KeyCap(code: 0x3B, label: "⌃", width: 1.25),
            KeyCap(code: 0x3A, label: "⌥", width: 1.25),
            KeyCap(code: 0x37, label: "⌘", width: 1.25),
            KeyCap(code: 0x31, label: "space", width: 5.5),
            KeyCap(code: 0x36, label: "⌘", width: 1.25),
            KeyCap(code: 0x3D, label: "⌥", width: 1.25),
            KeyCap(code: 0x7B, label: "←", width: 0.5625),
            KeyCap(code: 0x7E, label: "↑", width: 0.5625),
            KeyCap(code: 0x7D, label: "↓", width: 0.5625),
            KeyCap(code: 0x7C, label: "→", width: 0.5625),
        ],
    ]

    /// 60% 布局之外的常见键，列表里用可读名字而不是裸键码。
    private static let extraLabels: [Int64: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x52: "小键盘0", 0x53: "小键盘1", 0x54: "小键盘2", 0x55: "小键盘3", 0x56: "小键盘4",
        0x57: "小键盘5", 0x58: "小键盘6", 0x59: "小键盘7", 0x5B: "小键盘8", 0x5C: "小键盘9",
    ]

    /// 只在 60% 布局里出现过的键码。
    private static let layoutLabels: [Int64: String] = {
        var map: [Int64: String] = [:]
        for row in rows {
            for key in row {
                if let code = key.code, map[code] == nil { map[code] = key.label }
            }
        }
        return map
    }()

    /// 键码 → 可读名字（布局内的键 + 常见布局外键）。
    static let labels: [Int64: String] = layoutLabels.merging(extraLabels) { current, _ in current }

    /// 小键盘 / F 键 / JIS 键不在 60% 布局里，单独以「布局外」列表展示。
    static func inLayout(_ code: Int64) -> Bool { layoutLabels[code] != nil }

    static func label(for code: Int64) -> String {
        labels[code] ?? String(format: "0x%02X", code)
    }
}

// MARK: - 热力图

/// 键盘热力图：颜色深浅表示该键在所选时间范围内的次数。
/// 归一化用平方根，避免空格这种高频键把其它键全压成近似透明。
struct KeyboardHeatmapView: View {
    let counts: [Int64: Int]
    let maxCount: Int

    var body: some View {
        GeometryReader { proxy in
            // 键帽宽度随行宽缩放。固定 30pt 时整块宽 489pt，插件设置窗口只有 560pt，
            // 减去 grouped Form 的标签列与内边距必然溢出；一旦溢出，Form 会把列宽撑大，
            // 表现为整页内容右移、右侧被裁掉（滚动视图也救不回来）。
            let unit = max(16, (proxy.size.width - KeyboardLayout.spacing * 14) / 15)
            VStack(alignment: .leading, spacing: KeyboardLayout.spacing) {
                ForEach(Array(KeyboardLayout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: KeyboardLayout.spacing) {
                        ForEach(row) { key in
                            keyCap(key, unit: unit)
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: KeyboardLayout.height)
    }

    private func keyCap(_ key: KeyCap, unit: CGFloat) -> some View {
        let count = key.code.map { counts[$0] ?? 0 } ?? 0
        let intensity = intensity(count)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(fill(intensity))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
            .overlay(
                Text(verbatim: key.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(intensity > 0.65 ? Color.white : Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 1)
            )
            .frame(
                width: key.width * unit,
                height: unit * (KeyboardLayout.keyHeight / KeyboardLayout.unit)
            )
            .help(String(format: KBStrings.t("heatmap.tooltip"), key.label, count))
            .accessibilityLabel(Text(verbatim: "\(key.label) \(count)"))
    }

    private func intensity(_ count: Int) -> Double {
        guard maxCount > 0, count > 0 else { return 0 }
        return min(1, (Double(count) / Double(maxCount)).squareRoot())
    }

    private func fill(_ intensity: Double) -> Color {
        intensity <= 0
            ? Color.primary.opacity(0.06)
            : Color.accentColor.opacity(0.12 + 0.85 * intensity)
    }
}

/// 颜色深浅的图例：少 → 多。
struct KeyboardHeatmapLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: KBStrings.t("heatmap.legendLow"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12 + 0.85 * Double(step) / 5))
                        .frame(width: 14, height: 8)
                }
            }
            Text(verbatim: KBStrings.t("heatmap.legendHigh"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
