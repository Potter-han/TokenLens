import SwiftUI
import AppKit

// MARK: - 主题色

extension Color {
    static let blueOpacity = Color(hue: 0.58, saturation: 0.55, brightness: 0.62)
    static let tealMain = Color(hue: 0.44, saturation: 0.62, brightness: 0.52)
    static let violetMain = Color(hue: 0.72, saturation: 0.5, brightness: 0.72)
    /// 设置页药丸开关「开」态的高亮橙（呼应设计图）
    static let orangeAccent = Color(hue: 0.09, saturation: 0.95, brightness: 1.0)

    // MARK: 白色毛玻璃主题（菜单栏小窗 / 主窗口 / 设置页）
    // 强调色在白底上需要更饱和才能看清；accentGreen / accentRed 兼作涨跌语义色
    /// 亮紫（高亮强调，#8268F5）
    static let violetBright = Color(red: 0.51, green: 0.42, blue: 0.96)
    /// 荧光绿（正向增量 / 绿色卡片）—— 白底上压深一点保证对比度
    static let accentGreen = Color(red: 0.05, green: 0.66, blue: 0.44)
    /// 警示红（负向增量）
    static let accentRed = Color(red: 0.90, green: 0.28, blue: 0.24)
    /// 亮蓝（模型卡片 / 图表渐变）
    static let accentBlue = Color(red: 0.20, green: 0.48, blue: 0.96)
}

// MARK: - Liquid Glass 视觉体系（材质模糊 + 高光描边 + 彩色光斑折射）

/// 彩色光斑背景：玻璃材质需要背景有色彩才能折射出通透质感，光斑缓慢漂移
struct GlowBackground: View {
    @State private var drift = false
    var body: some View {
        GeometryReader { geo in
            // 光斑按容器宽度缩放（基准 392pt = 菜单栏小窗宽度）：
            // 小窗里是一圈柔光，主窗口里则是更大范围的环境光晕
            let s = max(geo.size.width / 392.0, 0.8)
            ZStack {
                Circle()
                    .fill(Color.tealMain.opacity(0.10))
                    .frame(width: 360 * s, height: 360 * s)
                    .blur(radius: 95 * s)
                    .position(x: geo.size.width * 0.85, y: drift ? geo.size.height * 0.10 : geo.size.height * 0.17)
                Circle()
                    .fill(Color.violetMain.opacity(0.08))
                    .frame(width: 320 * s, height: 320 * s)
                    .blur(radius: 105 * s)
                    .position(x: geo.size.width * 0.10, y: drift ? geo.size.height * 0.60 : geo.size.height * 0.50)
                Circle()
                    .fill(Color.blueOpacity.opacity(0.08))
                    .frame(width: 400 * s, height: 400 * s)
                    .blur(radius: 115 * s)
                    .position(x: geo.size.width * 0.52, y: drift ? geo.size.height * 0.88 : geo.size.height * 0.96)
            }
            .animation(.easeInOut(duration: 9).repeatForever(autoreverses: true), value: drift)
        }
        .ignoresSafeArea()
        .onAppear { drift = true }
    }
}

/// 白色毛玻璃底：菜单栏小窗 / 主窗口 / 设置页共用
///
/// 层次（自下而上）：
///   ① `.ultraThinMaterial` —— 桌面透出的磨砂，保证「高透明度」
///   ② 白色薄纱 —— 给玻璃一个白色基底，同时把桌面压暗的部分提亮，文字更易读
///   ③ 彩色光斑 —— 折射出彩色边缘
///
/// ⚠️ 透明度关键在第 ② 层的不透明度：
///   白纱是**不透明色**，它盖在材质之上，材质透出的桌面只剩 (1 - opacity) 份。
///   白色主题的好处是白纱本身就能提亮透进来的画面，文字用深色即可保证对比度，
///   所以 opacity 可以比深色主题更低仍有很好的可读性。
///   实测（弹窗浮在各色窗口上）：
///     opacity 0.50 → 桌面明显透出，深色文字对比度依然充足
struct LightBackdrop: View {
    /// 白纱不透明度：越小越透（能看见桌面），越大越实（长表格更易读）
    /// - 小窗 0.42：面板小，透出桌面最能体现毛玻璃感
    /// - 主窗口 / 设置页 0.58~0.64：内容密集，需要更实的底色保证文字可读
    var opacity: Double = 0.42

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.white.opacity(opacity),
                         Color.white.opacity(opacity * 0.82)],
                startPoint: .top, endPoint: .bottom)
            GlowBackground()
        }
        .ignoresSafeArea()
    }
}

/// 兼容别名：旧代码里的 DarkBackdrop 已全部迁移到 LightBackdrop
@available(*, deprecated, renamed: "LightBackdrop")
typealias DarkBackdrop = LightBackdrop

/// 玻璃面板：模糊材质 + 顶部高光渐变 + 斜向描边 + 柔和投影
extension View {
    func glassPanel(cornerRadius: CGFloat = 14, shadow: Bool = true) -> some View {
        self
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.30), Color.white.opacity(0.02), Color.white.opacity(0.10)],
                                startPoint: .top, endPoint: .bottom)
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.70), Color.white.opacity(0.10), Color.white.opacity(0.32)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(shadow ? 0.07 : 0), radius: 12, x: 0, y: 5)
    }
}

// MARK: - Liquid Glass（macOS 26 真·玻璃）

/// 玻璃容器：把相邻的玻璃元素放进同一个容器，边缘才能互相融合
@available(macOS 26.0, *)
struct GlassContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) { content }
    }
}

extension View {
    /// 真·Liquid Glass 卡片（macOS 26+ 调用系统 glassEffect，折射背景并产生高光边缘）；
    /// 旧系统降级为深色玻璃面板（半透明白 + 描边）。
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat, tint: Color = .clear) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                Glass.regular.tint(tint),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self.glassPanelDark(cornerRadius: cornerRadius)
        }
    }

    /// 深色玻璃面板（旧系统降级用；系统玻璃不可用时的视觉兜底）
    func glassPanelDark(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            )
    }
}

/// 手指光标
private struct HandCursorModifier: ViewModifier {
    @State private var inside = false
    func body(content: Content) -> some View {
        content.onHover { h in
            inside = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
extension View {
    func handCursor() -> some View { modifier(HandCursorModifier()) }
}

/// 按压弹性
struct SpringPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            // 整个 label 区域均可点击（含背景填充与 padding 空白）
            .contentShape(Rectangle())
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// 呼吸状态点
struct PulseDot: View {
    var color: Color = .tealMain
    var busy = false
    @State private var on = false
    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 12, height: 12)
                .scaleEffect(on ? 1.6 : 0.7)
                .opacity(on ? 0 : 0.9)
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: busy ? 0.8 : 1.5).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

/// 卡片悬浮上浮
private struct LiftOnHover: ViewModifier {
    @State private var hover = false
    var scale: CGFloat
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? scale : 1)
            .shadow(color: .black.opacity(hover ? 0.12 : 0.06), radius: hover ? 16 : 9, x: 0, y: hover ? 8 : 4)
            .onHover { h in hover = h }
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: hover)
    }
}
extension View {
    func liftOnHover(scale: CGFloat = 1.012) -> some View { modifier(LiftOnHover(scale: scale)) }
}

/// 入场级联出现
struct FadeSlideIn: ViewModifier {
    @State private var shown = false
    var delay: Double
    var distance: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : distance)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(delay)) { shown = true }
            }
    }
}
extension View {
    func fadeSlideIn(delay: Double, distance: CGFloat = 14) -> some View {
        modifier(FadeSlideIn(delay: delay, distance: distance))
    }
}
