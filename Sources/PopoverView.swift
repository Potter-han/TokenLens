import SwiftUI
import AppKit

// MARK: - 菜单栏小窗（按设计图重做：深色 Liquid Glass + 本机真实数据）
//
// 版块与设计图一一对应：
//   ① 顶栏      T 徽标 + TokenLens / AI 使用监控助手 + ● 监控中 + 设置
//   ② 今日消耗  大数字（亿/万 用紫色强调）+ 环形进度（今日占近 30 天的比例）
//   ③ 双统计卡  调用次数 / 预估费用，含「较昨日」与近 7 天迷你走势图
//   ④ 分时柱图  tokens / 费用 可切换，带网格刻度与「现在」标记
//   ⑤ 模型分布  Top3 + 其他模型
//   ⑥ 底部      刷新时间 / 历史统计 / 打开主窗口 / 退出
//
// 视觉：macOS 26 起调用系统真·Liquid Glass（glassEffect，折射背景 + 高光边缘），
// 旧系统降级为深色玻璃面板。弹窗在 AppDelegate 里强制深色外观（darkAqua），
// 保证任何系统主题下都长成设计图的样子；底色半透，能看见桌面（更高透明度）。
//
// 数据：全部来自 ScanStore 缓存的三份聚合（当天 / 近 7 天 / 近 30 天），
// 随主界面筛选变化的是主窗口，小窗恒定展示当天口径。

struct PopoverView: View {
    @ObservedObject var store: ScanStore

    /// 分时柱状图口径：tokens / 费用
    @State private var chartMode: ChartMode = .tokens
    /// 入场动画进度（0 → 1）：驱动柱子高度、环形进度、迷你走势图、进度条
    @State private var grow: CGFloat = 0

    enum ChartMode: String, CaseIterable, Identifiable {
        case tokens, cost
        var id: String { rawValue }
        var title: String { self == .tokens ? "tokens" : "费用" }
    }

    /// 「较昨日」的比较结果
    struct Delta {
        var text: String
        var color: Color
    }

    /// 模型分布条目
    struct ModelItem {
        var name: String
        var pct: Double
    }

    // MARK: 尺寸

    private let panelWidth: CGFloat = 360
    private let plotHeight: CGFloat = 70
    /// Y 轴刻度栏宽度（X 轴要留同样的空位才能对齐）
    private let gutter: CGFloat = 24

    // MARK: 数据源

    /// 今日（固定当天，与主界面筛选范围无关）
    private var today: DashboardData? { store.todayData }
    /// 近 7 天（「较昨日」对比 + 迷你走势图）
    private var week: DashboardData? { store.weekData }

    var body: some View {
        ZStack {
            backdrop
            if #available(macOS 26.0, *) {
                GlassContainer(spacing: 14) { content }
            } else {
                content
            }
        }
        .frame(width: panelWidth)
        .onAppear { animateIn() }
        .onChange(of: store.todayData?.scannedAt) { _, _ in animateIn() }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let d = today {
                heroCard(d)
                statRow(d)
                hairline
                chartCard(d)
                modelSection(d)
                footer(d)
            } else if store.busy {
                scanningTip
            } else {
                emptyTip
            }
            // 底部操作行始终可见：扫描未完成 / 无数据时也要能打开主窗口与退出
            bottomActions
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: 背景（桌面透出的磨砂 + 深夜蓝调色 + 彩色光斑，与主窗口共用）

