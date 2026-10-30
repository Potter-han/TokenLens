import SwiftUI
import Combine

// MARK: - 状态容器

@MainActor
final class ScanStore: ObservableObject {
    /// 全局唯一实例：主窗口、菜单栏弹窗、设置页共用同一份数据与刷新计时器
    static let shared = ScanStore()

    @Published var data: DashboardData?
    @Published var status: String = "未扫描"
    @Published var busy = false
    /// 当前已扫描的根目录集合（来自「应用配置」里的多个 AI 工具目录）
    @Published var roots: [ScanRoot] = []
    /// 主界面的时间范围筛选（默认近 30 天）
    @Published var range: DateRange = .days(30) {
        didSet { if range != oldValue { reaggregate() } }
    }

    // MARK: 菜单栏小窗专用缓存
    //
    // 这三份数据只依赖「扫出来的原始记录」，与主界面的筛选范围无关。
    // 以前是 computed 属性，SwiftUI 每次 body 求值都会重算一遍聚合（~20ms/次），
    // 小窗每次刷新都要付这个成本；现在改为扫描完成时在后台线程预聚合一次并缓存。

    /// 固定统计「当天」
    @Published private(set) var todayData: DashboardData?
    /// 近 7 天（「较昨日」对比 + 迷你走势图）
    @Published private(set) var weekData: DashboardData?
    /// 近 30 天总量（小窗环形进度分母，固定口径）
    @Published private(set) var monthlyTotal: Double = 0

    private let parser = TokenParser()
    private var refreshTimer: Timer?
    /// 订阅 AppSettings.autoRefresh：开关变化即重排 60s 轮询计时器
    private var autoRefreshCancellable: AnyCancellable?
    /// 扫描产出的原始记录（去重前），筛选切换时据此重新聚合，无需重新扫盘
    private var rawRecords: [UsageRecord] = []
    /// 本次扫描的元信息，重新聚合时复用
    private var scanMeta: (label: String, files: Int, secs: Double) = ("", 0, 0)

    private init() {
        syncRefreshTimer()
        autoRefreshCancellable = AppSettings.shared.$autoRefresh
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncRefreshTimer() }
    }

    /// 60s 轮询计时器；扫到一半或无扫描目录时本轮跳过。
    /// 开关状态统一来自 AppSettings（与设置页共用单一数据源）。
    private func syncRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard AppSettings.shared.autoRefresh else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.busy else { return }
                // 每轮顺带重新探测：新装的工具、新生成的会话目录会被自动纳入
                AppSettings.shared.refreshToolsAndScan(silent: true)
            }
        }
    }

    /// 按「应用配置」扫描所有已启用且有有效路径的 AI 工具目录
    func scanEnabledTools(silent: Bool = false) {
        let urls = AppSettings.shared.scanRoots
        roots = urls
        scan(urls, silent: silent)
    }

    /// 扫描一组根目录（合并统计到同一份 DashboardData）
    func scan(_ urls: [ScanRoot], silent: Bool = false) {
        guard !busy else { return }
        busy = true
        if !silent { status = "扫描中…" }
        let t0 = Date()
        parser.progress = { [weak self] n, _ in
            Task { @MainActor in self?.status = "扫描中… \(n) 个文件" }
        }
        // 后台线程扫描, 不卡 UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.parser.scan(roots: urls)
            let secs = Date().timeIntervalSince(t0)
            let label = urls.count == 1
                ? (urls.first?.url.lastPathComponent ?? "目录")
                : "\(urls.count) 个数据源"
            let records = self.parser.records
            let files = self.parser.filesScanned
            // 菜单栏小窗用的三份聚合在后台线程算好，避免主线程卡顿
            let rootLabel = label + "/"
            let todayAgg = Aggregator.build(records: records, root: rootLabel, files: files, secs: secs, range: .days(1))
            let weekAgg = Aggregator.build(records: records, root: rootLabel, files: files, secs: secs, range: .days(7))
            let monthAgg = Aggregator.build(records: records, root: rootLabel, files: files, secs: secs, range: .days(30))
            Task { @MainActor in
                self.rawRecords = records
                self.scanMeta = (label, files, secs)
                self.todayData = todayAgg
                self.weekData = weekAgg
                self.monthlyTotal = monthAgg.kpi.total
                self.rebuild()
                self.busy = false
                switch (silent, self.data?.kpi.calls ?? 0 > 0) {
                case (true, true):
                    self.status = "每 60s 自动刷新 · 上次 \(Fmt.time(Date()))"
                case (false, true):
                    self.status = "完成 · \(self.data?.kpi.calls ?? 0) 次调用"
                default:
                    self.status = urls.isEmpty
                        ? "未配置扫描目录，请在设置 → 应用配置中添加"
                        : "未发现 token 数据"
                }
            }
        }
    }

    /// 按当前筛选范围重新聚合（不重新扫盘）
    private func reaggregate() {
        guard !rawRecords.isEmpty else { return }
        rebuild()
    }

    /// 用已扫描的原始记录构建看板数据（按当前筛选范围）
    private func rebuild() {
        data = Aggregator.build(
            records: rawRecords,
            root: scanMeta.label + "/",
            files: scanMeta.files,
            secs: scanMeta.secs,
            range: range)
    }

    func rescan() {
        scan(roots)
    }
}

