import Foundation

// CLI 校验入口: swiftc 编译为命令行工具, 输出 JSON 摘要与 web 版/Python 基准对拍
@main
struct CLI {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("usage: tokenlens-cli <dir> [--json]")
            exit(2)
        }
        let root = URL(fileURLWithPath: args[1])
        let parser = TokenParser()
        let t0 = Date()
        parser.scan(root: root)
        let secs = Date().timeIntervalSince(t0)
        let data = Aggregator.build(records: parser.records, root: root.lastPathComponent + "/", files: parser.filesScanned, secs: secs)
        if args.contains("--json") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let summary: [String: Any] = [
                "files": parser.filesScanned,
                "calls": data.kpi.calls,
                "total_tokens": Int(data.kpi.total),
                "input": Int(data.kpi.input),
                "output": Int(data.kpi.output),
                "cached": Int(data.kpi.cached),
                "reasoning": Int(data.kpi.reasoning),
                "sessions": data.kpi.sessions,
                "models": data.kpi.models,
                "active_days": data.kpi.activeDays,
                "scan_seconds": Double(round(secs * 100) / 100),
            ]
            let d = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(d)
            print("")
        } else {
            print("files=\(parser.filesScanned) calls=\(data.kpi.calls) total=\(Int(data.kpi.total)) input=\(Int(data.kpi.input)) output=\(Int(data.kpi.output)) cached=\(Int(data.kpi.cached)) reasoning=\(Int(data.kpi.reasoning)) sessions=\(data.kpi.sessions) secs=\(String(format: "%.1f", secs))")
        }
    }
}
