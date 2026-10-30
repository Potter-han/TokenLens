import Foundation

// MARK: - 工具日志目录探测器
//
// 应用启动时扫描本机已安装的 AI 工具（Codex / WorkBuddy / Claude Code /
// OpenCode / Gemini CLI / Grok Build / Trae），定位各自真正存放会话与日志的
// 目录，把结果写进「应用配置」里对应工具的配置项。
//
// 探测分两层：
//   1) 安装检测：主目录存在 / PATH 上有 CLI / /Applications 下有 App
//   2) 日志定位：在主目录下按各工具已知的子目录结构找会话与日志目录
//      （~/.workbuddy/traces、~/.codex/sessions、~/.claude/projects …）
//
// 为什么按「已知子目录结构」而不是「扫描内容找 usage 关键字」：
//   - Codex 的 rollout 文件把 token 记录写在第 62 行之后（文件 386KB），
//     读文件头嗅探必然漏判；
//   - WorkBuddy 主目录下的 changes-detail / connectors-marketplace 等
//     目录里也有 "usage" 字样，但并非 token 用量数据。
//   已知目录名来自各工具官方文档 + 本机实测，判定稳定且可解释。
//
// 相对路径基准（base）统一取工具主目录：这样「工作空间」归组与直接扫描
// 整个主目录的结果保持一致（例如 ~/.workbuddy/traces 里的文件仍归到 traces 组）。
//
// ⚠️ 全程只读：只 stat 目录是否存在、是否非空，不读取用户数据文件内容。

// MARK: - 探测规格

/// 一个工具的「主目录 + 其下关注的日志子目录」组合
struct ToolRoot {
    /// 主目录路径（支持 `~` 前缀）
    let path: String
    /// 环境变量覆盖（如 CODEX_HOME）。设置时优先于 path
    let envKey: String?
    /// 该主目录下关注的日志/会话子目录；为空表示主目录本身即数据目录
    let subPaths: [String]

    init(path: String, envKey: String? = nil, subPaths: [String] = []) {
        self.path = path
        self.envKey = envKey
        self.subPaths = subPaths
    }
}

/// 一个 AI 工具的完整探测规格
struct ToolSpec {
    /// 主目录候选组
    let roots: [ToolRoot]
    /// PATH 上的可执行文件名（用于安装检测）
    let cliNames: [String]
    /// /Applications 下的 .app 名（用于安装检测）
    let appNames: [String]

    init(roots: [ToolRoot], cliNames: [String] = [], appNames: [String] = []) {
        self.roots = roots
        self.cliNames = cliNames
        self.appNames = appNames
    }
}

// MARK: - 探测结果

/// 探测到的一个日志目录
struct DetectedDir: Codable, Equatable {
    /// 日志目录绝对路径
    let path: String
    /// 相对路径基准（工具主目录），用于工作空间归组
    let base: String

    var url: URL { URL(fileURLWithPath: path) }
    var baseURL: URL { URL(fileURLWithPath: base) }
}

/// 单个工具的探测结果
struct ToolDetection {
    var toolID: String
    /// 是否检测到该工具已安装
    var isInstalled: Bool = false
    /// 探测到的日志目录
    var dirs: [DetectedDir] = []
    /// 该工具的主目录（已存在者），用于选择面板的起始位置
    var homeDir: String?
}

// MARK: - 探测器

enum ToolScanner {

    // MARK: 常量

