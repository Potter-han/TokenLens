import SwiftUI
import AppKit

// MARK: - 应用品牌 Logo
//
// 设计稿 logo（无限符号渐变彩带 + 拖尾圆点，透明背景 PNG）由 Tools/make_logo.py
// 从用户提供的图片生成，打包进 App 的 Contents/Resources/AppLogo.png。
// 菜单栏状态栏图标（实时用量环）保持不变，这里只供 Dock 图标的同款徽标与
// 主窗口 / 小窗口顶栏的「T」品牌位复用。

/// 从 App 包读取品牌 logo（透明背景）
enum BrandLogo {
    static var nsImage: NSImage? {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

/// 品牌徽标：白色圆角方块 + 居中 logo，与 Dock 图标保持同一套视觉语言
///
/// 放在白色毛玻璃面板上时靠 1pt 描边 + 柔影保证可辨识；
/// 放在深色背景下它就是一枚正常的应用图标方块。
struct BrandBadge: View {
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1)
                )
            if let img = BrandLogo.nsImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(0.10), radius: size * 0.12, y: size * 0.04)
        .accessibilityLabel("TokenLens 标志")
    }
}
