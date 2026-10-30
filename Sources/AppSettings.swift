import Foundation
import ServiceManagement
import Combine
import SwiftUI

// MARK: - 全局设置（单一数据源，持久化到 UserDefaults）
//
// 与 ScanStore 平级的单例。四项设置：
//   - autoRefresh           自动刷新（每 60s 轮询重扫）—— 默认开启
//   - minimizeToTrayOnClose 关闭主窗口时最小化到托盘而非退出 —— 默认开启
//   - trayStyle             托盘（菜单栏弹窗）样式：面板 / 菜单 —— 默认面板（菜单暂未开放）
//   - launchAtLogin         开机自启动 —— 默认关闭
//
// 数值变化即写入 UserDefaults；launchAtLogin 额外同步给系统的登录项。
//
// 「应用配置」部分管理要扫描的 AI 工具目录：
//   - 启动时由 ToolScanner 自动探测本机已安装工具的日志目录；
//   - 用户也可在设置页手动指定（手动优先于自动探测）。

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var autoRefresh: Bool {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: Keys.autoRefresh) }
    }
    @Published var minimizeToTrayOnClose: Bool {
        didSet { UserDefaults.standard.set(minimizeToTrayOnClose, forKey: Keys.minimizeToTrayOnClose) }
    }
    @Published var trayStyle: TrayStyle {
        didSet { UserDefaults.standard.set(trayStyle.rawValue, forKey: Keys.trayStyle) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin()
        }
    }
    /// 在程序坞显示图标（false = 纯菜单栏应用，默认）
    @Published var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: Keys.showDockIcon)
            applyDockIconPolicy()
        }
    }

    /// 按设置应用 Dock 策略：regular = 程序坞常驻图标 + 进 Cmd-Tab；
    /// accessory = 纯菜单栏应用（程序坞无图标）。
    ///
    /// 运行时 setActivationPolicy 可以覆盖 Info.plist 的 LSUIElement=true，
    /// 这是菜单栏类应用提供「显示程序坞图标」开关的标准做法。
    func applyDockIconPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    // MARK: 应用配置 —— 要扫描的 AI 工具目录

    /// 已纳入扫描的 AI 工具（顺序固定）。路径变更即持久化并触发重扫。
    @Published var tools: [AITool]

    /// 当前所有「有效路径」对应的目录（自动探测到的 + 手动指定的），统一扫描这些
    var scanRoots: [ScanRoot] {
        tools.flatMap { $0.effectiveDirs.map { ScanRoot(url: $0.url, base: $0.baseURL) } }
    }

    /// 为某个工具设置/清除手动目录（nil = 恢复自动探测）
    func setCustomPath(_ path: String?, for id: String) {
        guard let i = tools.firstIndex(where: { $0.id == id }) else { return }
        var copy = tools
        copy[i].customPath = path
        tools = copy
        var stored = UserDefaults.standard.dictionary(forKey: Keys.toolPaths) as? [String: String] ?? [:]
        if let p = path { stored[id] = p } else { stored.removeValue(forKey: id) }
        UserDefaults.standard.set(stored, forKey: Keys.toolPaths)
        // 目录配置变化后，立即按新配置重扫
        ScanStore.shared.scanEnabledTools(silent: true)
    }

    /// 重新探测本机已安装工具的日志目录（设置页「重新探测」按钮）
    func rescanTools() {
        refreshToolsAndScan(silent: true)
    }

    /// 重新探测本机工具目录并按新配置重扫（后台线程执行探测）
    ///
    /// 探测只读不写：只判断目录是否存在，不读取用户数据文件内容。
    /// 每 60s 自动刷新与启动时都会走这里，因此用户新装的工具、
    /// 或首次运行后新生成的会话目录（如 ~/.claude/projects）都会被自动纳入。
    func refreshToolsAndScan(silent: Bool = false) {
        let specs = Self.defaultTools.map { ($0.id, $0.spec) }
        Task.detached(priority: .utility) {
            let results = ToolScanner.detectAll(specs)
            await MainActor.run {
                self.applyDetection(results)
                ScanStore.shared.scanEnabledTools(silent: silent)
            }
        }
    }

    private init() {
        let ud = UserDefaults.standard
        self.autoRefresh = (ud.object(forKey: Keys.autoRefresh) as? Bool) ?? true
        self.minimizeToTrayOnClose = (ud.object(forKey: Keys.minimizeToTrayOnClose) as? Bool) ?? true
        let raw = ud.string(forKey: Keys.trayStyle) ?? TrayStyle.panel.rawValue
        self.trayStyle = TrayStyle(rawValue: raw) ?? .panel
        self.launchAtLogin = (ud.object(forKey: Keys.launchAtLogin) as? Bool) ?? false
        self.showDockIcon = (ud.object(forKey: Keys.showDockIcon) as? Bool) ?? false
        let storedPaths = ud.dictionary(forKey: Keys.toolPaths) as? [String: String] ?? [:]
        self.tools = Self.defaultTools.map { base in
            var t = base
            t.customPath = storedPaths[t.id]
            return t
        }
        // 启动时把系统真实的登录项状态同步回来（用户可能在系统设置里改过）
        syncLaunchAtLoginFromSystem()
    }

    // MARK: 开机自启动

    /// 把当前开关值同步给系统（macOS 13+ 的 SMAppService.mainApp，无需额外 Helper）
    func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("[TokenLens] 设置开机自启动失败：\(error.localizedDescription)")
        }
    }

    /// 读取系统真实启用状态，避免开关值与系统不一致
    private func syncLaunchAtLoginFromSystem() {
        guard #available(macOS 13.0, *) else { return }
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    // MARK: 托盘样式

    enum TrayStyle: String, CaseIterable, Identifiable {
        case panel = "panel"   // 面板（当前可用）
        case menu = "menu"     // 菜单（暂未开放）
        var id: String { rawValue }
        var title: String {
            switch self {
            case .panel: return "面板"
            case .menu: return "菜单"
            }
        }
        /// 当前是否可切换（菜单暂未开放 → 禁用）
        var isEnabled: Bool {
            switch self {
            case .panel: return true
            case .menu: return false
            }
        }
    }

    private enum Keys {
        static let autoRefresh = "autoRefresh"
        static let minimizeToTrayOnClose = "minimizeToTrayOnClose"
        static let trayStyle = "trayStyle"
        static let launchAtLogin = "launchAtLogin"
        static let toolPaths = "toolPaths"
        static let showDockIcon = "showDockIcon"
    }
}

