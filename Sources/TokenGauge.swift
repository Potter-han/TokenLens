import AppKit
import SwiftUI

// MARK: - Token 环形仪表图标
//
// 设计图要点：
//   · 一个白色圆盘，中心是环形进度轨道（浅灰底环）+ 从 12 点方向顺时针填充的彩色弧
//   · 圆心显示已消耗的 Token 数（12.4K 这种紧凑写法），下方小字 "TOKEN"
//   · 颜色随「今日额度使用比例」变化，直观识别状态：
//       空闲(灰) → 低使用(蓝) → 中等使用(浅蓝) → 较高使用(青) → 接近上限(橙) → 已超警戒(红)
//   · 菜单栏只显示一个图标（不显示文字标题），所以中心数字要够小仍可辨认；
//     菜单栏空间有限，数字用「万/千」紧凑单位。

// MARK: - 状态档位

/// 额度使用比例对应的状态档位
enum GaugeLevel: Int, Comparable {
    case idle = 0        // 空闲：灰
    case low = 1         // 低使用：蓝
    case moderate = 2    // 中等使用：浅蓝
    case high = 3        // 较高使用：青
    case warning = 4     // 接近上限：橙
    case danger = 5      // 已超警戒：红

    static func < (a: GaugeLevel, b: GaugeLevel) -> Bool { a.rawValue < b.rawValue }

    /// 按使用比例（0…1+）判定档位
    /// 阈值对齐设计图示例：0% 空闲 / 25% 低 / 50% 中等 / 75% 较高 / 90% 接近上限 / 98% 超警戒
    static func level(for ratio: Double) -> GaugeLevel {
        switch ratio {
        case ..<0.01:   return .idle
        case ..<0.35:   return .low
        case ..<0.60:   return .moderate
        case ..<0.82:   return .high
        case ..<0.95:   return .warning
        default:         return .danger
        }
    }

    /// 弧线颜色（用 NSColor 存储：AppKit 绘制与 SwiftUI 视图共用同一份值）
    var nsColor: NSColor {
        switch self {
        case .idle:     return NSColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 1)   // 冷灰
        case .low:      return NSColor(srgbRed: 0.13, green: 0.55, blue: 0.98, alpha: 1)   // 蓝
        case .moderate: return NSColor(srgbRed: 0.30, green: 0.70, blue: 1.00, alpha: 1)   // 浅蓝
        case .high:     return NSColor(srgbRed: 0.13, green: 0.80, blue: 0.84, alpha: 1)   // 青
        case .warning:  return NSColor(srgbRed: 1.00, green: 0.62, blue: 0.14, alpha: 1)   // 橙
        case .danger:   return NSColor(srgbRed: 1.00, green: 0.30, blue: 0.22, alpha: 1)   // 红
        }
    }

    /// 弧线颜色（SwiftUI 视图用）
    var color: Color { Color(nsColor: nsColor) }

    /// 弧线渐变（设计图：从 12 点方向的深色渐变到浅色）
    ///
    /// 实测设计图大图标环上配色：
    ///   0°(顶) 深蓝 → 90° 最深 → 240° 浅蓝 → 回到起点
    /// 状态色决定渐变的「色相」，深浅由 level 决定：
    ///   蓝/青档用同色系深→浅；橙/红档也用同色系深→浅。
    func gradientColors(for ratio: Double) -> [Color] {
        // 进度越大颜色越饱和：空闲灰 → 低蓝 → … → 超警戒红
        let deep = nsColor
        let light = nsColor.mixed(withFraction: 0.42, of: .white)
        return [Color(nsColor: light), Color(nsColor: deep), Color(nsColor: deep)]
    }

    /// 档位说明（tooltip 用）
    var label: String {
        switch self {
        case .idle:     return "空闲"
        case .low:      return "低使用"
        case .moderate: return "中等使用"
        case .high:     return "较高使用"
        case .warning:  return "接近上限"
        case .danger:   return "已超警戒"
        }
    }
}

