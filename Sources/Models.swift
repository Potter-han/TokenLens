import Foundation

// MARK: - 扫描根

/// 一个扫描根：实际遍历的目录 + 相对路径基准
///
/// base 用于计算文件的相对路径（会话身份）。自动探测会把
/// ~/.workbuddy 拆成 traces / projects 两个子目录分别扫描，
/// 此时 base 仍是 ~/.workbuddy，保证「工作空间」归组与整目录扫描一致。
struct ScanRoot {
    let url: URL      // 实际遍历的目录
    let base: URL     // 相对路径基准（工具主目录）

    init(url: URL, base: URL) {
        self.url = url
        self.base = base
    }
}

// MARK: - 数据模型

struct UsageFields {
    var input: Double = 0
    var output: Double = 0
    var cached: Double = 0
    var reasoning: Double = 0
    var total: Double = 0
    /// 本次响应是否返回了思考 token 数（缺失 ≠ 0，缺失说明思考过程未外露）
    var reasoningExposed: Bool = false
}

struct UsageRecord {
    var ts: Double        // ms epoch（调用结束时刻）
    var model: String
    var input: Double
    var output: Double
    var cached: Double
    var reasoning: Double
    var total: Double
    var file: String      // 文件名
    var path: String      // 相对路径（会话身份）
    /// 生成耗时（ms）：trace 来源 = 首字→结束；会话日志来源 = 时间戳估算
    var durationMs: Double = 0
    /// 首字时刻（ms，仅 trace 来源可得）
    var firstTokenMs: Double = 0
    /// 是否来自路由 trace（精确计时）
    var fromTrace: Bool = false
    /// 该次响应是否返回了思考 token 数
    var reasoningExposed: Bool = true
    /// 每秒输出 token；0 = 不展示（样本不足 / 无计时）
    var speedTps: Double = 0
    /// true = 会话日志时间戳估算（含等首字时间，偏低）
    var speedEstimated: Bool = false

    /// 本次调用的预估成本
    var cost: Double { Pricing.cost(input: input, cached: cached, output: output) }
}

struct KPI {
    var total: Double = 0
    var input: Double = 0
    var output: Double = 0
    var cached: Double = 0
    var reasoning: Double = 0
    var calls: Int = 0
    var sessions: Int = 0
    var activeDays: Int = 0
    var avgPerActiveDay: Double = 0
    var cacheHit: Double = 0      // 0-1
    var estCost: Double = 0
    var models: Int = 0
}

struct DayBucket {
    var key: String       // yyyy-MM-dd 或 yyyy-MM-dd HH:00
    var input: Double
    var output: Double
    var total: Double
    var calls: Int = 0      // 该桶内的调用次数（菜单栏小窗「较昨日」用）
    var cost: Double = 0    // 该桶内的预估费用
}

struct NamedStat {
    var name: String
    var total: Double
    var pct: Double       // 0-1（占总量）
    var sessions: Int
}

/// 单个模型在 0–24 时上的 token 分布（按小时聚合，用于峰值图）
struct HourModelStat {
    var name: String
    var hours: [Double]   // 长度 24，下标 = 小时（0…23）
    var total: Double
    /// true = 这是把长尾模型合并出来的「其他」聚合项（绘图时降权显示）
    var isAggregate: Bool = false

    /// 峰值所在的小时
    var peakHour: Int {
        var best = 0
        for (i, v) in hours.enumerated() where v > hours[best] { best = i }
        return best
    }
}

struct DashboardData {
    var kpi: KPI
    var daily: [DayBucket]        // 升序，最多 72 桶
    var hourlyMode: Bool
    var models: [NamedStat]
    var workspaces: [NamedStat]
    var recent: [UsageRecord]     // 时间倒序
    var last7: [DayBucket]        // 恒 7 天，旧→新
    var today: (total: Double, calls: Int, cost: Double)
    var rootLabel: String
    var scannedAt: Date
    var filesScanned: Int
    var scanSeconds: Double
    var hourlyByModel: [HourModelStat]   // 0–24 时分布（按模型，按总量降序）
    /// 始终按自然日聚合（不受 hourly 模式影响），含调用次数与费用，升序
    /// 菜单栏小窗用它算「较昨日」和近 7 天迷你走势图
    var byDay: [DayBucket]
    /// 0–23 时的 token 总量（24 项）
    var hourlyTokens: [Double]
    /// 0–23 时的预估费用（24 项）
    var hourlyCost: [Double]
}

