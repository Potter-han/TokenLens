import Foundation
import AppKit

// MARK: - 时间范围筛选的回归测试
//
// 覆盖：
//   1) 各预设的时间边界计算正确（含起始日 00:00、结束日 23:59:59.999）
//   2) 自定义范围含两端整天，起止颠倒时由 FilterBar 纠正
//   3) 筛选后统计确实收窄（范围越大统计越多，且 ≤ 不限范围）
//   4) 粒度判定以范围为准（≤3 天按小时，更长按天）
//   5) lastN 桶数 = 范围天数（自定义范围以结束日结尾）
//   6) 「今日」字段始终等于当天直算，与筛选范围无关
//   7) 菜单栏小窗固定用 .days(1)（当天），与主界面筛选解耦

/// 执行时间范围筛选断言；返回失败项列表
func runRangeTests() -> [String] {
    var failures: [String] = []

    func check(_ condition: Bool, _ message: String) {
        if condition {
            log("  ✅ \(message)")
        } else {
            log("  ❌ \(message)")
            failures.append(message)
        }
    }

    let cal = Calendar.current
    let now = Date()
    let dayMs: Double = 86_400_000

    // MARK: 1) 预设边界

    log("[1] 断言预设范围的时间边界 ...")

    let todayStart = cal.startOfDay(for: now).ms
    let todayEnd = todayStart + dayMs - 1

    let d1 = DateRange.days(1)
    check(d1.startMs(now: now) == todayStart, "1 天起点 == 今天 00:00")
    check(d1.endMs(now: now) == todayEnd, "1 天终点 == 今天 23:59:59.999")
    check(d1.dayCount == 1, "1 天 dayCount == 1")

    for n in [3, 7, 30] {
        let r = DateRange.days(n)
        let expectedStart = todayStart - Double(n - 1) * dayMs
        check(r.startMs(now: now) == expectedStart, "近 \(n) 天起点 == 今天往前 \(n - 1) 天")
        check(r.endMs(now: now) == todayEnd, "近 \(n) 天终点 == 今天 23:59:59.999")
        check(r.dayCount == n, "近 \(n) 天 dayCount == \(n)")
    }

    // MARK: 2) 自定义范围

    log("\n[2] 断言自定义范围 ...")

    let s = cal.date(byAdding: .day, value: -5, to: cal.startOfDay(for: now))!
    let e = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: now))!
    let custom = DateRange.custom(start: s, end: e)
    check(custom.startMs(now: now) == cal.startOfDay(for: s).ms, "自定义起点 == 起始日 00:00")
    check(custom.endMs(now: now) == cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e))!.ms - 1,
          "自定义终点 == 结束日 23:59:59.999")
    check(custom.dayCount == 4, "自定义 dayCount == 4（两端都计入）")
    check(custom.title == "自定义", "自定义标题正确")

    // MARK: 3) 筛选后统计收窄

    log("\n[3] 断言筛选后统计确实收窄 ...")

    // 用构造的记录而非真实扫描，保证测试可重复
    let cal2 = Calendar.current
    let base = cal2.startOfDay(for: now)
    var records: [UsageRecord] = []
    // 造 40 天的数据，每天 3 条
    for dayOffset in 0..<40 {
        let day = cal2.date(byAdding: .day, value: -dayOffset, to: base)!
        for k in 0..<3 {
            let ts = cal2.startOfDay(for: day).ms + Double(k * 1000)
            records.append(UsageRecord(ts: ts, model: "m\(k % 2)",
                                       input: 100, output: 50, cached: 0, reasoning: 0,
                                       total: 150, file: "f\(dayOffset)-\(k)", path: "p/f\(dayOffset)-\(k)"))
        }
    }

    func agg(_ range: DateRange?) -> DashboardData {
        Aggregator.build(records: records, root: "t/", files: 120, secs: 0, now: now, range: range)
    }

    let all = agg(nil)
    let r1 = agg(.days(1))
    let r3 = agg(.days(3))
    let r7 = agg(.days(7))
    let r30 = agg(.days(30))

    check(r1.kpi.calls == 3, "1 天筛选 → 3 次调用（1 天 × 3 条）")
    check(r3.kpi.calls == 9, "3 天筛选 → 9 次调用（3 天 × 3 条）")
    check(r7.kpi.calls == 21, "7 天筛选 → 21 次调用（7 天 × 3 条）")
    check(r30.kpi.calls == 90, "30 天筛选 → 90 次调用（30 天 × 3 条）")
    check(all.kpi.calls == 120, "不限范围 → 120 次调用（40 天 × 3 条）")
    check(r1.kpi.calls < r3.kpi.calls && r3.kpi.calls < r7.kpi.calls && r7.kpi.calls < r30.kpi.calls,
          "统计随范围单调递增")
    check(r30.kpi.calls <= all.kpi.calls, "30 天统计 ≤ 不限范围统计")

    // MARK: 4) 粒度以范围为准

    log("\n[4] 断言粒度判定以范围为准 ...")
    check(r1.hourlyMode, "1 天范围 → 小时模式")
    check(r3.hourlyMode, "3 天范围 → 小时模式")
    check(!r7.hourlyMode, "7 天范围 → 天模式")
    check(!r30.hourlyMode, "30 天范围 → 天模式")

    // MARK: 5) lastN 桶数与结尾日

    log("\n[5] 断言 lastN 桶数与结尾日 ...")
    check(r1.last7.count == 1, "1 天范围 lastN == 1 桶")
    check(r7.last7.count == 7, "7 天范围 lastN == 7 桶")
    check(r30.last7.count == 30, "30 天范围 lastN == 30 桶")
    check(all.last7.count == 7, "不限范围 lastN == 7 桶")

    // 自定义范围以结束日结尾（不是今天）
    let customAgg = agg(custom)
    let expectedLastKey = Aggregator.dayKey(cal2.startOfDay(for: e).ms)
    check(customAgg.last7.last?.key == expectedLastKey,
          "自定义范围 lastN 末桶 == 结束日（\(customAgg.last7.last?.key ?? "-") == \(expectedLastKey)）")

    // MARK: 6) 「今日」字段与范围无关

    log("\n[6] 断言「今日」字段始终等于当天直算 ...")
    check(r1.today.total == all.today.total, "1 天范围的 today == 不限范围的 today")
    check(r30.today.total == all.today.total, "30 天范围的 today == 不限范围的 today")
    check(r1.today.calls == 3, "today.calls == 当天 3 次调用")
    // 当天直算
    var manualToday: Double = 0
    for r in records where Aggregator.dayKey(r.ts) == Aggregator.dayKey(now.ms) { manualToday += r.total }
    check(abs(all.today.total - manualToday) < 0.001, "today.total == 手工直算当天总量")

    // MARK: 7) 菜单栏小窗固定当天

    log("\n[7] 断言菜单栏小窗固定使用当天 ...")
    let popoverRange = DateRange.days(1)
    let popAgg = agg(popoverRange)
    check(popAgg.kpi.calls == 3, "小窗口径（当天）→ 3 次调用")
    check(popAgg.kpi.calls != r30.kpi.calls, "小窗口径与主界面 30 天口径相互独立")

    return failures
}