// MARK: - 要扫描的 AI 工具

/// 一个纳入扫描的 AI 工具及其日志/会话目录
struct AITool: Identifiable {
    let id: String
    let displayName: String
    let systemImage: String
    let accent: Color
    /// 探测规格（本机安装痕迹 + 日志目录结构）
    let spec: ToolSpec
    /// 用户手动指定的目录（绝对路径）；nil = 用自动探测结果
    var customPath: String?
    /// 自动探测到的日志目录
    var detectedDirs: [DetectedDir] = []
    /// 是否检测到该工具已安装
    var isInstalled: Bool = false
    /// 该工具的主目录（探测时记录），用于选择面板的起始位置
    var homeDir: String?

    /// 实际生效的扫描目录：手动优先，否则自动探测
    var effectiveDirs: [DetectedDir] {
        if let p = customPath {
            // 手动目录以其自身为 base：相对路径从该目录起算
            return [DetectedDir(path: p, base: p)]
        }
        return detectedDirs
    }

    /// 生效路径的展示文本（设置页用）
    var displayPaths: [String] { effectiveDirs.map(\.path) }

    /// 「选择目录」面板的起始目录
    ///
    /// 取该工具自己的位置：已探测到的日志目录 → 主目录 → 用户 home。
    /// 不能用系统记忆的「上次打开目录」，否则每个工具的面板都会停在第一个工具的目录。
    var startDirectoryForPicker: URL? {
        if let first = detectedDirs.first { return URL(fileURLWithPath: first.path) }
        if let h = homeDir { return URL(fileURLWithPath: h) }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}

extension AppSettings {
    /// 默认纳入扫描的 AI 工具（顺序即界面展示顺序）
    ///
    /// 各工具的目录结构依据官方文档 + 本机实测确定：
    ///   - Codex     : $CODEX_HOME/sessions（rollout-*.jsonl 记 token）
    ///   - WorkBuddy : ~/.workbuddy/{traces,projects}（路由 trace + 会话日志）
    ///   - Claude    : ~/.claude/projects（每项目一个目录，会话 .jsonl）
    ///   - OpenCode  : ~/.local/share/opencode/{storage,project}
    ///   - Gemini    : ~/.gemini/tmp（项目哈希目录下的 chats/）
    ///   - Grok      : ~/.grok/{sessions,logs}
    ///   - Trae      : ~/Library/Application Support/Trae*/ModularData/ai-agent
    static let defaultTools: [AITool] = [
        AITool(id: "workbuddy", displayName: "WorkBuddy",
               systemImage: "brain", accent: Color.tealMain,
               spec: ToolSpec(
                   roots: [
                       ToolRoot(path: "~/.workbuddy", subPaths: ["traces", "projects"]),
                   ],
                   cliNames: ["workbuddy"],
                   appNames: ["WorkBuddy"])),
        AITool(id: "codex", displayName: "Codex",
               systemImage: "cpu", accent: Color.blueOpacity,
               spec: ToolSpec(
                   roots: [
                       ToolRoot(path: "~/.codex", envKey: "CODEX_HOME", subPaths: ["sessions"]),
                       ToolRoot(path: "~/.config/codex", subPaths: ["sessions"]),
                   ],
                   cliNames: ["codex"],
                   appNames: ["Codex"])),
        AITool(id: "claude", displayName: "Claude Code",
               systemImage: "waveform", accent: Color.violetMain,
               spec: ToolSpec(
                   roots: [
                       ToolRoot(path: "~/.claude", envKey: "CLAUDE_CONFIG_DIR", subPaths: ["projects"]),
                       ToolRoot(path: "~/.config/claude", subPaths: ["projects"]),
                   ],
                   cliNames: ["claude"],
                   appNames: ["Claude"])),
        AITool(id: "gemini", displayName: "Gemini CLI",
               systemImage: "star.fill", accent: Color.orangeAccent,
               spec: ToolSpec(
                   roots: [
                       // Gemini CLI 的会话落在 tmp/<项目哈希>/chats/ 下，
                       // 数据目录本身即日志目录（env GEMINI_DATA_DIR 可覆盖）
                       ToolRoot(path: "~/.gemini/tmp", envKey: "GEMINI_DATA_DIR"),
                   ],
                   cliNames: ["gemini"],
                   appNames: ["Gemini"])),
        AITool(id: "grok", displayName: "Grok Build",
               systemImage: "circle.slash", accent: Color(hue: 0.0, saturation: 0.0, brightness: 0.4),
               spec: ToolSpec(
                   roots: [
                       ToolRoot(path: "~/.grok", envKey: "GROK_HOME", subPaths: ["sessions", "logs"]),
                   ],
                   cliNames: ["grok"],
                   appNames: ["Grok"])),
        AITool(id: "opencode", displayName: "OpenCode",
               systemImage: "square", accent: Color(hue: 0.55, saturation: 0.5, brightness: 0.5),
               spec: ToolSpec(
                   roots: [
                       ToolRoot(path: "~/.local/share/opencode", envKey: "OPENCODE_DATA_DIR",
                                subPaths: ["storage", "project"]),
                       ToolRoot(path: "~/.config/opencode", subPaths: ["storage", "project"]),
                   ],
                   cliNames: ["opencode"],
                   appNames: ["OpenCode"])),
        AITool(id: "trae", displayName: "Trae",
               systemImage: "paperplane", accent: Color(hue: 0.33, saturation: 0.6, brightness: 0.55),
               spec: ToolSpec(
                   roots: [
                       // Trae 是 VSCode 派生：会话存在 User/workspaceStorage 的
                       // state.vscdb（SQLite），AI 会话存在 ModularData/ai-agent
                       ToolRoot(path: "~/Library/Application Support/Trae CN/User/workspaceStorage"),
                       ToolRoot(path: "~/Library/Application Support/TRAE SOLO CN/User/workspaceStorage"),
                       ToolRoot(path: "~/Library/Application Support/Trae/User/workspaceStorage"),
                   ],
                   cliNames: ["trae"],
                   appNames: ["Trae", "Trae CN", "TRAE SOLO CN"])),
    ]
}

// MARK: - 启动时自动探测

extension AppSettings {
    /// 应用启动时调用：扫描本机已安装的 AI 工具，把日志目录写入对应工具的配置
    ///
    /// 只读探测，不改用户任何文件。探测在后台线程进行，
    /// 完成后回到主线程写入配置并触发重扫。
    func detectAndConfigureTools() {
        let specs = Self.defaultTools.map { ($0.id, $0.spec) }
        Task.detached(priority: .utility) {
            let results = ToolScanner.detectAll(specs)
            await MainActor.run {
                self.applyDetection(results)
                ScanStore.shared.scanEnabledTools(silent: true)
            }
        }
    }

    /// 把探测结果写入各工具的配置（不覆盖用户手动指定的目录）
    private func applyDetection(_ results: [String: ToolDetection]) {
        var copy = tools
        for i in copy.indices {
            guard let det = results[copy[i].id] else { continue }
            copy[i].detectedDirs = det.dirs
            copy[i].isInstalled = det.isInstalled
            copy[i].homeDir = det.homeDir
        }
        tools = copy
    }
}
