import Foundation

// MARK: - 工具目录自动探测的回归测试
//
// 覆盖「应用启动时自动扫描本机已安装的 AI 工具，并把日志目录写入对应工具
// 的应用配置」这条链路。
//
// 断言要点：
//   1) 探测能认出已安装的工具（本机装了 Codex / WorkBuddy / Claude Code / Trae）
//   2) 探测到的目录真实存在，且是「日志/会话目录」而非工具主目录里的噪音目录
//   3) 生效的扫描根带有正确的 base 基准（保证工作空间归组与整目录扫描一致）
//   4) 探测是只读的：不产生任何新文件，也不修改用户目录
//
// 用法: ./Tests/run_detect.sh
// 注意: 本测试读取真实用户目录，只做 stat 判断，不写入任何数据。

func log(_ s: String) { print(s); fflush(stdout) }

var failures: [String] = []

func check(_ condition: Bool, _ message: String) {
    if condition {
        log("  ✅ \(message)")
    } else {
        log("  ❌ \(message)")
        failures.append(message)
    }
}

/// 断言路径存在且是目录
func assertDir(_ path: String, _ label: String) {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    check(exists && isDir.boolValue, "\(label) 目录存在: \(path)")
}

let home = FileManager.default.homeDirectoryForCurrentUser.path

// MARK: - 1) 探测本机工具

log("[1] 探测本机已安装的 AI 工具 ...")
let specs: [(String, ToolSpec)] = [
    ("workbuddy", ToolSpec(
        roots: [ToolRoot(path: "~/.workbuddy", subPaths: ["traces", "projects"])],
        cliNames: ["workbuddy"], appNames: ["WorkBuddy"])),
    ("codex", ToolSpec(
        roots: [ToolRoot(path: "~/.codex", envKey: "CODEX_HOME", subPaths: ["sessions"])],
        cliNames: ["codex"], appNames: ["Codex"])),
    ("claude", ToolSpec(
        roots: [ToolRoot(path: "~/.claude", envKey: "CLAUDE_CONFIG_DIR", subPaths: ["projects"])],
        cliNames: ["claude"], appNames: ["Claude"])),
    ("gemini", ToolSpec(
        roots: [ToolRoot(path: "~/.gemini/tmp", envKey: "GEMINI_DATA_DIR")],
        cliNames: ["gemini"], appNames: ["Gemini"])),
    ("grok", ToolSpec(
        roots: [ToolRoot(path: "~/.grok", envKey: "GROK_HOME", subPaths: ["sessions", "logs"])],
        cliNames: ["grok"], appNames: ["Grok"])),
    ("opencode", ToolSpec(
        roots: [ToolRoot(path: "~/.local/share/opencode", envKey: "OPENCODE_DATA_DIR",
                         subPaths: ["storage", "project"])],
        cliNames: ["opencode"], appNames: ["OpenCode"])),
    ("trae", ToolSpec(
        roots: [ToolRoot(path: "~/Library/Application Support/Trae CN/User/workspaceStorage")],
        cliNames: ["trae"], appNames: ["Trae", "Trae CN", "TRAE SOLO CN"])),
]
let results = ToolScanner.detectAll(specs)

for (id, d) in results.sorted(by: { $0.key < $1.key }) {
    let paths = d.dirs.map(\.path).joined(separator: ", ")
    log("    [\(id)] installed=\(d.isInstalled) dirs=\(d.dirs.count) \(paths)")
}

// MARK: - 2) 断言：本机实际安装的工具都被认出

log("\n[2] 断言安装检测 ...")
// 本机装了 Codex（~/.codex 存在）、WorkBuddy（~/.workbuddy）、Trae（Application Support/Trae CN）
if FileManager.default.fileExists(atPath: home + "/.codex") {
    check(results["codex"]?.isInstalled == true, "Codex 被认出为已安装")
}
if FileManager.default.fileExists(atPath: home + "/.workbuddy") {
    check(results["workbuddy"]?.isInstalled == true, "WorkBuddy 被认出为已安装")
}
if FileManager.default.fileExists(atPath: home + "/.claude") {
    check(results["claude"]?.isInstalled == true, "Claude Code 被认出为已安装")
}

// MARK: - 3) 断言：探测到的目录存在，且 base 正确

log("\n[3] 断言探测到的目录与 base 基准 ...")
for (id, d) in results {
    for dir in d.dirs {
        assertDir(dir.path, "[\(id)]")
        check(FileManager.default.fileExists(atPath: dir.base, isDirectory: nil),
              "[\(id)] base 存在: \(dir.base)")
        // base 必须是 dir.path 的祖先，否则相对路径计算会越界
        let isAncestor = dir.path == dir.base || dir.path.hasPrefix(dir.base + "/")
        check(isAncestor, "[\(id)] base 是目录的祖先: \(dir.base)")
    }
}

