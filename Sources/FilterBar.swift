import SwiftUI
import AppKit

// MARK: - 时间范围筛选栏
//
// 设计图：胶囊按钮组（1 天 / 3 天 / 近 7 天 / 近 30 天）+ 自定义日期区间（起 ~ 止）。
//
// 行为：
//   - 点预设按钮 → 立即切换并重新聚合
//   - 自定义区间：改任一端日期即生效（起 > 止时自动纠正）
//   - 选中态用蓝色描边 + 浅蓝底，与设计图一致

struct FilterBar: View {
    @Binding var range: DateRange

    /// 自定义区间的两个端点（仅在自定义模式下生效）
    @State private var customStart: Date = Date()
    @State private var customEnd: Date = Date()

    /// 是否正处于自定义模式
    private var isCustom: Bool {
        if case .custom = range { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            // 预设按钮组
            ForEach(DateRange.presets) { preset in
                presetButton(preset)
            }

            // 自定义区间
            HStack(spacing: 6) {
                dateField(isStart: true)
                Text("至")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                dateField(isStart: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            Spacer(minLength: 0)

            // 范围说明
            Text(range.summary())
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .onAppear(perform: syncCustomDates)
        .onChange(of: range) { _, _ in syncCustomDates() }
    }

    // MARK: 预设按钮

    private func presetButton(_ preset: DateRange) -> some View {
        let selected = range == preset
        return Button {
            range = preset
        } label: {
            Text(preset.title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(Color.violetBright) : AnyShapeStyle(Color.secondary))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Color.violetBright.opacity(0.16) : Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Color.violetBright.opacity(0.6) : Color.primary.opacity(0.10),
                                      lineWidth: selected ? 1.4 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("统计\(preset.title)的用量")
        .accessibilityLabel("\(preset.title)筛选\(selected ? "，已选中" : "")")
    }

    // MARK: 自定义日期输入

    @ViewBuilder
    private func dateField(isStart: Bool) -> some View {
        let binding = Binding<Date>(
            get: { isStart ? customStart : customEnd },
            set: { newValue in
                if isStart { customStart = newValue } else { customEnd = newValue }
                applyCustom()
            })
        DatePicker("", selection: binding, displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .controlSize(.small)
    }

    /// 应用自定义区间：起止顺序颠倒时自动交换
    private func applyCustom() {
        let cal = Calendar.current
        let s = cal.startOfDay(for: customStart)
        let e = cal.startOfDay(for: customEnd)
        let (start, end) = s <= e ? (s, e) : (e, s)
        customStart = start
        customEnd = end
        range = .custom(start: start, end: end)
    }

    /// 同步自定义端点：预设模式下显示该预设对应的实际日期
    private func syncCustomDates() {
        let cal = Calendar.current
        let now = Date()
        switch range {
        case .days(let n):
            let start = cal.startOfDay(for: now).addingTimeInterval(-Double(max(0, n - 1)) * 86_400)
            customStart = start
            customEnd = cal.startOfDay(for: now)
        case .custom(let s, let e):
            customStart = cal.startOfDay(for: s)
            customEnd = cal.startOfDay(for: e)
        }
    }
}
