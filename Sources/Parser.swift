import Foundation

// MARK: - 目录扫描 + 解析主引擎（规则与 web 版 harvestFromObject 一致）

final class TokenParser {
    static let maxFiles = 6000
    static let maxFileBytes = 24 * 1024 * 1024
    static let skipDirs: Set<String> = ["node_modules", ".git", "cache", "blobs", "Cache"]

    private(set) var records: [UsageRecord] = []
    private(set) var filesScanned = 0
    var progress: ((Int, String) -> Void)?

    /// 扫描多个根目录并合并（用于「应用配置」里多个 AI 工具目录的统一统计）
    func scan(roots: [ScanRoot]) {
        records.removeAll()
        filesScanned = 0
        for r in roots where FileManager.default.fileExists(atPath: r.url.path) {
            scanOne(r)
        }
        progress?(filesScanned, "done")
    }

    /// 扫描单个根目录（保持原单目录 API，供 CLI 等使用）
    func scan(root: URL) {
        records.removeAll()
        filesScanned = 0
        scanOne(ScanRoot(url: root, base: root))
        progress?(filesScanned, "done")
    }

    /// 扫描单个根目录（不清空，供多根累加）
    ///
    /// 注意：相对路径（会话身份）以 `base` 为基准而非扫描目录本身。
    /// 这样把 ~/.workbuddy 拆成 traces / projects 两个子目录分别扫描时，
    /// 归组结果与「整目录扫描」完全一致（projects/<项目名>/… 仍按项目归组）。
    private func scanOne(_ root: ScanRoot) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.url.path) else { return }
        let basePath = root.base.path
        var queue: [URL] = [root.url]
        var visited = 0

        while !queue.isEmpty, filesScanned < Self.maxFiles {
            let dir = queue.removeFirst()
            visited += 1
            if visited > 20000 { break }
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
            } catch { continue }
            for item in items {
                let name = item.lastPathComponent
                if Self.skipDirs.contains(name) { continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    queue.append(item)
                } else if name.hasSuffix(".json") || name.hasSuffix(".jsonl") {
                    if filesScanned >= Self.maxFiles { break }
                    filesScanned += 1
                    if filesScanned % 25 == 0 { progress?(filesScanned, name) }
                    parseFile(at: item, basePath: basePath)
                }
            }
        }
    }

    private func parseFile(at url: URL, basePath: String) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > Self.maxFileBytes { return }
        guard let data = try? Data(contentsOf: url) else { return }
        // 相对路径以 base 为基准：会话身份与「整目录扫描」保持一致
        let rel = String(url.path.dropFirst(basePath.count + 1))
        let name = url.lastPathComponent
        if name.hasSuffix(".jsonl") {
            parseJSONL(data, fileName: name, relPath: rel)
        } else {
            parseJSON(data, fileName: name, relPath: rel)
        }
    }

    private func parseJSON(_ data: Data, fileName: String, relPath: String) {
        guard let v = JParse.parse(data) else { parseJSONL(data, fileName: fileName, relPath: relPath); return }
        harvest(v, fileName: fileName, relPath: relPath, ctxTs: Extractor.pickTs(v))
    }

    private func parseJSONL(_ data: Data, fileName: String, relPath: String) {
        var lineStart = 0
        var count = 0
        let bytes = [UInt8](data)
        for i in 0...bytes.count {
            if i == bytes.count || bytes[i] == 0x0A {
                let len = i - lineStart
                if len > 10, count <= 20000 {
                    count += 1
                    let sub = Data(data[lineStart..<i])
                    if let v = JParse.parse(sub) {
                        harvest(v, fileName: fileName, relPath: relPath, ctxTs: Extractor.pickTs(v))
                    }
                }
                lineStart = i + 1
            }
        }
    }

    /// codex 文件级状态: 是否出现过 token_usage_record(逐次权威), token_count 汇总行 seen 签名
    private var codexHasUsageRecord = false
    private var codexCountLastSigs = Set<String>()

    /// 对应 web harvestFromObject 三分支
    private func harvest(_ data: JValue, fileName: String, relPath: String, ctxTs: Double) {
        // 0) codex rollout 专属: 行类型明确, 避免事件广播/汇总行双计
        if let type = data["type"]?.str, let payload = data["payload"], case .object = payload {
            let ts = ctxTs
            switch type {
            case "token_usage_record":
                if let u = Extractor.readUsageFields(payload["usage"]) {
                    codexHasUsageRecord = true
                    push(u, ts: ts, model: Extractor.pickModel(payload), fileName: fileName, relPath: relPath)
                }
                return
            case "event_msg":
                // token_count 的广播副本, 由 token_count 行处理; 若无 token_count 行则兜底处理
                if let info = eventMsgCountInfo(payload) {
                    handleCodexCount(info, ts: ts, fileName: fileName, relPath: relPath, fromBroadcast: true)
                }
                return
            case "token_count":
                if let info = countInfo(payload) {
                    handleCodexCount(info, ts: ts, fileName: fileName, relPath: relPath, fromBroadcast: false)
                }
                return
            default: break
            }
        }
        // 0.1) codex 文件已用专属通道 → 其余行不再通用递归
        if codexHasUsageRecord && fileName.hasPrefix("rollout-") { return }

        // 1) traces 格式
        if let spans = data["spans"]?.arr {
            for s in spans {
                guard s["type"]?.str == "generation" else { continue }
                var chunksArr: [JValue] = []
                if let to = s["toolOutput"]?.str {
                    if let parsed = JParse.parse(Data(to.utf8)) {
                        if let a = parsed.arr { chunksArr = a } else { chunksArr = [parsed] }
                    }
                }
                let ts = Extractor.pickTs(s) != 0 ? Extractor.pickTs(s) : ctxTs
                for c in chunksArr {
                    let u = c["usage"] != nil ? Extractor.readUsageFields(c["usage"]) : Extractor.readUsageFields(c)
                    if let u { push(u, ts: ts != 0 ? ts : ctxTs, model: Extractor.findModelNear(c), fileName: fileName, relPath: relPath) }
                }
            }
            return
        }
        let ts = ctxTs
        let ctxModel = Extractor.pickModel(data)

        // 2) codex 累计+增量 → 只计增量
        if case .object = data {
            var hasTotal = false, hasLast = false
            func probe(_ node: JValue?, depth: Int) {
                guard let n = node, depth <= 6, !(hasTotal && hasLast) else { return }
                if case .object = n {
                    if Extractor.hasKey(n, ["total_token_usage", "total_tokens_usage"]) { hasTotal = true }
                    if Extractor.hasKey(n, ["last_token_usage", "last_tokens_usage"]) { hasLast = true }
                    if let o = n.obj { for (_, v) in o { probe(v, depth: depth + 1) } }
                } else if let a = n.arr {
                    for it in a { probe(it, depth: depth + 1) }
                }
            }
            probe(data, depth: 0)
            if hasTotal && hasLast {
                // JValue 为值类型 enum, 无环引用风险, 无需 visited 去重
                // (ObjectIdentifier 对 enum 装箱不稳定, 曾导致子树被误判已访问)
                func collect(_ node: JValue?, depth: Int) {
                    guard let n = node, depth <= 6 else { return }
                    if case .object = n {
                        if Extractor.hasKey(n, ["last_token_usage", "last_tokens_usage"]) {
                            if let last = Extractor.readUsageFields(n["last_token_usage"] ?? n["last_tokens_usage"]) {
                                push(last, ts: Extractor.pickTs(n) != 0 ? Extractor.pickTs(n) : ts, model: ctxModel, fileName: fileName, relPath: relPath)
                            }
                        }
                        if let o = n.obj { for (_, v) in o { collect(v, depth: depth + 1) } }
                    } else if let a = node?.arr {
                        for it in a { collect(it, depth: depth + 1) }
                    }
                }
                collect(data, depth: 0)
                return
            }
        }

        // 3) 权威 usage（message/usage/response）优先
        if case .object = data {
            for p in ["message", "usage", "response"] {
                if let holder = data[p], case .object = holder {
                    if let u = Extractor.readUsageFields(holder["usage"]) {
                        let m = p == "message" ? (Extractor.pickModel(data["message"]).isEmpty ? ctxModel : Extractor.pickModel(data["message"])) : ctxModel
                        push(u, ts: ts, model: m, fileName: fileName, relPath: relPath)
                        return
                    }
                    if let u = Extractor.readUsageFields(holder) {
                        let m = p == "message" ? (Extractor.pickModel(data["message"]).isEmpty ? ctxModel : Extractor.pickModel(data["message"])) : ctxModel
                        push(u, ts: ts, model: m, fileName: fileName, relPath: relPath)
                        return
                    }
                }
            }
        }
        for u in Extractor.findUsageNodes(data) {
            push(u, ts: ts, model: ctxModel, fileName: fileName, relPath: relPath)
        }
    }

    // MARK: codex rollout 辅助

    /// payload={info:{total_token_usage,last_token_usage,...}} 或直接含这两个 key
    private func countInfo(_ payload: JValue) -> JValue? {
        if Extractor.hasKey(payload, ["total_token_usage", "total_tokens_usage"]) { return payload }
        if let info = payload["info"], Extractor.hasKey(info, ["total_token_usage", "total_tokens_usage"]) { return info }
        return nil
    }

    /// event_msg 行内 token_count 副本探测
    private func eventMsgCountInfo(_ payload: JValue) -> JValue? {
        if let t = payload["type"]?.str, t == "token_count" { return countInfo(payload) }
        if countInfo(payload) != nil { return payload }
        return nil
    }

    /// token_count 类行: 只取 last_token_usage(增量); token_usage_record 出现后失效(逐次记录更权威)
    private func handleCodexCount(_ holder: JValue, ts: Double, fileName: String, relPath: String, fromBroadcast: Bool) {
        guard !codexHasUsageRecord else { return }
        guard let last = Extractor.readUsageFields(holder["last_token_usage"] ?? holder["last_tokens_usage"]) else { return }
        let sig = "\(last.input)/\(last.output)/\(last.cached)/\(last.reasoning)/\(last.total)"
        if fromBroadcast && codexCountLastSigs.contains(sig) { return }   // 广播去重
        codexCountLastSigs.insert(sig)
        push(last, ts: ts, model: "", fileName: fileName, relPath: relPath)
    }

    private func push(_ u: UsageFields, ts: Double, model: String, fileName: String, relPath: String) {
        records.append(UsageRecord(
            ts: ts != 0 ? ts : Date().timeIntervalSince1970 * 1000,
            model: model.isEmpty ? "unknown" : model,
            input: u.input, output: u.output, cached: u.cached, reasoning: u.reasoning,
            total: u.total != 0 ? u.total : u.input + u.output,
            file: fileName, path: relPath))
    }
}
