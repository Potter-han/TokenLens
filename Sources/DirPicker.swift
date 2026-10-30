import AppKit
import SwiftUI

// MARK: - 目录选择器
//
// 为什么不用 SwiftUI 的 `.fileImporter`：
//   SwiftUI 的 fileImporter 在 macOS 上没有「初始目录」参数，底层 NSOpenPanel
//   会记住该 app 上次打开的目录（偏好键 NSOSPLastRootDirectory）。
//   结果就是：先点过 WorkBuddy 的「选择目录」后，之后点任何工具的按钮，
//   面板都从 WorkBuddy 的目录开始 —— 用户看到的正是「点哪个都打开 workbuddy」。
//
// 这里改用原生 NSOpenPanel，显式指定起始目录：
//   - 起始目录 = 该工具自己的探测目录（没有则用其主目录，再没有用 home）
//   - 面板以 sheet 形式挂在设置窗口上，符合 macOS 交互习惯
//   - 选中结果直接回调给发起方，不依赖全局 @State，杜绝「写到别的工具」的错配

@MainActor
enum DirPicker {

    /// 弹出目录选择面板
    /// - Parameters:
    ///   - startDirectory: 面板起始目录；nil 表示从用户主目录开始
    ///   - onPick: 用户选中目录时的回调（cancel 不回调）
    static func pick(startDirectory: URL?, in window: NSWindow?, onPick: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目录"
        panel.message = "选择要扫描的日志 / 会话目录"
        // 起始目录：优先用指定目录；指定目录不存在则回退到其父目录
        if let start = startDirectory {
            let fm = FileManager.default
            var dir = start
            while !fm.fileExists(atPath: dir.path), dir.path != "/" {
                dir = dir.deletingLastPathComponent()
            }
            panel.directoryURL = dir
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                onPick(url)
            }
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            // 没有宿主窗口时退化为独立模态面板
            let response = panel.runModal()
            if response == .OK, let url = panel.url {
                onPick(url)
            }
        }
    }
}
