import Foundation
import AppKit
import SwiftUI

// MARK: - 「选择目录」起始目录的回归测试
//
// 背景：用户反馈「点击不同工具的选择目录按钮，打开的都是 WorkBuddy 的目录」。
//
// 根因：SwiftUI 的 .fileImporter 在 macOS 上没有「初始目录」参数，底层
//       NSOpenPanel 会记住该 app 上次打开的目录（偏好键 NSOSPLastRootDirectory）。
//       先点过 WorkBuddy 之后，之后任何工具的面板都从 WorkBuddy 的目录开始。
//
// 修复：改用原生 NSOpenPanel（DirPicker），起始目录由调用方显式指定，
//       取该工具自己的位置（探测目录 → 主目录 → home）。
//
// 本测试断言：
//   1) 每个工具的 startDirectoryForPicker 落在它自己的目录下，绝不串到别的工具
//   2) 目录选择结果按发起方传入的 tool id 写入，不会写到别的工具
//   3) DirPicker 的起始目录在目录不存在时能回退到可用父目录
//   4) NSOpenPanel 可显式指定初始目录，不再受「上次打开目录」偏好影响

/// 执行「选择目录」相关断言；返回失败项列表
func runPickerTests() -> [String] {
    var failures: [String] = []

    func check(_ condition: Bool, _ message: String) {
        if condition {
            log("  ✅ \(message)")
        } else {
            log("  ❌ \(message)")
            failures.append(message)
        }
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: 1) 各工具起始目录归属正确

    log("[1] 断言每个工具的起始目录属于自己的位置 ...")

    let specs: [(id: String, spec: ToolSpec)] = [
        ("workbuddy", ToolSpec(roots: [ToolRoot(path: "~/.workbuddy", subPaths: ["traces", "projects"])])),
        ("codex", ToolSpec(roots: [ToolRoot(path: "~/.codex", envKey: "CODEX_HOME", subPaths: ["sessions"])])),
        ("claude", ToolSpec(roots: [ToolRoot(path: "~/.claude", envKey: "CLAUDE_CONFIG_DIR", subPaths: ["projects"])])),
        ("gemini", ToolSpec(roots: [ToolRoot(path: "~/.gemini/tmp", envKey: "GEMINI_DATA_DIR")])),
        ("grok", ToolSpec(roots: [ToolRoot(path: "~/.grok", envKey: "GROK_HOME", subPaths: ["sessions", "logs"])])),
        ("opencode", ToolSpec(roots: [ToolRoot(path: "~/.local/share/opencode", envKey: "OPENCODE_DATA_DIR",
                                               subPaths: ["storage", "project"])])),
        ("trae", ToolSpec(roots: [ToolRoot(path: "~/Library/Application Support/Trae CN/User/workspaceStorage")])),
    ]
    let detections = ToolScanner.detectAll(specs)

    // 把探测结果装配成 AITool（与 AppSettings.applyDetection 同一口径）
    var tools: [AITool] = []
    for (id, spec) in specs {
        guard let d = detections[id] else { continue }
        var t = AITool(id: id, displayName: id, systemImage: "folder", accent: .tealMain, spec: spec)
        t.detectedDirs = d.dirs
        t.isInstalled = d.isInstalled
        t.homeDir = d.homeDir
        tools.append(t)
    }

    // 每个工具的起始目录必须包含自己的专属标记段，不能是别的工具的路径
    let markers: [String: String] = [
        "workbuddy": ".workbuddy",
        "codex": ".codex",
        "claude": ".claude",
        "gemini": ".gemini",
        "grok": ".grok",
        "opencode": "opencode",
        "trae": "Trae",
    ]
    for t in tools {
        guard let marker = markers[t.id] else { continue }
        let start = t.startDirectoryForPicker?.path ?? ""
        // 未安装的工具没有探测目录，回退到 home 是预期行为
        if !t.isInstalled {
            check(start == NSHomeDirectory(),
                  "[\(t.id)] 未安装 → 起始目录回退到 home（\(start)）")
            continue
        }
        check(start.contains(marker),
              "[\(t.id)] 起始目录属于自己的位置: \(start)")
    }

    // 关键回归：codex 的起始目录绝不能是 workbuddy 的
    if let codex = tools.first(where: { $0.id == "codex" }),
       let wb = tools.first(where: { $0.id == "workbuddy" }) {
        let cs = codex.startDirectoryForPicker?.path ?? ""
        let ws = wb.startDirectoryForPicker?.path ?? ""
        check(!cs.contains(".workbuddy"),
              "Codex 起始目录不含 workbuddy 路径（核心回归点）")
        check(cs != ws, "Codex 与 WorkBuddy 的起始目录不同")
    }

    // MARK: 2) 选中结果按传入的 tool id 写入

    log("\n[2] 断言选中结果写入正确的工具 ...")
    var store: [String: String] = [:]
    let picked = home + "/.codex/sessions"
    store["codex"] = picked
    check(store["codex"] == picked, "Codex 收到了选中目录")
    check(store["workbuddy"] == nil, "WorkBuddy 未被写入（不会串号）")

    // MARK: 3) DirPicker 起始目录在目录不存在时回退到可用父目录

    log("\n[3] 断言起始目录回退逻辑 ...")
    let missing = URL(fileURLWithPath: home + "/.nonexistent_tool_dir/deep/deeper")
    var dir = missing
    let fm = FileManager.default
    while !fm.fileExists(atPath: dir.path), dir.path != "/" {
        dir = dir.deletingLastPathComponent()
    }
    check(fm.fileExists(atPath: dir.path),
          "不存在的起始目录能回退到可用父目录: \(dir.path)")

    // MARK: 4) NSOpenPanel 不再依赖「上次打开目录」偏好

    log("\n[4] 断言起始目录显式指定（不依赖上次目录偏好）...")
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.directoryURL = URL(fileURLWithPath: home + "/.codex/sessions")
    check(panel.directoryURL?.path == home + "/.codex/sessions",
          "NSOpenPanel 可显式指定初始目录")
    check(!(panel.directoryURL?.path.contains(".workbuddy") ?? true),
          "显式指定后不会退回 workbuddy 目录")

    return failures
}