// MARK: - 价格估算（粗略，可调）

enum Pricing {
    static let inputPerM = 2.0    // ¥ / 百万 tokens（未命中缓存部分）
    static let cachedPerM = 0.2
    static let outputPerM = 8.0
    static func cost(input: Double, cached: Double, output: Double) -> Double {
        let plain = max(input - cached, 0)
        return plain / 1e6 * inputPerM + cached / 1e6 * cachedPerM + output / 1e6 * outputPerM
    }
}

// MARK: - 聚合器（与 web 版 aggregate() 等价 + 看板扩展）

enum Aggregator {
    /// 速度门槛：路由 trace 来源要求输出 ≥ 100 token，会话日志估算来源要求 ≥ 200 token
    static let speedMinTokensTrace: Double = 100
    static let speedMinTokensSession: Double = 200

    /// 构建看板数据
    ///
    /// - Parameter range: 时间范围筛选；nil 表示不限（统计全部历史）。
    ///   过滤发生在去重之后，因此同一份扫描结果可反复按不同范围重新聚合，
    ///   无需重新扫盘（实测 4276 条记录聚合约 20ms）。
    static func build(records: [UsageRecord], root: String, files: Int, secs: Double,
                      now: Date = Date(), range: DateRange? = nil) -> DashboardData {
        // 同一次调用会同时落在 traces 与会话日志中，先去重（trace 优先，计时更准）
        var records = dedupe(records).map { withSpeed($0) }

        // 时间范围过滤（闭区间）
        if let range {
            let lo = range.startMs(now: now)
            let hi = range.endMs(now: now)
            records = records.filter { $0.ts >= lo && $0.ts <= hi }
        }

        var kpi = KPI()
        var minTs = Double.infinity, maxTs = 0.0
        var modelTotals: [String: Double] = [:]
        var fileSet = Set<String>()

        for r in records {
            kpi.total += r.total; kpi.input += r.input; kpi.output += r.output
            kpi.cached += r.cached; kpi.reasoning += r.reasoning
            if r.ts > 0 { minTs = min(minTs, r.ts); maxTs = max(maxTs, r.ts) }
            modelTotals[r.model, default: 0] += r.total
            fileSet.insert(r.path)
        }
        kpi.calls = records.count
        kpi.sessions = fileSet.count

        let spanDays = (maxTs - minTs) / 86_400_000
        // 粒度判定以「筛选范围」为准，而非数据实际跨度：
        //   - 范围 ≤ 3 天 → 按小时（最多 72 桶 = 3×24）
        //   - 更长 → 按天
        // 这样「近 3 天」始终能看出日内分布，不会因某天数据集中而退化成 3 个日柱。
        let hourly: Bool
        if let range {
            hourly = records.count > 0 && range.dayCount <= 3
        } else {
            hourly = records.count > 0 && spanDays <= 2
        }

        var buckets: [String: (input: Double, output: Double)] = [:]
        for r in records {
            let key = hourly ? dayHourKey(r.ts) : dayKey(r.ts)
            var b = buckets[key] ?? (0, 0)
            b.input += r.input; b.output += r.output
            buckets[key] = b
        }
        var daily = buckets.map { DayBucket(key: $0.key, input: $0.value.input, output: $0.value.output, total: $0.value.input + $0.value.output) }
            .sorted { $0.key < $1.key }
        // 桶数上限：小时模式 72 桶（3 天），天模式按范围天数（最多 366）
        let maxBuckets = hourly ? 72 : max(72, min(range?.dayCount ?? 72, 366))
        if daily.count > maxBuckets { daily = Array(daily.suffix(maxBuckets)) }

        // 按自然日聚合（始终按天，与 hourly 模式无关）：
        //   - byDay：菜单栏小窗的「较昨日」对比 + 近 7 天迷你走势图
        //   - hourlyTokens / hourlyCost：小窗分时柱状图（tokens / 费用两种口径）
        var byDayMap: [String: DayBucket] = [:]
        var hourlyTokens = [Double](repeating: 0, count: 24)
        var hourlyCost = [Double](repeating: 0, count: 24)
        for r in records {
            let key = dayKey(r.ts)
            var b = byDayMap[key] ?? DayBucket(key: key, input: 0, output: 0, total: 0)
            b.input += r.input; b.output += r.output; b.total += r.total
            b.calls += 1; b.cost += r.cost
            byDayMap[key] = b
            let h = hourOfDay(r.ts)
            hourlyTokens[h] += r.total
            hourlyCost[h] += r.cost
        }
        let byDay = byDayMap.values.sorted { $0.key < $1.key }
        // 活跃天数：小时模式下 daily 装的是小时桶，需按天去重，否则「日均消耗」会被稀释
        kpi.activeDays = hourly ? Set(daily.map { String($0.key.prefix(10)) }).count : daily.count
        kpi.avgPerActiveDay = kpi.activeDays > 0 ? kpi.total / Double(kpi.activeDays) : 0
        let inDenom = kpi.input + kpi.cached
        kpi.cacheHit = inDenom > 0 ? kpi.cached / inDenom : 0
        kpi.estCost = Pricing.cost(input: kpi.input, cached: kpi.cached, output: kpi.output)
        kpi.models = modelTotals.count

        // 模型 Top6 + 其他（其余合并为一行，占比按总量计）
        let sortedModels = modelTotals.sorted { $0.value > $1.value }
        var modelStats: [NamedStat] = []
        for m in sortedModels.prefix(6) {
            modelStats.append(NamedStat(name: m.key, total: m.value,
                                        pct: kpi.total > 0 ? m.value / kpi.total : 0, sessions: 0))
        }
        if sortedModels.count > 6 {
            let rest = sortedModels.dropFirst(6)
            let restTotal = rest.reduce(0) { $0 + $1.value }
            modelStats.append(NamedStat(name: "其他 \(rest.count) 个模型", total: restTotal,
                                        pct: kpi.total > 0 ? restTotal / kpi.total : 0, sessions: 0))
        }

        // 工作空间分布（按相对路径第一段；projects/<名> 取第二段）Top6 + 其他
        var wsTotals: [String: Double] = [:]
        var wsSessions: [String: Set<String>] = [:]
        for r in records {
            let ws = workspaceName(of: r.path)
            wsTotals[ws, default: 0] += r.total
            wsSessions[ws, default: []].insert(r.path)
        }
        var wsStats: [NamedStat] = []
        let sortedWs = wsTotals.sorted { $0.value > $1.value }
        for w in sortedWs.prefix(6) {
            wsStats.append(NamedStat(name: w.key, total: w.value,
                                     pct: kpi.total > 0 ? w.value / kpi.total : 0,
                                     sessions: wsSessions[w.key]?.count ?? 0))
        }
        if sortedWs.count > 6 {
            let rest = sortedWs.dropFirst(6)
            let restTotal = rest.reduce(0) { $0 + $1.value }
            let restSessions = rest.reduce(0) { $0 + (wsSessions[$1.key]?.count ?? 0) }
            wsStats.append(NamedStat(name: "其他 \(rest.count) 个", total: restTotal,
                                     pct: kpi.total > 0 ? restTotal / kpi.total : 0, sessions: restSessions))
        }

        // lastN（含空日）：天数随筛选范围变化
        //   - 不限范围 → 7 天（菜单栏小窗用）
        //   - 有范围 → 该范围覆盖的天数（主界面趋势条用）
        // 注意：小时模式下 daily 的 key 含小时，需先按天聚合再取，否则一天会出现多次
        var dayMap: [String: DayBucket] = [:]
        for b in daily {
            let dayKey = String(b.key.prefix(10))
            if let exist = dayMap[dayKey] {
                dayMap[dayKey] = DayBucket(key: dayKey,
                                           input: exist.input + b.input,
                                           output: exist.output + b.output,
                                           total: exist.total + b.total)
            } else {
                dayMap[dayKey] = DayBucket(key: dayKey, input: b.input, output: b.output, total: b.total)
            }
        }
        var lastN: [DayBucket] = []
        let cal = Calendar.current
        let lastNCount = max(1, min(range?.dayCount ?? 7, 30))
        // 末日：自定义范围以「结束日」结尾，预设/不限以今天结尾
        let lastDay: Date = {
            if case .custom(_, let e) = range { return cal.startOfDay(for: e) }
            return cal.startOfDay(for: now)
        }()
        for i in stride(from: lastNCount - 1, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -i, to: lastDay) ?? lastDay
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            if let b = dayMap[key] { lastN.append(b) }
            else { lastN.append(DayBucket(key: key, input: 0, output: 0, total: 0)) }
        }