    /// PATH 之外的常见 CLI 安装位置（homebrew / nvm / fnm / volta / bun / pnpm）
    private static let extraBinDirs = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/opt/local/bin",
        "~/.local/bin", "~/.bun/bin", "~/.volta/bin", "~/.npm-global/bin",
        "~/.yarn/bin", "~/.local/share/pnpm", "~/.deno/bin",
    ]
    /// 带通配的 CLI 安装位置（逐层展开）
    private static let globBinDirs = [
        "~/.nvm/versions/node/*/bin",
        "~/.fnm/node-versions/*/installation/bin",
        "~/.local/share/fnm/node-versions/*/installation/bin",
        "~/.asdf/installs/nodejs/*/bin",
    ]
    /// App 查找位置
    private static let appDirs = [
        "/Applications", "/Applications/Utilities", "~/Applications",
    ]

    // MARK: 对外入口

    /// 批量探测所有工具
    static func detectAll(_ specs: [(id: String, spec: ToolSpec)]) -> [String: ToolDetection] {
        var out: [String: ToolDetection] = [:]
        for (id, spec) in specs {
            out[id] = detect(id: id, spec: spec)
        }
        return out
    }

    /// 探测单个工具
    static func detect(id: String, spec: ToolSpec) -> ToolDetection {
        var d = ToolDetection(toolID: id)

        // 展开所有主目录候选（环境变量优先于默认路径）
        var roots: [ToolRoot] = []
        for r in spec.roots {
            var resolved = r
            if let key = r.envKey,
               let v = ProcessInfo.processInfo.environment[key],
               !v.isEmpty {
                resolved = ToolRoot(path: v, envKey: nil, subPaths: r.subPaths)
            }
            roots.append(resolved)
        }
        let homePaths = PathUtil.unique(roots.map { PathUtil.expand($0.path) })

        // 安装检测：主目录 / CLI / App 任一命中即视为已安装
        d.isInstalled = homePaths.contains { isDirectory($0) }
            || spec.cliNames.contains { findCLI($0) != nil }
            || spec.appNames.contains { findApp($0) != nil }

        // 日志定位：逐个主目录找已知日志子目录
        for (i, r) in roots.enumerated() {
            let home = PathUtil.expand(r.path)
            guard isDirectory(home) else { continue }
            // 记录第一个存在的主目录：作为选择面板的起始位置
            if d.homeDir == nil { d.homeDir = home }
            if r.subPaths.isEmpty {
                // 主目录本身即数据目录
                if isNonEmptyDir(home) {
                    d.dirs.append(DetectedDir(path: home, base: home))
                }
                continue
            }
            for sub in r.subPaths {
                let p = (home as NSString).appendingPathComponent(sub)
                guard isDirectory(p), isNonEmptyDir(p) else { continue }
                d.dirs.append(DetectedDir(path: p, base: home))
            }
            _ = i
        }

        // 去重（同一目录可能经由多个候选命中）
        var seen = Set<String>()
        d.dirs = d.dirs.filter { seen.insert($0.path).inserted }
        return d
    }

    // MARK: 目录判定

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// 目录非空（含至少一个条目，隐藏文件也算）
    static func isNonEmptyDir(_ path: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return !names.isEmpty
    }

    // MARK: CLI / App 探测

    /// 在 PATH 与常见安装位置里找可执行文件
    static func findCLI(_ name: String) -> String? {
        for dir in cliSearchDirs() {
            let p = (dir as NSString).appendingPathComponent(name)
            if isExecutable(p) { return p }
        }
        return nil
    }

    /// 在 /Applications 等位置找 .app
    static func findApp(_ name: String) -> String? {
        for dir in appDirs {
            let p = (dir as NSString).appendingPathComponent(name + ".app")
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// CLI 搜索目录：PATH + 常见安装位置（通配展开）
    private static func cliSearchDirs() -> [String] {
        var dirs: [String] = []
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        dirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        dirs.append(contentsOf: extraBinDirs.map { PathUtil.expand($0) })
        for pattern in globBinDirs {
            dirs.append(contentsOf: expandGlob(pattern))
        }
        return PathUtil.unique(dirs)
    }

    /// 展开形如 `~/.nvm/versions/node/*/bin` 的通配路径
    private static func expandGlob(_ pattern: String) -> [String] {
        let expanded = PathUtil.expand(pattern)
        let parts = expanded.split(separator: "/").map(String.init)
        guard let starIdx = parts.firstIndex(of: "*") else { return [expanded] }

        var current = ""
        for (i, part) in parts.enumerated() {
            if i == starIdx {
                let base = current.isEmpty ? "/" : current
                let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                let tail = parts[(i + 1)...].joined(separator: "/")
                return names.map { n in
                    let dir = n.hasPrefix(".") ? base : base + "/" + n
                    return tail.isEmpty ? dir : dir + "/" + tail
                }
            }
            current = current.isEmpty ? "/" + part : current + "/" + part
        }
        return [expanded]
    }
}

// MARK: - 路径工具

enum PathUtil {
    /// 展开 `~` 与 `${VAR}` 环境变量
    static func expand(_ path: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var s = path
        while let r = s.range(of: "\\$\\{([A-Za-z_][A-Za-z0-9_]*)\\}",
                              options: .regularExpression) {
            let name = String(s[r]).dropFirst(2).dropLast()
            let val = env[String(name)] ?? ""
            s.replaceSubrange(r, with: val)
        }
        return (s as NSString).expandingTildeInPath
    }

    /// 路径去重（保持顺序）
    static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}