    private var backdrop: some View {
        DarkBackdrop()
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 1)
            .padding(.top, 12)
    }

    // MARK: ① 顶栏

    private var header: some View {
        HStack(spacing: 9) {
            BrandBadge(size: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text("TokenLens").font(.system(size: 13, weight: .bold)).foregroundStyle(.primary)
                Text("AI 使用监控助手").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                PulseDot(color: today != nil ? .accentGreen : Color.secondary, busy: store.busy)
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.25), value: statusText)
            }
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1, height: 15)
            Button {
                AppDelegate.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("设置")
        }
        .padding(.bottom, 12)
    }

    private var statusText: String {
        store.busy ? "扫描中" : (today != nil ? "监控中" : "待扫描")
    }

    // MARK: ② 今日消耗（大数字 + 环形进度）

    private func heroCard(_ d: DashboardData) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今日消耗")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                heroNumber(d.today.total)
                Text("\(d.today.calls) 次调用 · 截至 \(Fmt.time(d.scannedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            progressRing(d)
        }
        .padding(13)
        .liquidGlass(cornerRadius: 18, tint: Color.violetBright.opacity(0.10))
    }

    /// 大数字：数值白色，单位（亿/万）用紫蓝渐变强调
    private func heroNumber(_ total: Double) -> some View {
        let parts = splitCN(total)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.number)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            if !parts.unit.isEmpty {
                Text(parts.unit)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [Color.violetBright, Color.accentBlue],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Text("tokens")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    /// 环形进度：今日消耗占近 30 天的比例（颜色随状态档位变化，与菜单栏图标一致）
    private func progressRing(_ d: DashboardData) -> some View {
        let base = max(store.monthlyTotal, 1)
        let ratio = min(max(d.today.total / base, 0), 1)
        let level = GaugeLevel.level(for: ratio)
        return ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 5.5)
            Circle()
                .trim(from: 0, to: ratio * Double(grow))
                .stroke(level.color,
                        style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text(level.label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
    }

    // MARK: ③ 双统计卡（调用次数 / 预估费用）

    private func statRow(_ d: DashboardData) -> some View {
        HStack(spacing: 10) {
            statCard(icon: "waveform.path.ecg",
                     tint: .accentGreen,
                     label: "调用次数",
                     value: "\(d.today.calls) 次",
                     delta: delta(today: Double(d.today.calls), yesterday: Double(yesterday?.calls ?? 0)),
                     spark: last7 { Double($0.calls) },
                     sparkColor: .accentGreen)
            statCard(icon: "banknote.fill",
                     tint: .violetBright,
                     label: "预估费用",
                     value: Fmt.cost(d.today.cost),
                     delta: delta(today: d.today.cost, yesterday: yesterday?.cost ?? 0),
                     spark: last7 { $0.cost },
                     sparkColor: .violetBright)
        }
        .padding(.top, 10)
    }

    private func statCard(icon: String, tint: Color, label: String, value: String,
                          delta: Delta, spark: [Double], sparkColor: Color) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Text(delta.text)
                    .font(.system(size: 8.5))
                    .foregroundStyle(delta.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            sparkline(spark, color: sparkColor)
                .frame(width: 46, height: 30)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 14, tint: tint.opacity(0.08))
    }

    /// 近 7 天迷你走势图（面积 + 折线）
    private func sparkline(_ values: [Double], color: Color) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = max(values.max() ?? 0, 1)
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: values.count > 1 ? w * CGFloat(i) / CGFloat(values.count - 1) : w / 2,
                        y: h - (h - 2) * CGFloat(v / maxV) * grow)
            }
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: h))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: h))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    // MARK: ④ 今日分布 · 按小时

    private func chartCard(_ d: DashboardData) -> some View {
        let values = chartMode == .tokens ? d.hourlyTokens : d.hourlyCost
        let maxV = max(values.max() ?? 0, 0.0001)
        let top = niceCeil(maxV)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("今日分布 · 按小时")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                modeSwitch
            }
            HStack(alignment: .top, spacing: 4) {
                yAxis(top: top, isCost: chartMode == .cost)
                    .frame(width: gutter)
                barPlot(values: values, maxV: maxV)
            }
            .frame(height: plotHeight)
            HStack(spacing: 4) {
                Color.clear.frame(width: gutter)
                xAxis
            }
            .frame(height: 11)
        }
        .padding(12)
        .liquidGlass(cornerRadius: 16, tint: Color.violetBright.opacity(0.06))
    }

    /// tokens / 费用 切换
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(ChartMode.allCases) { m in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { chartMode = m }
                } label: {
                    Text(m.title)
                        .font(.system(size: 9.5, weight: chartMode == m ? .semibold : .regular))
                        .foregroundStyle(chartMode == m ? .white : Color.white.opacity(0.45))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(chartMode == m ? Color.violetMain : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .handCursor()
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.12)))
    }

    /// Y 轴刻度（0 / 1/4 / 1/2 / 3/4 / 满量程）
    private func yAxis(top: Double, isCost: Bool) -> some View {
        GeometryReader { geo in
            let h = geo.size.height
            let topInset: CGFloat = 10
            let plotH = max(h - topInset, 1)
            ZStack(alignment: .topLeading) {
                ForEach(0...4, id: \.self) { i in
                    let v = top * (1 - Double(i) / 4)
                    Text(i == 4 ? "0" : (isCost ? Fmt.cost(v) : axisCompact(v)))
                        .font(.system(size: 7.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: geo.size.width, height: 9)
                        .position(x: geo.size.width / 2, y: topInset + plotH * CGFloat(i) / 4)
                }
            }
        }
    }

    /// 24 根分时柱 + 网格 + 「现在」标记
    private func barPlot(values: [Double], maxV: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let topInset: CGFloat = 10
            let plotH = max(h - topInset, 1)
            let slot = w / 24
            let barW = min(slot * 0.56, 11)
            let nowHour = Calendar.current.component(.hour, from: Date())
            ZStack(alignment: .topLeading) {
                // 网格线
                ForEach(0...4, id: \.self) { i in
                    Path { p in
                        let y = topInset + plotH * CGFloat(i) / 4
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                // 柱子
                ForEach(0..<24, id: \.self) { hour in
                    let v = values[hour]
                    if v > 0 {
                        let bh = max(CGFloat(v / maxV) * plotH * grow, 1.5)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(LinearGradient(colors: [Color.violetBright, Color.accentBlue],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: barW, height: bh)
                            .position(x: slot * (CGFloat(hour) + 0.5), y: topInset + plotH - bh / 2)
                    }
                }
                // 「现在」竖线
                Path { p in
                    let x = slot * (CGFloat(nowHour) + 0.5)
                    p.move(to: CGPoint(x: x, y: topInset - 2))
                    p.addLine(to: CGPoint(x: x, y: topInset + plotH))
                }
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                Text("现在")
                    .font(.system(size: 7.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: min(max(slot * (CGFloat(nowHour) + 0.5) + 16, 16), w - 14), y: 4)
            }
        }
    }

    /// X 轴刻度：00:00 / 04:00 / … / 24:00
    private var xAxis: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ForEach(0...6, id: \.self) { k in
                Text(String(format: "%02d:00", k * 4))
                    .font(.system(size: 7.5, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34)
                    .position(x: min(max(w * CGFloat(k) / 6, 16), w - 16), y: 5)
            }
        }
    }

    // MARK: ⑤ 模型使用分布

    private func modelSection(_ d: DashboardData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("模型使用分布")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    AppDelegate.openMainWindow()
                } label: {
                    HStack(spacing: 2) {
                        Text("查看详情").font(.system(size: 9.5))
                        Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .handCursor()
                .help("在主窗口查看完整模型明细")
            }
            HStack(spacing: 7) {
                ForEach(Array(modelItems(d).enumerated()), id: \.offset) { i, item in
                    modelCard(item, index: i)
                }
            }
        }
        .padding(.top, 13)
    }

    private func modelCard(_ item: ModelItem, index: Int) -> some View {
        let tints = [Color.accentGreen, Color.accentBlue, Color.accentBlue, Color.violetBright]
        let icons = ["brain.head.profile", "sparkles", "cube.transparent", "circle.grid.2x2.fill"]
        let tint = tints[index % tints.count]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ZStack {
                    Circle().fill(tint.opacity(0.22))
                    Image(systemName: icons[index % icons.count])
                        .font(.system(size: 8))
                        .foregroundStyle(tint)
                }
                .frame(width: 16, height: 16)
                Text(item.name)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 1)
                Text("\(Int((item.pct * 100).rounded()))%")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(min(max(item.pct, 0), 1)) * grow)
                }
            }
            .frame(height: 3)
        }
        .padding(7)
        .frame(maxWidth: .infinity)
        .liquidGlass(cornerRadius: 12, tint: tint.opacity(0.10))
    }

    /// Top3 + 其余合并成「其他模型」
    private func modelItems(_ d: DashboardData) -> [ModelItem] {
        var items = d.models.prefix(3).map { ModelItem(name: shortModel($0.name), pct: $0.pct) }
        let rest = Array(d.models.dropFirst(3))
        if !rest.isEmpty {
            let pct = rest.reduce(0) { $0 + $1.pct }
            items.append(ModelItem(name: rest.count > 1 ? "其他 \(rest.count) 个" : "其他模型", pct: pct))
        }
        return items
    }

    // MARK: ⑥ 底部

    private func footer(_ d: DashboardData) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(.tertiary)
            Text("刷新于 \(Fmt.time(d.scannedAt))")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Button {
                store.rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, height: 15)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("立即刷新")
            Spacer(minLength: 0)
            Button {
                AppDelegate.openMainWindow()
            } label: {
                HStack(spacing: 2) {
                    Text("历史统计").font(.system(size: 9.5))
                    Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("打开主窗口查看历史统计")
        }
        .padding(.top, 13)
    }

    /// 打开主窗口并收起本弹窗（主窗口由 AppDelegate 全权管理）
    ///
    /// 注意：这里不能用 `NSApp.delegate as? AppDelegate`。
    /// @NSApplicationDelegateAdaptor 挂到 NSApp.delegate 上的是 SwiftUI 的内部代理对象，
    /// 强转结果恒为 nil，按钮会变成"点了没反应"的空按钮。
    /// 统一通过 AppDelegate.current（自登记实例）访问。
    @MainActor
    private func openMainWindow() {
        AppDelegate.openMainWindow()
    }

    // 底部: 打开主窗口 + 退出（一行排列）
    private var bottomActions: some View {
        HStack(spacing: 8) {
            // 注意: 背景放在 ButtonStyle 内部（label 之下），
            // 否则点击背景区域会穿透，只有文字可点击
            Button {
                openMainWindow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 12))
                    Text("打开主窗口")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color.violetMain.opacity(0.95), Color.violetMain],
                                             startPoint: .top, endPoint: .bottom))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SpringPressStyle())
            .foregroundStyle(.white)
            .handCursor()
            .shadow(color: Color.black.opacity(0.3), radius: 6, y: 3)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 40)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.18))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(SpringPressStyle())
            .foregroundStyle(.secondary)
            .handCursor()
            .help("退出 TokenLens")
        }
        .padding(.top, 12)
    }

    // MARK: 空状态

    private var scanningTip: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在扫描…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary)
                Text(store.status).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 28)
    }

    private var emptyTip: some View {
        VStack(spacing: 6) {
            Text("尚未扫描").font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
            Text("打开主面板，在「设置 → 应用配置」中配置要扫描的 AI 工具目录")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: 数据辅助

    /// 把 1.57亿 / 1763.0万 拆成 (数字部分, 单位部分)，便于分别上色
    private func splitCN(_ v: Double) -> (number: String, unit: String) {
        let s = Fmt.cn(v)
        for u in ["亿", "万"] where s.hasSuffix(u) {
            return (String(s.dropLast()), u)
        }
        return (s, "")
    }

    /// 昨天的聚合桶（「较昨日」对比用）
    private var yesterday: DayBucket? {
        guard let w = week else { return nil }
        let key = dayKey(offsetDays: -1)
        return w.byDay.first { $0.key == key }
    }

    /// 近 7 天（含今天）的序列，缺失的天补 0；顺序为「最旧 → 今天」
    private func last7(_ pick: (DayBucket) -> Double) -> [Double] {
        guard let w = week else { return [] }
        var map: [String: DayBucket] = [:]
        for b in w.byDay { map[b.key] = b }
        return (0..<7).reversed().map { i in
            map[dayKey(offsetDays: -i)].map(pick) ?? 0
        }
    }

    /// 相对昨天的变化率
    private func delta(today: Double, yesterday: Double) -> Delta {
        guard yesterday > 0 else {
            return Delta(text: "较昨日 —", color: Color.secondary)
        }
        let ratio = (today - yesterday) / yesterday
        let up = ratio >= 0
        let arrow = up ? "↗" : "↘"
        return Delta(text: "较昨日 \(arrow) \(String(format: "%.1f", abs(ratio) * 100))%",
                     color: up ? .accentGreen : .accentRed)
    }

    /// 指定相对今天偏移若干天的日期键
    private func dayKey(offsetDays: Int) -> String {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: offsetDays, to: Date()) ?? Date()
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 坐标轴上界取整（1.5 / 2 / 2.5 / 3 / 4 / 5 / 6 / 8 / 10 倍）
    private func niceCeil(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let mag = pow(10, floor(log10(v)))
        let n = v / mag
        let step: Double
        switch n {
        case ..<1.5: step = 1.5
        case ..<2: step = 2
        case ..<2.5: step = 2.5
        case ..<3: step = 3
        case ..<4: step = 4
        case ..<5: step = 5
        case ..<6: step = 6
        case ..<8: step = 8
        default: step = 10
        }
        return step * mag
    }

    /// 坐标轴紧凑刻度（与设计图一致用 M/K 记法）：80000000 → 80M
    private func axisCompact(_ v: Double) -> String {
        if v >= 1e9 { return String(format: "%.1fB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0fK", v / 1e3) }
        return Fmt.trail(v, 1)
    }

    /// 模型名精简（去掉厂商前缀，过长截断）
    private func shortModel(_ m: String) -> String {
        var s = m
        for p in ["us.anthropic.", "anthropic/", "openai/", "meta-llama/", "google/", "models/", "us."] {
            if s.hasPrefix(p) {
                s = String(s.dropFirst(p.count))
                break
            }
        }
        if s.count > 12 { s = String(s.prefix(11)) + "…" }
        return s
    }

    // MARK: 动画

    private func animateIn() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { grow = 0 }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.86)) { grow = 1 }
        }
    }
}