extension NSColor {
    /// 与另一颜色按比例混合（0 = 全自身，1 = 全另一色）
    ///
    /// 命名避开 NSColor 自带的 blended(withFraction:of:)（那是颜色空间混合，语义不同）
    func mixed(withFraction f: CGFloat, of other: NSColor) -> NSColor {
        let t = max(0, min(1, f))
        // 用 sRGB 空间取值：泛型灰（NSColor.white）取 redComponent 会抛异常
        let s = usingColorSpace(.sRGB) ?? self
        let o = other.usingColorSpace(.sRGB) ?? other
        let r = s.redComponent + (o.redComponent - s.redComponent) * t
        let g = s.greenComponent + (o.greenComponent - s.greenComponent) * t
        let b = s.blueComponent + (o.blueComponent - s.blueComponent) * t
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - 数值格式化

enum TokenFormat {
    /// 紧凑写法：1234 → 1.2K，12345 → 12.3K，1234567 → 1.2M
    ///
    /// 保留一位小数（设计图示例：2.1K / 6.5K / 12.4K / 17.8K / 19.6K）。
    /// 只有当整数部分本身就很长时才省略小数，避免菜单栏里塞不下。
    static func compact(_ v: Double) -> String {
        let n = max(v, 0)
        if n < 1000 { return "\(Int(n))" }
        if n < 1_000_000 {
            let k = n / 1000
            // 100K 以上整数部分已有 3 位，再加小数会太宽
            return k < 100 ? String(format: "%.1fK", k) : "\(Int(k.rounded()))K"
        }
        let m = n / 1_000_000
        return m < 100 ? String(format: "%.1fM", m) : "\(Int(m.rounded()))M"
    }
}

// MARK: - 环形仪表视图

/// 白色圆盘 + 环形进度 + 中心数字（设计图的图标主体）
struct TokenGaugeView: View {
    /// 已消耗 Token
    var tokens: Double
    /// 使用比例（0…1，超出按 1 计）
    var ratio: Double
    /// 圆盘直径
    var diameter: CGFloat
    /// 是否显示 "TOKEN" 小字（App 图标显示，菜单栏不显示）
    var showsCaption: Bool
    /// 环线宽
    var lineWidth: CGFloat
    /// 中心数字字号（nil = 自适应）
    var fontSize: CGFloat?

    private let level: GaugeLevel

    init(tokens: Double, ratio: Double, diameter: CGFloat,
         showsCaption: Bool, lineWidth: CGFloat, fontSize: CGFloat? = nil) {
        self.tokens = tokens
        self.ratio = ratio
        self.diameter = diameter
        self.showsCaption = showsCaption
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.level = GaugeLevel.level(for: ratio)
    }

    var body: some View {
        ZStack {
            // 白色圆盘
            Circle()
                .fill(Color.white)
            // 灰色底环
            Circle()
                .stroke(Color(red: 0.89, green: 0.90, blue: 0.93),
                        lineWidth: lineWidth)
            // 彩色进度弧：从 12 点顺时针（渐变：顶部深 → 底部浅）
            Circle()
                .trim(from: 0, to: min(max(ratio, 0), 1))
                .stroke(AngularGradient(gradient: Gradient(colors: level.gradientColors(for: ratio)),
                                        center: .center,
                                        startAngle: .degrees(90),
                                        endAngle: .degrees(450)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // 中心内容
            VStack(spacing: diameter * 0.02) {
                Text(TokenFormat.compact(tokens))
                    .font(.system(size: fontSize ?? diameter * 0.30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.10, green: 0.12, blue: 0.16))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if showsCaption {
                    Text("TOKEN")
                        .font(.system(size: diameter * 0.10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.42, green: 0.45, blue: 0.52))
                }
            }
            .padding(.horizontal, diameter * 0.16)
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - 渐变弧绘制（AppKit）

enum GaugeRenderer {
    /// 绘制环形进度弧：从 12 点方向顺时针，颜色沿弧线渐变
    ///
    /// AppKit 没有 SwiftUI 的 AngularGradient，这里逐段插值描边实现同样的观感。
    /// - Parameters:
    ///   - ratio: 0…1 的进度
    ///   - level: 状态档位（决定色相）
    ///   - gradient: 是否使用渐变（App 图标用渐变，菜单栏小图标用纯色以保证小尺寸下清晰）
    static func drawProgressArc(center: NSPoint, radius: CGFloat,
                                lineWidth: CGFloat, ratio: Double, level: GaugeLevel,
                                gradient: Bool) {
        let clamped = min(max(ratio, 0), 1)
        guard clamped > 0.001 else { return }
        let sweep = 360 * clamped

        if !gradient {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius,
                           startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            level.nsColor.setStroke()
            path.stroke()
            return
        }

        // 渐变弧：起点（12 点）最深，向末端渐浅（设计图实测：
        // 0°≈(94,185,248) → 90° 最深(44,113,247) → 240° 最浅(153,193,242)）
        let steps = max(Int(sweep / 3), 8)
        for i in 0..<steps {
            let t0 = Double(i) / Double(steps)
            let t1 = Double(i + 1) / Double(steps)
            // a0 > a1：clockwise:true 表示角度递减，所以从 a0 画到 a1（3° 小段）
            // ⚠️ 若写反成 startAngle: a1 → endAngle: a0，每段会逆时针绕整圈，
            //    最后一段把前面的渐变全部盖掉（曾导致渐变失效变成纯色）
            let a0 = 90 - sweep * t0
            let a1 = 90 - sweep * t1
            // 中段最深、两端较浅：用正弦包络逼近设计图的渐变观感
            let f = sin(Double.pi * (t0 + 0.5 / Double(steps)))
            let c = level.nsColor.mixed(withFraction: f * 0.55, of: .white)
            let seg = NSBezierPath()
            seg.appendArc(withCenter: center, radius: radius,
                          startAngle: a0, endAngle: a1, clockwise: true)
            seg.lineWidth = lineWidth
            seg.lineCapStyle = (i == 0 || i == steps - 1) ? .round : .butt
            c.setStroke()
            seg.stroke()
        }
    }
}

// MARK: - 菜单栏图标（AppKit 绘制，供 NSStatusItem 使用）

enum MenuBarGaugeIcon {
    /// 菜单栏图标：白色圆盘 + 环形进度 + 中心紧凑数字
    ///
    /// 菜单栏可用高度约 18pt，白色圆盘能保证在深色菜单栏上清晰可见，
    /// 数字用紧凑单位（1.2K / 12K）以在这么小的尺寸下仍可辨认。
    static func image(tokens: Double, ratio: Double, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let level = GaugeLevel.level(for: ratio)
            let d = size
            let lineWidth = max(d * 0.115, 1.6)
            let center = NSPoint(x: d / 2, y: d / 2)
            let radius = (d - lineWidth) / 2

            // 白色圆盘
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()

            // 灰色底环
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius,
                            startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor(srgbRed: 0.89, green: 0.90, blue: 0.93, alpha: 1).setStroke()
            track.stroke()

            // 彩色进度弧：12 点方向起，顺时针
            // 菜单栏尺寸小，用纯色而非渐变，保证小尺寸下颜色辨识度更高
            GaugeRenderer.drawProgressArc(center: center, radius: radius,
                                          lineWidth: lineWidth, ratio: ratio,
                                          level: level, gradient: false)

            // 中心数字
            let text = TokenFormat.compact(tokens) as NSString
            let font = NSFont.systemFont(ofSize: d * 0.34, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1)
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (d - size.width) / 2,
                                  y: (d - size.height) / 2),
                      withAttributes: attrs)
            return true
        }
        img.isTemplate = false   // 保留配色（模板图会被系统单色化，丢掉状态色）
        return img
    }
}
