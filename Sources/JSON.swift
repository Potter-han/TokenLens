import Foundation

// MARK: - JSON 值（只读轻量解析，避免 JSONSerialization 对象图开销）

indirect enum JValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JValue])
    case object([(String, JValue)])

    var obj: [(String, JValue)]? { if case .object(let o) = self { return o }; return nil }
    var arr: [JValue]? { if case .array(let a) = self { return a }; return nil }
    var str: String? { if case .string(let s) = self { return s }; return nil }
    var num: Double? { if case .number(let n) = self { return n }; return nil }
    subscript(key: String) -> JValue? {
        guard let o = obj else { return nil }
        for (k, v) in o where k == key { return v }
        return nil
    }
}

enum JParse {
    static func parse(_ data: Data) -> JValue? {
        var i = 0
        let bytes = [UInt8](data)
        return value(bytes, &i)
    }

    static func skipWS(_ b: [UInt8], _ i: inout Int) {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
        }
    }

    static func value(_ b: [UInt8], _ i: inout Int) -> JValue? {
        skipWS(b, &i)
        guard i < b.count else { return nil }
        switch b[i] {
        case UInt8(ascii: "{"): return object(b, &i)
        case UInt8(ascii: "["): return array(b, &i)
        case UInt8(ascii: "\""): return .string(string(b, &i))
        case UInt8(ascii: "t"):
            i += 4; return .bool(true)
        case UInt8(ascii: "f"):
            i += 5; return .bool(false)
        case UInt8(ascii: "n"):
            i += 4; return .null
        default: return number(b, &i)
        }
    }

    static func object(_ b: [UInt8], _ i: inout Int) -> JValue? {
        i += 1
        var pairs: [(String, JValue)] = []
        skipWS(b, &i)
        if i < b.count && b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
        while i < b.count {
            skipWS(b, &i)
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { return nil }
            let k = string(b, &i)
            skipWS(b, &i)
            guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            guard let v = value(b, &i) else { return nil }
            pairs.append((k, v))
            skipWS(b, &i)
            guard i < b.count else { return nil }
            if b[i] == UInt8(ascii: ",") { i += 1 }
            else if b[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            else { return nil }
        }
        return nil
    }

    static func array(_ b: [UInt8], _ i: inout Int) -> JValue? {
        i += 1
        var items: [JValue] = []
        skipWS(b, &i)
        if i < b.count && b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while i < b.count {
            guard let v = value(b, &i) else { return nil }
            items.append(v)
            skipWS(b, &i)
            guard i < b.count else { return nil }
            if b[i] == UInt8(ascii: ",") { i += 1 }
            else if b[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            else { return nil }
        }
        return nil
    }

    static func string(_ b: [UInt8], _ i: inout Int) -> String {
        i += 1
        var out = [UInt8]()
        out.reserveCapacity(32)
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < b.count else { break }
                switch b[i] {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    let scalars = [b.get4Hex(i + 1), b.get4Hex(min(i + 6, b.count - 4))].compactMap { $0 }
                    if let hi = scalars.first {
                        if (0xD800...0xDBFF).contains(hi), scalars.count > 1, (0xDC00...0xDFFF).contains(scalars[1]) {
                            let cp = 0x10000 + ((hi - 0xD800) << 10) + (scalars[1] - 0xDC00)
                            out.append(contentsOf: utf8(cp)); i += 10
                        } else { out.append(contentsOf: utf8(hi)); i += 6 }
                    } else { i += 2 }
                default: out.append(b[i])
                }
                i += 1
            } else {
                out.append(c); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func utf8(_ cp: Int) -> [UInt8] {
        guard let scalar = UnicodeScalar(cp) else { return [] }
        return Array(String(scalar).utf8)
    }

    static func number(_ b: [UInt8], _ i: inout Int) -> JValue? {
        let start = i
        while i < b.count {
            let c = b[i]
            if (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
                || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { i += 1 } else { break }
        }
        guard i > start, let s = String(bytes: b[start..<i], encoding: .utf8), let d = Double(s) else { return nil }
        return .number(d)
    }
}

extension [UInt8] {
    /// 解析 i 处开始的 4 位 hex（供 \u 转义）
    func get4Hex(_ i: Int) -> Int? {
        guard i + 3 < count else { return nil }
        var v = 0
        for k in i...(i + 3) {
            let c = self[k]
            let d: Int
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = Int(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = Int(c - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = Int(c - UInt8(ascii: "A")) + 10
            default: return nil
            }
            v = v * 16 + d
        }
        return v
    }
}

// MARK: - usage 提取（逐字段对应 web 版已验证规则）

enum Extractor {
    static func num(_ v: JValue?) -> Double {
        guard let n = v?.num, n.isFinite else { return 0 }
        return n
    }

    /// 对应 web readUsageFields
    static func readUsageFields(_ n: JValue?) -> UsageFields? {
        guard let o = n?.obj else { return nil }
        _ = o
        let pt = num(n?["prompt_tokens"]), it = num(n?["input_tokens"])
        let ct = num(n?["completion_tokens"]), ot = num(n?["output_tokens"])
        let tt = num(n?["total_tokens"])
        if !(tt > 0 || ((pt > 0 || it > 0) && (ct > 0 || ot > 0))) { return nil }
        let pd = n?["prompt_tokens_details"]
        let cd = n?["completion_tokens_details"]
        let cached = [num(pd?["cached_tokens"]), num(n?["cache_read_input_tokens"]),
                      num(n?["cached_tokens"]), num(n?["cache_read_tokens"]), num(n?["cache_creation_input_tokens"])].max() ?? 0
        let reasoning = [num(cd?["reasoning_tokens"]), num(n?["reasoning_tokens"]), num(n?["reasoning_output_tokens"])].max() ?? 0
        let input = pt > 0 ? pt : it
        let output = ct > 0 ? ct : ot
        return UsageFields(input: input, output: output, cached: cached, reasoning: reasoning, total: tt > 0 ? tt : input + output)
    }

    static func hasKey(_ n: JValue?, _ keys: [String]) -> Bool {
        guard let o = n?.obj else { return false }
        for (k, _) in o where keys.contains(k) { return true }
        return false
    }

    /// 对应 web findUsageNodes：递归 + 签名去重 + codex 累计/增量处理
    /// 注: JValue 为值类型无环引用, 不做节点身份去重
    static func findUsageNodes(_ root: JValue?) -> [UsageFields] {
        var out: [UsageFields] = []
        var bySig = Set<String>()
        func add(_ u: UsageFields) {
            let sig = "\(u.input)/\(u.output)/\(u.cached)/\(u.reasoning)/\(u.total)"
            if !bySig.contains(sig) { bySig.insert(sig); out.append(u) }
        }
        func walk(_ node: JValue?, depth: Int) {
            guard let n = node, depth <= 6 else { return }
            switch n {
            case .array(let items):
                for it in items { walk(it, depth: depth + 1) }
            case .object:
                if let u = readUsageFields(n) {
                    if hasKey(n, ["total_token_usage", "total_tokens_usage"]) {
                        if hasKey(n, ["last_token_usage", "last_tokens_usage"]) {
                            if let last = readUsageFields(n["last_token_usage"] ?? n["last_tokens_usage"]) {
                                add(last); return
                            }
                        }
                    }
                    add(u)
                    return
                }
                if let o = n.obj {
                    for (_, v) in o { walk(v, depth: depth + 1) }
                }
            default: break
            }
        }
        walk(root, depth: 0)
        return out
    }

    /// 对应 web pickTs
    static func pickTs(_ obj: JValue?) -> Double {
        guard let o = obj?.obj else { return 0 }
        let keys = ["startedAt", "started_at", "timestamp", "created_at", "createdAt", "ts", "time"]
        for (k, v) in o where keys.contains(k) {
            if let d = v.num, d > 1e9 { return d < 1e12 ? d * 1000 : d }
            if let s = v.str, s.count >= 10, s.prefix(4).allSatisfy({ $0.isNumber }), s.contains("-") {
                if let t = isoDate(s) { return t }
            }
        }
        return 0
    }

    /// 解析 "2026-10-28T10:53:00" 类 ISO 时间（毫秒，按本地时区，与 JS Date.parse 行为对齐）
    static func isoDate(_ s: String) -> Double? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        guard let d = f.date(from: String(s.prefix(19))) else { return nil }
        return d.timeIntervalSince1970 * 1000
    }

    /// 对应 web pickModel
    static func pickModel(_ obj: JValue?) -> String {
        let keys = ["model", "model_name", "modelSlug", "model_id"]
        if let o = obj?.obj {
            for (k, v) in o where keys.contains(k) {
                if let s = v.str, !s.isEmpty { return s }
            }
        }
        for p in ["providerData", "provider_data", "message", "response", "data"] {
            if let sub = obj?[p], case .object = sub {
                if let o = sub.obj {
                    for (k, v) in o where keys.contains(k) {
                        if let s = v.str, !s.isEmpty { return s }
                    }
                }
            }
        }
        return ""
    }

    static func findModelNear(_ node: JValue?) -> String {
        guard let o = node?.obj else { return "" }
        for (k, v) in o where ["model", "model_name", "modelSlug", "model_id"].contains(k) {
            if let s = v.str, !s.isEmpty { return s }
        }
        return ""
    }
}