        // 0–24 时分布（按模型）：每个模型 24 个小时的 token 总量
        var hourModelBuckets: [String: [Double]] = [:]
        for r in records {
            let h = hourOfDay(r.ts)
            var arr = hourModelBuckets[r.model] ?? [Double](repeating: 0, count: 24)
            arr[h] += r.total
            hourModelBuckets[r.model] = arr
        }
        // 总量前 5 个模型各自成线，其余合并为「其他」
        let sortedByHour = hourModelBuckets.sorted {
            $0.value.reduce(0, +) > $1.value.reduce(0, +)
        }
        var hourlyByModel: [HourModelStat] = []
        for (name, arr) in sortedByHour.prefix(5) {
            hourlyByModel.append(HourModelStat(name: name, hours: arr, total: arr.reduce(0, +)))
        }
        if sortedByHour.count > 5 {
            var merged = [Double](repeating: 0, count: 24)
            for (_, arr) in sortedByHour.dropFirst(5) {
                for i in 0..<24 { merged[i] += arr[i] }
            }
            hourlyByModel.append(HourModelStat(name: "其他 \(sortedByHour.count - 5) 个模型",
                                              hours: merged, total: merged.reduce(0, +),
                                              isAggregate: true))
        }

        // 今日：始终统计「今天」，与筛选范围无关
        //   （筛选「近 7 天」时主界面看的是 7 天汇总，但「今日」卡片仍表示今天）
        let todayKey = dayKey(now.timeIntervalSince1970 * 1000)
        var todayTotal = 0.0, todayCalls = 0
        var tIn = 0.0, tOut = 0.0, tCached = 0.0
        for r in records where dayKey(r.ts) == todayKey {
            todayTotal += r.total; todayCalls += 1
            tIn += r.input; tOut += r.output; tCached += r.cached
        }
        let todayCost = Pricing.cost(input: tIn, cached: tCached, output: tOut)

