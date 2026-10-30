import Foundation

// MARK: - 时间范围筛选
//
// 主界面顶部的筛选条件：1 天 / 3 天 / 近 7 天 / 近 30 天 / 自定义日期范围。
//
// 设计要点：
//   - 筛选只影响「统计口径」，不触发重新扫盘。
//     扫描一次拿到全部记录，切换范围时只重新聚合（实测 ~20ms，瞬时响应）。
//   - 菜单栏小窗固定展示「当天」数据，与主界面的筛选范围互不影响。
//   - 自定义范围用「起始日 00:00 ~ 结束日 23:59:59.999」闭区间，
//     保证用户选中的两天都完整计入。

/// 时间范围
enum DateRange: Equatable, Identifiable {
    /// 最近 N 天（含今天）
    case days(Int)
    /// 自定义区间：起始日 ~ 结束日（含两端整天）
    case custom(start: Date, end: Date)

    /// 预设选项（界面展示顺序）
    static let presets: [DateRange] = [.days(1), .days(3), .days(7), .days(30)]

    var id: String {
        switch self {
        case .days(let n): return "d\(n)"
        case .custom(let s, let e): return "c\(Int(s.timeIntervalSince1970))-\(Int(e.timeIntervalSince1970))"
        }
    }

    /// 按钮标题
    var title: String {
        switch self {
        case .days(1): return "1 天"
        case .days(3): return "3 天"
        case .days(7): return "近 7 天"
        case .days(30): return "近 30 天"
        case .days(let n): return "\(n) 天"
        case .custom: return "自定义"
        }
    }

    /// 是否为某个预设（用于高亮）
    func matches(_ preset: DateRange) -> Bool { self == preset }

    // MARK: 时间边界

    /// 起始时刻（毫秒时间戳，闭区间左端）
    func startMs(now: Date = Date(), calendar: Calendar = .current) -> Double {
        switch self {
        case .days(let n):
            return startOfToday(now, calendar).addingTimeInterval(-Double(max(0, n - 1)) * 86_400).ms
        case .custom(let s, _):
            return calendar.startOfDay(for: s).ms
        }
    }

    /// 结束时刻（毫秒时间戳，闭区间右端，含结束日整天）
    func endMs(now: Date = Date(), calendar: Calendar = .current) -> Double {
        switch self {
        case .days:
            // 「近 N 天」= 今天 23:59:59.999 结束
            return endOfToday(now, calendar).ms
        case .custom(_, let e):
            return endOfToday(e, calendar).ms
        }
    }

    /// 覆盖的天数（用于图表刻度与说明文字）
    var dayCount: Int {
        switch self {
        case .days(let n): return max(1, n)
        case .custom(let s, let e):
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: s), to: cal.startOfDay(for: e)).day ?? 0
            return max(1, days + 1)
        }
    }

    /// 范围说明（副标题用）
    func summary(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        switch self {
        case .days(let n):
            let start = Date(timeIntervalSince1970: startMs(now: now) / 1000)
            return "\(f.string(from: start)) - \(f.string(from: now))"
        case .custom(let s, let e):
            f.dateFormat = "yyyy年M月d日"
            return "\(f.string(from: s)) - \(f.string(from: e))"
        }
    }

    // MARK: 辅助

    private func startOfToday(_ now: Date, _ cal: Calendar) -> Date {
        cal.startOfDay(for: now)
    }
    private func endOfToday(_ date: Date, _ cal: Calendar) -> Date {
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001) ?? date
    }
}

extension Date {
    /// 毫秒时间戳（与 UsageRecord.ts 同一口径）
    var ms: Double { timeIntervalSince1970 * 1000 }
}

// MARK: - 筛选状态

/// 筛选状态：主界面用范围筛选，菜单栏小窗固定用「当天」
struct FilterState: Equatable {
    /// 主界面的时间范围
    var range: DateRange = .days(30)
    /// 菜单栏小窗固定展示当天
    var popoverRange: DateRange = .days(1)
}