// MARK: - 4) 断言：WorkBuddy 的 traces / projects 被分别定位（不扫噪音目录）

log("\n[4] 断言 WorkBuddy 精确定位到日志子目录 ...")
let wbDirs = results["workbuddy"]?.dirs.map(\.path) ?? []
if FileManager.default.fileExists(atPath: home + "/.workbuddy/traces") {
    check(wbDirs.contains(home + "/.workbuddy/traces"), "定位到 ~/.workbuddy/traces")
    check(wbDirs.contains(home + "/.workbuddy/projects"), "定位到 ~/.workbuddy/projects")
    // 不应把噪音目录配成扫描根（changes-detail / cache / connectors-marketplace 等）
    let noise = ["changes-detail", "connectors-marketplace", "cache", "blobs", "file-tree-manifests"]
    for n in noise {
        let hit = wbDirs.contains { $0.hasSuffix("/" + n) }
        check(!hit, "未把噪音目录 \(n) 配成扫描根")
    }
}

// MARK: - 5) 断言：探测是只读的（不产生新文件）

log("\n[5] 断言探测只读 ...")
let probeDir = home + "/.workbuddy/traces"
if FileManager.default.fileExists(atPath: probeDir) {
    let before = (try? FileManager.default.contentsOfDirectory(atPath: probeDir))?.count ?? 0
    _ = ToolScanner.detectAll(specs)
    let after = (try? FileManager.default.contentsOfDirectory(atPath: probeDir))?.count ?? 0
    check(before == after, "探测前后 ~/.workbuddy/traces 条目数不变 (\(before) → \(after))")
}

// MARK: - 6) 断言：多目录扫描结果与整目录扫描一致（base 基准正确）

log("\n[6] 断言多目录合并统计与整目录扫描等价 ...")
func summarize(_ roots: [ScanRoot]) -> (calls: Int, total: Double, sessions: Int, workspaces: [String: Double]) {
    let p = TokenParser()
    p.scan(roots: roots)
    let d = Aggregator.build(records: p.records, root: "t/", files: p.filesScanned, secs: 0)
    var ws: [String: Double] = [:]
    for w in d.workspaces { ws[w.name] = w.total }
    return (d.kpi.calls, d.kpi.total, d.kpi.sessions, ws)
}

if FileManager.default.fileExists(atPath: home + "/.workbuddy/traces"),
   FileManager.default.fileExists(atPath: home + "/.workbuddy/projects") {
    let split = summarize([
        ScanRoot(url: URL(fileURLWithPath: home + "/.workbuddy/traces"),
                 base: URL(fileURLWithPath: home + "/.workbuddy")),
        ScanRoot(url: URL(fileURLWithPath: home + "/.workbuddy/projects"),
                 base: URL(fileURLWithPath: home + "/.workbuddy")),
    ])
    let whole = summarize([
        ScanRoot(url: URL(fileURLWithPath: home + "/.workbuddy"),
                 base: URL(fileURLWithPath: home + "/.workbuddy")),
    ])
    check(split.calls == whole.calls, "调用数一致 (拆分 \(split.calls) vs 整目录 \(whole.calls))")
    check(abs(split.total - whole.total) < 1, "token 总数一致 (拆分 \(Int(split.total)) vs 整目录 \(Int(whole.total)))")
    check(split.sessions == whole.sessions, "会话数一致 (\(split.sessions) vs \(whole.sessions))")
    check(split.workspaces == whole.workspaces, "工作空间分布一致")
}

// MARK: - 7) 「选择目录」起始目录归属（用户反馈缺陷的回归点）

log("\n[7] 断言「选择目录」面板起始目录归属 ...")
let pickerFailures = runPickerTests()
failures.append(contentsOf: pickerFailures)

// MARK: - 8) 时间范围筛选（用户需求：主界面顶部加日期筛选）

log("\n[8] 断言时间范围筛选 ...")
let rangeFailures = runRangeTests()
failures.append(contentsOf: rangeFailures)

// MARK: 结论

print("")
if failures.isEmpty {
    print("===== ✅ PASS: 工具目录自动探测全链路可用 =====")
    exit(0)
} else {
    print("===== ❌ FAIL: \(failures.count) 项断言未通过 =====")
    for f in failures { print("   - \(f)") }
    exit(1)
}