        let recent = records.sorted { $0.ts > $1.ts }
        return DashboardData(
            kpi: kpi, daily: daily, hourlyMode: hourly,
            models: modelStats, workspaces: wsStats,
            recent: Array(recent.prefix(120)), last7: lastN,
            today: (todayTotal, todayCalls, todayCost),
            rootLabel: root, scannedAt: now, filesScanned: files, scanSeconds: secs,
            hourlyByModel: hourlyByModel,
            byDay: byDay, hourlyTokens: hourlyTokens, hourlyCost: hourlyCost)
    }

    // MARK: 去重

    /// 同一次调用会同时写入 traces 与会话日志：两份记录时间戳对齐在 0.05s 内，
    /// token 与缓存口径完全一致。以 (输入, 输出, 合计, 缓存) + 时间邻近做签名，
    /// 命中则保留 trace 记录（带精确计时），丢弃会话日志副本。
    private static func dedupe(_ records: [UsageRecord]) -> [UsageRecord] {
        var traceIndex: [String: [Int]] = [:]
        for (i, r) in records.enumerated() where r.fromTrace {
            traceIndex[signature(r), default: []].append(i)
        }
        var consumed = Set<Int>()
        var out: [UsageRecord] = []
        out.reserveCapacity(records.count)
        for (i, r) in records.enumerated() {
            if r.fromTrace {
                out.append(r)
                continue
            }
            var duplicated = false
            if let candidates = traceIndex[signature(r)] {
                for j in candidates where !consumed.contains(j) {
                    if abs(records[j].ts - r.ts) <= 2_000 {
                        consumed.insert(j)
                        duplicated = true
                        break
                    }
                }
            }
            if !duplicated { out.append(r) }
        }
        return out
    }

    private static func signature(_ r: UsageRecord) -> String {
        "\(Int(r.input))|\(Int(r.output))|\(Int(r.total))|\(Int(r.cached))"
    }

    // MARK: 速度

    /// 速度 = 输出 token ÷ 生成耗时
    /// - 路由 trace 来源：耗时 = 首字→结束（精确），要求输出 ≥ 100 token
    /// - 会话日志来源：耗时 = 时间戳估算（含等首字时间，偏低），要求输出 ≥ 200 token
    private static func withSpeed(_ r: UsageRecord) -> UsageRecord {
        var r = r
        let threshold = r.fromTrace ? speedMinTokensTrace : speedMinTokensSession
        if r.durationMs > 0 && r.output >= threshold {
            r.speedTps = r.output / (r.durationMs / 1000)
        }
        r.speedEstimated = !r.fromTrace
        return r
    }

    static func workspaceName(of relPath: String) -> String {
        let parts = relPath.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return "根目录" }
        if parts[0] == "projects" && parts.count >= 3 { return parts[1] }
        return parts[0]
    }

    static func dayKey(_ ms: Double) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }
    static func dayHourKey(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: d)
        return String(format: "%04d-%02d-%02d %02d:00", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
    }
    /// 调用发生的小时（0…23），用于 0–24 时分布图
    static func hourOfDay(_ ms: Double) -> Int {
        let c = Calendar.current.dateComponents([.hour], from: Date(timeIntervalSince1970: ms / 1000))
        return min(max(c.hour ?? 0, 0), 23)
    }
}