// MARK: - 主窗口看板（图1 轻量化 + Liquid Glass）

struct DashboardView: View {
    @ObservedObject var store: ScanStore
    /// 0–24 时分布图里独享展示的模型名（nil = 全部显示）
    @State private var peakSelection: String?

    var body: some View {
        ZStack {
            DarkBackdrop(opacity: 0.64)
            VStack(spacing: 0) {
                header
                filterBar
                if let d = store.data {
                    ScrollView {
                        VStack(spacing: 14) {
                            kpiRow(d)
                            trendCard(d)
                            HStack(alignment: .top, spacing: 14) {
                                modelCard(d)
                                workspaceCard(d)
                            }
                            hourlyPeakCard(d)
                            recentCard(d)
                        }
                        .padding(20)
                    }
                } else {
                    if store.busy { scanningState } else { emptyState }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 顶栏
    private var header: some View {
        HStack(spacing: 12) {
            BrandBadge(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Token 用量监控").font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.busy { ProgressView().controlSize(.small) }
            Text(store.status).font(.system(size: 11)).foregroundStyle(.secondary)
            Button {
                if store.roots.isEmpty {
                    AppDelegate.openSettings()        // 没配置目录 → 去应用配置
                } else if store.data != nil {
                    store.rescan()
                } else {
                    store.scanEnabledTools()
                }
            } label: {
                Label(store.roots.isEmpty ? "配置目录"
                      : (store.data == nil ? "开始扫描" : "重新扫描"),
                      systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(SpringPressStyle())
            .handCursor()
            .disabled(store.busy)
            // 设置入口（自动刷新等通用设置已迁移到设置页）
            Button {
                AppDelegate.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SpringPressStyle())
            .foregroundStyle(.secondary)
            .handCursor()
            .help("设置")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        guard let d = store.data else { return "在「设置 → 应用配置」中选择要扫描的 AI 工具目录" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "数据截至 \(f.string(from: d.scannedAt)) · \(d.filesScanned) 个文件 · \(String(format: "%.1f", d.scanSeconds))s"
    }

    // MARK: 筛选栏（时间范围）

    private var filterBar: some View {
        FilterBar(range: $store.range)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }

    // MARK: 空态 / 扫描中
    private var scanningState: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("正在扫描…").font(.system(size: 14, weight: .medium))
            Text(store.status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(
                    LinearGradient(colors: [Color.violetBright, Color.accentBlue],
                                   startPoint: .top, endPoint: .bottom))
                .fadeSlideIn(delay: 0)
            Text("配置要扫描的 AI 工具目录")
                .font(.system(size: 17, weight: .semibold))
                .fadeSlideIn(delay: 0.08)
            Text("在「设置 → 应用配置」中勾选 WorkBuddy、Codex、Claude Code 等工具，\n应用会自动探测并扫描它们的日志目录，统一统计 token 消耗")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fadeSlideIn(delay: 0.14)
            Button {
                AppDelegate.openSettings()
            } label: {
                Label("打开应用配置", systemImage: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .buttonStyle(SpringPressStyle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color.violetMain.opacity(0.95), Color.violetMain],
                                         startPoint: .top, endPoint: .bottom))
            )
            .foregroundStyle(.white)
            .handCursor()
            .fadeSlideIn(delay: 0.2)
            Text("全部在本机解析，数据不会上传")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fadeSlideIn(delay: 0.26)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: KPI 行
    private func kpiRow(_ d: DashboardData) -> some View {
        let k = d.kpi
        return HStack(spacing: 12) {
            kpiCard("合计 TOKEN", Fmt.cn(k.total), sub: "\(k.calls) 次调用", tint: .accentGreen).fadeSlideIn(delay: 0.02)
            kpiCard("日均消耗", Fmt.cn(k.avgPerActiveDay), sub: "\(k.activeDays) 个活跃时段", tint: .accentBlue).fadeSlideIn(delay: 0.06)
            kpiCard("会话数", "\(k.sessions)", sub: "\(k.models) 个模型", tint: .violetBright).fadeSlideIn(delay: 0.10)
            kpiCard("输入", Fmt.cn(k.input), sub: Fmt.pct(k.total > 0 ? k.input / k.total : 0), tint: .accentGreen).fadeSlideIn(delay: 0.14)
            kpiCard("输出", Fmt.cn(k.output), sub: Fmt.pct(k.total > 0 ? k.output / k.total : 0), tint: .accentBlue).fadeSlideIn(delay: 0.18)
            kpiCard("预估金额", Fmt.cost(k.estCost), sub: "综合单价估算", tint: .violetBright).fadeSlideIn(delay: 0.22)
        }
    }

    private func kpiCard(_ label: String, _ value: String, sub: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(sub).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .liquidGlass(cornerRadius: 12, tint: tint.opacity(0.08))
        .liftOnHover()
    }

    // MARK: 趋势卡（柱状图悬浮明细）
    private func trendCard(_ d: DashboardData) -> some View {
        card("每日 Token 趋势", trailing: AnyView(legend), delay: 0.26) {
            HoverableBars(buckets: d.daily, hourly: d.hourlyMode)
                .frame(height: 150)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            dot(Color.accentGreen, "输入")
            dot(Color.accentBlue, "输出")
        }
    }

    private func dot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(t).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }

    // MARK: 模型分布
    private func modelCard(_ d: DashboardData) -> some View {
        card("模型用量分布", trailing: nil, delay: 0.32) {
            VStack(spacing: 9) {
                if d.models.isEmpty {
                    Text("暂无数据").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                ForEach(Array(d.models.prefix(7).enumerated()), id: \.offset) { i, m in
                    HBarRow(name: m.name, value: m.total, pct: m.pct, detail: nil, color: modelColor(i))
                }
            }
        }
    }

    // MARK: 工作空间分布
    private func workspaceCard(_ d: DashboardData) -> some View {
        card("工作空间分布", trailing: nil, delay: 0.36) {
            VStack(spacing: 9) {
                if d.workspaces.isEmpty {
                    Text("暂无数据").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                ForEach(Array(d.workspaces.enumerated()), id: \.offset) { i, w in
                    HBarRow(
                        name: w.name, value: w.total, pct: w.pct,
                        detail: "\(Fmt.pct(w.pct)) · \(w.sessions) 个会话",
                        color: i % 2 == 0 ? Color.violetMain : Color.blueOpacity)
                }
            }
        }
    }

    // MARK: 0–24 时分布（按模型峰值）

    private func hourlyPeakCard(_ d: DashboardData) -> some View {
        card("0–24 时分布 · 按模型",
             trailing: AnyView(peakLegend(d.hourlyByModel, selection: $peakSelection)),
             delay: 0.40) {
            HourlyModelPeaks(stats: d.hourlyByModel, selection: $peakSelection)
                .frame(height: 168)
        }
    }

    /// 图例：点击某个模型 = 独享显示它（其余置灰），再点一次恢复全部
    private func peakLegend(_ stats: [HourModelStat], selection: Binding<String?>) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                let isSel = selection.wrappedValue == s.name
                let dim = selection.wrappedValue != nil && !isSel
                Button {
                    // 再次点击同一个模型 → 恢复显示全部
                    selection.wrappedValue = isSel ? nil : s.name
                } label: {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(HourlyModelPeaks.color(i, aggregate: s.isAggregate)
                                .opacity(dim ? 0.3 : 1))
                            .frame(width: 8, height: 8)
                        Text(s.name)
                            .font(.system(size: 10.5, weight: isSel ? .semibold : .regular))
                            .foregroundStyle(dim ? AnyShapeStyle(.tertiary)
                                         : (isSel ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
                .help(isSel ? "点击恢复显示全部模型" : "只看 \(s.name)")
                .accessibilityLabel("\(s.name)，\(isSel ? "已独享显示，点击恢复全部" : "点击只看这个模型")")
            }
        }
    }

    // MARK: 最近调用
    private func recentCard(_ d: DashboardData) -> some View {
        card("最近调用", trailing: AnyView(Text("共 \(d.kpi.calls) 次").font(.system(size: 10.5)).foregroundStyle(.tertiary)), delay: 0.42) {
            VStack(spacing: 0) {
                ForEach(Array(d.recent.prefix(12).enumerated()), id: \.offset) { i, r in
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text(Fmt.recordTime(r.ts))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 88, alignment: .leading)
                            Text(shortModel(r.model))
                                .font(.system(size: 10.5, design: .monospaced))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.violetBright.opacity(0.16)))
                                .lineLimit(1)
                            Spacer()
                            Text("入 \(Fmt.cn(r.input))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                            Text("出 \(Fmt.cn(r.output))").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                            Text(Fmt.cn(r.total))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                    }
                    .background(hoverIdx == i ? Color.primary.opacity(0.035) : .clear)
                    .onHover { hoverIdx = $0 ? i : nil }
                    if i < min(11, d.recent.count - 1) {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }
    @State private var hoverIdx: Int?

    private func shortModel(_ m: String) -> String { m.count > 24 ? String(m.prefix(22)) + "…" : m }

    private func card(_ title: String, trailing: AnyView?, delay: Double, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                trailing
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 14, tint: Color.violetBright.opacity(0.06))
        .fadeSlideIn(delay: delay)
    }

    private func modelColor(_ i: Int) -> Color {
        [Color.accentGreen, Color.accentBlue, Color.violetBright,
         Color.orangeAccent, Color.tealMain, Color.blueOpacity,
         Color(hue: 0.13, saturation: 0.6, brightness: 0.8)][i % 7]
    }
}
// MARK: - 柱状图（悬浮展示明细卡，未悬浮柱变暗）

struct HoverableBars: View {
    let buckets: [DayBucket]
    let hourly: Bool
    @State private var appeared = false
    @State private var hoverIdx: Int?

    private var maxV: Double { buckets.map { $0.total }.max() ?? 1 }
    private let plotHeight: CGFloat = 118

    var body: some View {
        GeometryReader { geo in
            let n = max(buckets.count, 1)
            let slot = geo.size.width / CGFloat(n)
            let barW = min(slot * (n > 30 ? 0.6 : 0.5), 30)
            ZStack(alignment: .topLeading) {
                // 柱子区
                HStack(spacing: 0) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { i, b in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            let h = appeared ? CGFloat(b.total / max(maxV, 1)) * plotHeight : 0
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(LinearGradient(colors: [Color.accentBlue, Color.violetBright],
                                                         startPoint: .top, endPoint: .bottom))
                                    .frame(height: h * CGFloat(b.output / max(b.total, 1)))
                                Rectangle()
                                    .fill(LinearGradient(colors: [Color.accentGreen, Color.tealMain],
                                                         startPoint: .top, endPoint: .bottom))
                                    .frame(height: h * CGFloat(b.input / max(b.total, 1)))
                            }
                            .frame(width: barW)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .opacity(hoverIdx == nil || hoverIdx == i ? 1 : 0.25)
                            .scaleEffect(hoverIdx == i ? 1.06 : 1, anchor: .bottom)
                            .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(appeared ? 0 : barDelay(i)), value: appeared)
                            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: hoverIdx)
                        }
                        .frame(width: slot, height: plotHeight + 12)
                        .contentShape(Rectangle())
                        // onContinuousHover: 连续追踪且只发一次 ended，
                        // 柱间移动不会像 onHover 那样产生瞬时 nil 导致闪烁
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                if hoverIdx != i { hoverIdx = i }
                            case .ended:
                                if hoverIdx == i { hoverIdx = nil }
                            }
                        }
                    }
                }
                .frame(height: plotHeight + 12, alignment: .bottom)
                // x 轴标签: 每个标签居中对齐到对应柱的中心
                // （首尾钳制在绘图区内，防止半个标签溢出卡片）
                ForEach(axisLabels(n: n), id: \.0) { item in
                    let w = min(slot * CGFloat(item.2), 120)
                    Text(item.1)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: w)
                        .position(x: min(max(slot * (CGFloat(item.0) + 0.5), w / 2),
                                         geo.size.width - w / 2),
                                  y: plotHeight + 19)
                }
                // 悬浮明细卡
                if let idx = hoverIdx, idx < buckets.count, appeared {
                    tooltip(buckets[idx])
                        .position(x: tooltipX(idx, slot: slot, width: geo.size.width),
                                  y: tooltipY(buckets[idx]))
                        // 关键: 明细卡不参与鼠标命中，否则卡片盖住指针时
                        // 会触发"柱子失去 hover → 卡片消失 → hover 恢复"的死循环频闪
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .animation(.spring(response: 0.22, dampingFraction: 0.85), value: hoverIdx)
                }
            }
        }
        .onAppear { appeared = true }
    }

    private func axisLabels(n: Int) -> [(Int, String, Double)] {
        guard n > 0 else { return [] }
        let step = max(1, n / 8)
        return buckets.enumerated().compactMap { i, b in
            guard i % step == 0 else { return nil }
            let span = min((i / step + 1) * step, n) - i
            return (i, Fmt.bucketLabel(b.key, hourly: hourly), Double(max(span, 1)))
        }
    }

    private func barDelay(_ i: Int) -> Double {
        var h = 0.0
        for ch in buckets[i].key.unicodeScalars { h = (h * 31 + Double(ch.value)).truncatingRemainder(dividingBy: 97) }
        return (h / 97) * 0.35
    }

    private func tooltip(_ b: DayBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Fmt.bucketLabel(b.key, hourly: hourly))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            row("输入", Fmt.int(b.input), Color.tealMain)
            row("输出", Fmt.int(b.output), Color.blueOpacity)
            Divider().opacity(0.5)
            HStack {
                Text("合计").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.int(b.total)).font(.system(size: 11, weight: .bold, design: .monospaced))
            }
        }
        .padding(9)
        .frame(width: 156)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.7)
        )
    }

    private func row(_ label: String, _ v: String, _ c: Color) -> some View {
        HStack {
            Circle().fill(c).frame(width: 5, height: 5)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 10.5, design: .monospaced))
        }
    }

    private func tooltipX(_ idx: Int, slot: CGFloat, width: CGFloat) -> CGFloat {
        let cx = slot * (CGFloat(idx) + 0.5)
        let half: CGFloat = 78
        return min(max(cx, half + 2), width - half - 2)
    }

    private func tooltipY(_ b: DayBucket) -> CGFloat {
        let barTop = (plotHeight + 12) - CGFloat(b.total / max(maxV, 1)) * plotHeight
        return max(barTop - 52, 52)
    }
}

