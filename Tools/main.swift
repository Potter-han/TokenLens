import AppKit
import SwiftUI

// MARK: - TokenLens App 图标生成器
//
// 把品牌 logo（透明背景 PNG：无限符号渐变彩带 + 拖尾圆点）绘制到
// 白色圆角方块（squircle）中央，产出标准 macOS 应用图标。
//
// 用法（由 build.sh 调用）：
//   swiftc -O Sources/TokenGauge.swift Tools/main.swift -o gen_icon
//   ./gen_icon <输出目录> [logo路径]
//
// 产出：
//   <输出目录>/AppIcon.icns          —— 应用图标（供 Info.plist 引用）
//   <输出目录>/AppIcon-1024.png      —— 预览用大图

/// 编译期加载的 logo（main() 里按命令行参数或默认路径读入）
private var logoImage: NSImage?

/// 默认 logo 路径（相对仓库根目录；build.sh 在仓库根目录运行）
private let defaultLogoPath = "./Assets/AppLogo.png"

/// 读取 logo PNG（透明背景）
private func loadLogo(at path: String) -> NSImage? {
    NSImage(contentsOf: URL(fileURLWithPath: path))
}

// 设计图实测比例（以白色方块边长 side 为基准）
private let cornerRatio: CGFloat = 0.2237   // macOS squircle 圆角比例

/// 绘制图标主体（透明背景，尺寸 size）：白圆角方块 + 居中 logo
func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = size * 0.085          // macOS 图标圆角方块的留白
        let side = size - inset * 2
        let box = NSRect(x: inset, y: inset, width: side, height: side)
        let radius = side * cornerRatio

        // 白色圆角方块
        let shape = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        shape.fill()

        // 居中绘制 logo（保持原图宽高比，留 15% 内边距）
        if let logo = logoImage,
           let rep = logo.representations.first,
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            let ratio = CGFloat(rep.pixelsHigh) / CGFloat(rep.pixelsWide)
            let pad = side * 0.15
            let drawW = side - pad * 2
            let drawH = drawW * ratio
            let dx = box.midX - drawW / 2
            let dy = box.midY - drawH / 2
            logo.draw(in: NSRect(x: dx, y: dy, width: drawW, height: drawH),
                      from: .zero,
                      operation: .sourceOver,
                      fraction: 1.0)
        } else {
            // 兜底：读不到 logo 时画一个纯白方块（避免完全空白）
            NSColor.white.setFill()
            box.fill()
        }

        return true
    }
    return img
}

/// 导出 PNG
func writePNG(_ img: NSImage, size: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

// MARK: - 入口

@main
struct GenerateIconMain {
    static func main() {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./"
        let logoPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : defaultLogoPath
        logoImage = loadLogo(at: logoPath)
        if logoImage == nil {
            FileHandle.standardError.write("⚠️ 找不到 logo：\(logoPath)，将生成空白图标\n".data(using: .utf8)!)
        }

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // iconutil 需要 .iconset 目录，内含各尺寸的 PNG
        let iconset = "\(outDir)/AppIcon.iconset"
        try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

        let sizes: [(name: String, px: CGFloat, pt: CGFloat)] = [
            ("icon_16x16.png", 16, 16), ("icon_16x16@2x.png", 32, 16),
            ("icon_32x32.png", 32, 32), ("icon_32x32@2x.png", 64, 32),
            ("icon_128x128.png", 128, 128), ("icon_128x128@2x.png", 256, 128),
            ("icon_256x256.png", 256, 256), ("icon_256x256@2x.png", 512, 256),
            ("icon_512x512.png", 512, 512), ("icon_512x512@2x.png", 1024, 512),
        ]
        for s in sizes {
            writePNG(drawIcon(size: s.px), size: s.px, to: "\(iconset)/\(s.name)")
        }
        // 预览大图
        writePNG(drawIcon(size: 1024), size: 1024, to: "\(outDir)/AppIcon-1024.png")

        print("图标已生成: \(outDir)")
    }
}