// MARK: - 格式化（中文亿/万风格，对齐参考图）

enum Fmt {
    static func int(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v.rounded()))"
    }
    /// 2.12亿 / 1763.0万 / 1,234 / 56
    static func cn(_ v: Double) -> String {
        if v >= 1e8 { return String(format: "%.2f", v / 1e8) + "亿" }
        if v >= 1e4 { return String(format: "%.1f", v / 1e4) + "万" }
        if v >= 1000 { return int(v) }
        return "\(Int(v.rounded()))"
    }
    /// 与 cn 相同，但中文单位前留一个空格（悬浮提示用）
    static func cnSpaced(_ v: Double) -> String {
        if v >= 1e8 { return String(format: "%.2f", v / 1e8) + " 亿" }
        if v >= 1e4 { return String(format: "%.1f", v / 1e4) + " 万" }
        if v >= 1000 { return int(v) }
        return "\(Int(v.rounded()))"
    }
    /// 坐标轴紧凑：去尾零
    static func axis(_ v: Double) -> String {
        if v >= 1e8 { return trail(v / 1e8, 1) + "亿" }
        if v >= 1e4 { return trail(v / 1e4, 1) + "万" }
        if v >= 1000 { return int(v) }
        return trail(v, 1)
    }
    static func cost(_ v: Double) -> String {
        if v >= 100 { return "¥" + int(v) }
        if v >= 1 { return "¥" + String(format: "%.1f", v) }
        return "¥" + String(format: "%.2f", v)
    }
    static func pct(_ v: Double) -> String {
        if v > 0 && v < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", v * 100)
    }
    /// 速度：token/秒
    static func speed(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
    static func trail(_ v: Double, _ places: Int) -> String {
        var s = String(format: "%.\(places)f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "0" : s
    }
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
    static func recordTime(_ ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
    static func bucketLabel(_ key: String, hourly: Bool) -> String {
        if hourly { return String(key.dropFirst(5)) }   // MM-dd HH:00 → 去年份
        let p = key.split(separator: "-")
        guard p.count == 3 else { return key }
        return "\(p[1])/\(p[2])"
    }
}