// MARK: - 横向条形（模型/工作空间分布）

struct HBarRow: View {
    let name: String
    let value: Double
    let pct: Double
    let detail: String?
    let color: Color
    @State private var appeared = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(name)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(detail ?? "\(Fmt.cn(value)) · \(Fmt.pct(pct))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.05))
                    Capsule()
                        .fill(
                            LinearGradient(colors: [color.opacity(0.7), color],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        // 宽度 = 可用宽度 × 占比（pct 是 0-1 的比例，不能直接当点宽用）
                        .frame(width: appeared ? max(geo.size.width * CGFloat(min(max(pct, 0), 1)), 2) : 0)
                        .shadow(color: color.opacity(hover ? 0.55 : 0.25), radius: hover ? 6 : 2)
                }
            }
            .frame(height: 5)
        }
        .onHover { hover = $0 }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)
                .delay(appeared ? 0 : Double(abs(name.hashValue % 30)) / 100)) {
                appeared = true
            }
        }
    }
}

// MARK: - 0–24 时分布 · 按模型峰值图

/// 0–24 时分布（按模型）
///
/// 每个模型一条折线，纵轴为该小时的 token 总量。
/// 选中的模型独享显示（其余置灰），再点一次恢复全部。
struct HourlyModelPeaks: View {
    let stats: [HourModelStat]
    @Binding var selection: String?
    @State private var appeared = false
    @State private var hoverHour: Int?

    /// 配色（与图例一致）
    static func color(_ i: Int, aggregate: Bool) -> Color {
        if aggregate { return Color.secondary.opacity(0.55) }
        return [Color.accentGreen, Color.accentBlue, Color.violetBright,
                Color.orangeAccent, Color.tealMain][i % 5]
    }

    private var maxV: Double {
        max(stats.map { $0.hours.max() ?? 0 }.max() ?? 1, 1)
    }

    var body: some View {
        GeometryReader { geo in
            let plotH = geo.size.height - 22
            ZStack(alignment: .topLeading) {
                // 网格线
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.primary.opacity(0.05))
                            .frame(height: 1)
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: plotH)

                // 折线
                ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                    let dim = selection != nil && selection != s.name
                    peakPath(s, width: geo.size.width, plotH: plotH)
                        .stroke(
                            LinearGradient(colors: [Self.color(i, aggregate: s.isAggregate).opacity(dim ? 0.25 : 0.9),
                                                   Self.color(i, aggregate: s.isAggregate).opacity(dim ? 0.15 : 0.55)],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: s.isAggregate ? 1.2 : 1.8, lineCap: .round))
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(Double(i) * 0.06), value: appeared)
                }

                // 峰值点
                ForEach(Array(stats.enumerated()), id: \.offset) { i, s in
                    let dim = selection != nil && selection != s.name
                    ForEach(Array(s.hours.enumerated()), id: \.offset) { h, v in
                        if v > 0, v >= (s.hours.max() ?? 0) * 0.995 {
                            Circle()
                                .fill(Self.color(i, aggregate: s.isAggregate))
                                .frame(width: 5, height: 5)
                                .opacity(dim ? 0.25 : 0.95)
                                .position(x: xPos(h, width: geo.size.width),
                                          y: plotH - CGFloat(v / maxV) * plotH)
                        }
                    }
                }

                // 悬浮竖线
                if let hh = hoverHour {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .position(x: xPos(hh, width: geo.size.width), y: plotH / 2)
                }

                // x 轴刻度
                HStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { h in
                        if h % 3 == 0 {
                            Text("\(h)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                        } else {
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: 16)
                .offset(y: plotH + 4)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let w = geo.size.width
                    let idx = Int(((p.x / max(w, 1)) * 24).rounded(.down))
                    hoverHour = min(max(idx, 0), 23)
                case .ended:
                    hoverHour = nil
                }
            }
        }
        .onAppear { appeared = true }
    }

    private func xPos(_ hour: Int, width: CGFloat) -> CGFloat {
        width * (CGFloat(hour) + 0.5) / 24
    }

    private func peakPath(_ s: HourModelStat, width: CGFloat, plotH: CGFloat) -> Path {
        var p = Path()
        for (h, v) in s.hours.enumerated() {
            let pt = CGPoint(x: xPos(h, width: width), y: plotH - CGFloat(v / maxV) * plotH)
            if h == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
