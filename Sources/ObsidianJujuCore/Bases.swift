import Foundation

// MARK: - Results sent to the renderer

/// A rendered cell value. `t` is the kind: null, bool, num, str, date, list, link, image.
public struct BaseCell: Encodable, Sendable {
    public var t: String
    public var text: String = ""
    public var path: String?
    public var bool: Bool?
    public var items: [BaseCell]?

    static let null = BaseCell(t: "null")

    init(t: String, text: String = "", path: String? = nil, bool: Bool? = nil, items: [BaseCell]? = nil) {
        self.t = t; self.text = text; self.path = path; self.bool = bool; self.items = items
    }

    init(_ v: BaseValue, resolveImage: (String) -> String?) {
        switch v {
        case .null: self = .null
        case .bool(let b): self.init(t: "bool", text: b ? "true" : "false", bool: b)
        case .number: self.init(t: "num", text: v.text)
        case .date: self.init(t: "date", text: v.text)
        case .list(let l): self.init(t: "list", text: v.text, items: l.map { BaseCell($0, resolveImage: resolveImage) })
        case .link(let p, let d): self.init(t: "link", text: d, path: p)
        case .file(let p): self.init(t: "link", text: v.text, path: p)
        case .image(let s): self.init(t: "image", text: s, path: resolveImage(s))
        default: self.init(t: "str", text: v.text)
        }
    }
}

public struct BaseColumn: Encodable, Sendable {
    public let id: String
    public let name: String
}

public struct BaseRow: Encodable, Sendable {
    public let path: String
    public let cells: [BaseCell]
    /// Cards view cover image (vault path or URL).
    public var image: BaseCell?
}

public struct BaseGroup: Encodable, Sendable {
    public let key: BaseCell?
    public let rows: [BaseRow]
}

public struct BaseViewResult: Encodable, Sendable {
    public let name: String
    public let type: String
    public let columns: [BaseColumn]
    public let groups: [BaseGroup]
    public let total: Int
    /// Summary text per column ("" when none).
    public let summaries: [String]
    public let error: String?
}

public struct BaseResult: Encodable, Sendable {
    public let views: [BaseViewResult]
    /// Index of the view to show first (from a `#View name` subpath).
    public let selected: Int
    public let error: String?
}

// MARK: - Data the engine reads

/// One file as Bases sees it.
struct BaseFileInfo {
    let file: VaultFile
    let record: NoteRecord?
}

struct BaseEnvironment {
    let files: [String: VaultFile]
    let records: [String: NoteRecord]
    let resolver: LinkResolver
    let now: Date

    func info(_ path: String) -> BaseFileInfo? {
        guard let f = files[path] else { return nil }
        return BaseFileInfo(file: f, record: records[path])
    }
}

// MARK: - Evaluation

/// Evaluates expressions for one row (`file`) with `this` and the base's formulas.
final class BaseEvaluator {
    let env: BaseEnvironment
    let formulas: [String: Result<BaseExpr, BaseSyntaxError>]
    let row: BaseFileInfo
    let this: BaseFileInfo?
    private var formulaCache: [String: BaseValue] = [:]
    private var evaluating: Set<String> = []
    private var locals: [String: BaseValue] = [:]

    init(env: BaseEnvironment, formulas: [String: Result<BaseExpr, BaseSyntaxError>], row: BaseFileInfo, this: BaseFileInfo?) {
        self.env = env; self.formulas = formulas; self.row = row; self.this = this
    }

    struct EvalError: Error { let message: String }

    func eval(_ e: BaseExpr) throws -> BaseValue {
        switch e {
        case .literal(let v): return v
        case .list(let items): return .list(try items.map(eval))
        case .ident(let name): return try identifier(name)
        case .member(let base, let name): return try member(base, name)
        case .index(let base, let idx):
            let key = try eval(idx)
            if case .ident(let ns) = base, ["note", "formula", "file", "this"].contains(ns) {
                return try namespaced(ns, key.text)
            }
            return index(try eval(base), key)
        case .unary(let op, let x):
            let v = try eval(x)
            switch op {
            case "!": return .bool(!v.isTruthy)
            case "-": return v.numberValue.map { .number(-$0) } ?? .null
            default: return v.numberValue.map { .number($0) } ?? .null
            }
        case .binary(let op, let l, let r): return try binary(op, l, r)
        case .call(let callee, let args): return try call(callee, args)
        }
    }

    // Identifiers and property access

    private func identifier(_ name: String) throws -> BaseValue {
        if let v = locals[name] { return v }
        switch name {
        case "file": return .file(row.file.path)
        case "note": return .object(row.record?.properties.map { ($0.key, propertyValue($0.value)) } ?? [])
        case "this": return this.map { .file($0.file.path) } ?? .null
        default: return noteProperty(row, name)
        }
    }

    private func member(_ base: BaseExpr, _ name: String) throws -> BaseValue {
        if case .ident(let ns) = base, locals[ns] == nil {
            switch ns {
            case "note", "formula", "file": return try namespaced(ns, name)
            case "this":
                guard let t = this else { return .null }
                if name == "file" { return .file(t.file.path) }
                return noteProperty(t, name)
            default: break
            }
        }
        return field(try eval(base), name)
    }

    /// `note.x`, `formula.x`, `file.x`, `this.x`, also via property ids like "note.front tire pressure".
    func namespaced(_ ns: String, _ name: String) throws -> BaseValue {
        switch ns {
        case "note": return noteProperty(row, name)
        case "formula": return try formula(name)
        case "file": return fileField(row, name)
        case "this":
            guard let t = this else { return .null }
            return name == "file" ? .file(t.file.path) : noteProperty(t, name)
        default: return .null
        }
    }

    func formula(_ name: String) throws -> BaseValue {
        if let v = formulaCache[name] { return v }
        guard let parsed = formulas[name] else { return .null }
        guard !evaluating.contains(name) else { throw EvalError(message: "Formula “\(name)” refers to itself") }
        evaluating.insert(name)
        defer { evaluating.remove(name) }
        let expr: BaseExpr
        switch parsed {
        case .success(let e): expr = e
        case .failure(let err): throw EvalError(message: err.description)
        }
        let saved = locals
        locals = [:]
        defer { locals = saved }
        let v = try eval(expr)
        formulaCache[name] = v
        return v
    }

    func noteProperty(_ info: BaseFileInfo, _ name: String) -> BaseValue {
        guard let props = info.record?.properties else { return .null }
        let prop = props.first { $0.key == name } ?? props.first { $0.key.lowercased() == name.lowercased() }
        return prop.map { propertyValue($0.value, source: info.file.path) } ?? .null
    }

    /// Frontmatter text → typed value (numbers, booleans, dates and [[links]] are recognised).
    func propertyValue(_ v: PropertyValue, source: String? = nil) -> BaseValue {
        let src = source ?? row.file.path
        switch v {
        case .text(let s): return infer(s, source: src)
        case .list(let items): return .list(items.map { infer($0, source: src) })
        }
    }

    func infer(_ s: String, source: String) -> BaseValue {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .null }
        if t == "true" { return .bool(true) }
        if t == "false" { return .bool(false) }
        if let n = Double(t), t.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil { return .number(n) }
        if let d = BaseDates.parse(t) { return .date(d.0, hasTime: d.1) }
        if t.hasPrefix("[["), t.hasSuffix("]]") {
            let inner = NoteParser.parseWikiInner(String(t.dropFirst(2).dropLast(2)))
            let path = env.resolver.resolve(inner.target, from: source)
            return .link(path: path, display: inner.alias ?? inner.target)
        }
        return .string(s)
    }

    func fileField(_ info: BaseFileInfo, _ name: String) -> BaseValue {
        let f = info.file
        switch name {
        case "name": return .string(f.name)
        case "basename": return .string(f.basename)
        case "path": return .string(f.path)
        case "folder": return .string(f.folder)
        case "ext": return .string(f.ext)
        case "size": return .number(Double(f.size))
        case "mtime": return .date(Date(timeIntervalSince1970: f.mtime), hasTime: true)
        case "ctime": return .date(Date(timeIntervalSince1970: f.ctime), hasTime: true)
        case "tags": return .list((info.record?.tags ?? []).map { .string("#" + $0) })
        case "links":
            return .list((info.record?.links ?? []).filter { !$0.isEmbed }.map { link($0, from: f.path) })
        case "embeds":
            return .list((info.record?.links ?? []).filter(\.isEmbed).map { link($0, from: f.path) })
        case "backlinks":
            let sources = env.records.values.filter { r in
                r.path != f.path && r.links.contains { env.resolver.resolve($0.target, from: r.path) == f.path }
            }.map(\.path).sorted()
            return .list(sources.map { .file($0) })
        case "properties":
            return .object(info.record?.properties.map { ($0.key, propertyValue($0.value, source: f.path)) } ?? [])
        case "file": return .file(f.path)
        default: return .null
        }
    }

    private func link(_ l: LinkRef, from source: String) -> BaseValue {
        .link(path: env.resolver.resolve(l.target, from: source), display: l.alias ?? (l.target.isEmpty ? (l.subpath ?? "") : l.target))
    }

    func field(_ v: BaseValue, _ name: String) -> BaseValue {
        switch (v, name) {
        case (.file(let p), _):
            guard let info = env.info(p) else { return .null }
            return fileField(info, name)
        case (.link(let p, _), _):
            guard let p, let info = env.info(p) else { return .null }
            return name == "file" ? .file(p) : fileField(info, name)
        case (.string(let s), "length"): return .number(Double(s.count))
        case (.list(let l), "length"): return .number(Double(l.count))
        case (.date(let d, _), _):
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: d)
            switch name {
            case "year": return .number(Double(c.year ?? 0))
            case "month": return .number(Double(c.month ?? 0))
            case "day": return .number(Double(c.day ?? 0))
            case "hour": return .number(Double(c.hour ?? 0))
            case "minute": return .number(Double(c.minute ?? 0))
            case "second": return .number(Double(c.second ?? 0))
            case "millisecond": return .number(Double((c.nanosecond ?? 0) / 1_000_000))
            default: return .null
            }
        case (.object(let o), _): return o.first { $0.0 == name }?.1 ?? .null
        default: return .null
        }
    }

    func index(_ v: BaseValue, _ key: BaseValue) -> BaseValue {
        switch v {
        case .list(let l):
            guard let n = key.numberValue else { return .null }
            let i = Int(n) < 0 ? l.count + Int(n) : Int(n)
            return l.indices.contains(i) ? l[i] : .null
        case .string(let s):
            guard let n = key.numberValue, Int(n) >= 0, Int(n) < s.count else { return .null }
            return .string(String(s[s.index(s.startIndex, offsetBy: Int(n))]))
        case .object(let o): return o.first { $0.0 == key.text }?.1 ?? .null
        default: return field(v, key.text)
        }
    }

    // Operators

    private func binary(_ op: String, _ l: BaseExpr, _ r: BaseExpr) throws -> BaseValue {
        if op == "&&" { let a = try eval(l); return a.isTruthy ? try eval(r) : a }
        if op == "||" { let a = try eval(l); return a.isTruthy ? a : try eval(r) }
        let a = try eval(l), b = try eval(r)
        switch op {
        case "==": return .bool(BaseValue.equals(a, b))
        case "!=": return .bool(!BaseValue.equals(a, b))
        case "<", ">", "<=", ">=":
            guard let c = BaseValue.compare(a, b) else { return .bool(false) }
            switch op {
            case "<": return .bool(c < 0)
            case ">": return .bool(c > 0)
            case "<=": return .bool(c <= 0)
            default: return .bool(c >= 0)
            }
        case "+", "-":
            let sign: Double = op == "+" ? 1 : -1
            if case .date(let d, let t) = a {
                if case .date(let d2, _) = b, op == "-" { return .number((d.timeIntervalSince1970 - d2.timeIntervalSince1970) * 1000) }
                if case .duration(let dur) = b { return .date(dur.applied(to: d, sign: sign), hasTime: t || dur.seconds.truncatingRemainder(dividingBy: 86400) != 0) }
                if case .string(let s) = b, let dur = BaseDuration.parse(s) {
                    return .date(dur.applied(to: d, sign: sign), hasTime: t || dur.seconds.truncatingRemainder(dividingBy: 86400) != 0)
                }
                if let n = b.numberValue { return .date(d.addingTimeInterval(sign * n / 1000), hasTime: true) }
            }
            if op == "+" {
                if case .list(let x) = a { return .list(x + (b.items)) }
                if case .string = a { return .string(a.text + b.text) }
                if case .string = b { return .string(a.text + b.text) }
            }
            guard let x = a.numberValue, let y = b.numberValue else { return .null }
            return .number(x + sign * y)
        case "*", "/", "%":
            guard let x = a.numberValue, let y = b.numberValue else { return .null }
            switch op {
            case "*": return .number(x * y)
            case "/": return y == 0 ? .null : .number(x / y)
            default: return y == 0 ? .null : .number(x.truncatingRemainder(dividingBy: y))
            }
        default:
            throw EvalError(message: "Unknown operator \(op)")
        }
    }

    // Calls

    private func call(_ callee: BaseExpr, _ args: [BaseExpr]) throws -> BaseValue {
        if case .ident(let name) = callee { return try global(name, args) }
        if case .member(let base, let method) = callee {
            // file.hasTag() etc. on the row's file without evaluating `file` as a value first.
            let target = try eval(base)
            return try method_(target, method, args)
        }
        throw EvalError(message: "Not a function")
    }

    private func global(_ name: String, _ args: [BaseExpr]) throws -> BaseValue {
        func arg(_ i: Int) throws -> BaseValue { i < args.count ? try eval(args[i]) : .null }
        switch name {
        case "if":
            return try arg(0).isTruthy ? try arg(1) : try arg(2)
        case "now": return .date(env.now, hasTime: true)
        case "today": return .date(Calendar.current.startOfDay(for: env.now), hasTime: false)
        case "date":
            let v = try arg(0)
            if case .date = v { return v }
            return BaseDates.parse(v.text).map { .date($0.0, hasTime: $0.1) } ?? .null
        case "duration": return BaseDuration.parse(try arg(0).text).map { .duration($0) } ?? .null
        case "number":
            let v = try arg(0)
            if case .date(let d, _) = v { return .number(d.timeIntervalSince1970 * 1000) }
            return v.numberValue.map { .number($0) } ?? .null
        case "list":
            let v = try arg(0)
            if case .list = v { return v }
            return v.isEmptyValue ? .list([]) : .list([v])
        case "link":
            let v = try arg(0)
            let display = args.count > 1 ? try arg(1).text : nil
            switch v {
            case .file(let p): return .link(path: p, display: display ?? BaseValue.file(p).text)
            case .link(let p, let d): return .link(path: p, display: display ?? d)
            default:
                let path = env.resolver.resolve(v.text, from: row.file.path)
                return .link(path: path, display: display ?? v.text)
            }
        case "file":
            let v = try arg(0)
            if case .file = v { return v }
            if case .link(let p, _) = v { return p.map { .file($0) } ?? .null }
            return env.resolver.resolve(v.text, from: row.file.path).map { .file($0) } ?? .null
        case "image": return .image(try arg(0).text)
        case "icon": return .string("")
        case "html", "escapeHTML": return .string(try arg(0).text)
        case "max", "min":
            let nums = try args.map(eval).flatMap { $0.items }.compactMap(\.numberValue)
            guard !nums.isEmpty else { return .null }
            return .number(name == "max" ? nums.max()! : nums.min()!)
        case "random": return .number(Double.random(in: 0..<1))
        default:
            throw EvalError(message: "Unknown function \(name)()")
        }
    }

    private func method_(_ v: BaseValue, _ name: String, _ args: [BaseExpr]) throws -> BaseValue {
        func arg(_ i: Int) throws -> BaseValue { i < args.count ? try eval(args[i]) : .null }
        func allArgs() throws -> [BaseValue] { try args.map(eval).flatMap { $0.items } }

        // Any type
        switch name {
        case "isTruthy": return .bool(v.isTruthy)
        case "isType": return .bool(v.typeName == (try arg(0)).text.lowercased())
        case "toString": return .string(v.text)
        case "isEmpty": return .bool(v.isEmptyValue)
        default: break
        }

        switch v {
        case .file(let p), .link(.some(let p), _):
            guard let info = env.info(p) else { return .null }
            switch name {
            case "hasTag":
                let wanted = try allArgs().map { $0.text.hasPrefix("#") ? String($0.text.dropFirst()) : $0.text }.map { $0.lowercased() }
                let tags = (info.record?.tags ?? []).map { $0.lowercased() }
                return .bool(wanted.contains { w in tags.contains { $0 == w || $0.hasPrefix(w + "/") } })
            case "inFolder":
                let folder = try arg(0).text.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                let own = info.file.folder.lowercased()
                return .bool(folder.isEmpty || own == folder || own.hasPrefix(folder + "/"))
            case "hasProperty":
                let key = try arg(0).text
                return .bool(info.record?.properties.contains { $0.key == key } ?? false)
            case "hasLink", "linksTo":
                let other = try arg(0)
                let target: String?
                switch other {
                case .file(let o): target = o
                case .link(let o, _): target = o
                default: target = env.resolver.resolve(other.text, from: p)
                }
                if case .link = v, name == "linksTo" { return .bool(p == target) }
                guard let target else { return .bool(false) }
                return .bool(info.record?.links.contains { env.resolver.resolve($0.target, from: p) == target } ?? false)
            case "asLink":
                return .link(path: p, display: args.isEmpty ? BaseValue.file(p).text : try arg(0).text)
            case "asFile": return .file(p)
            default: break
            }
        case .string(let s):
            let lower = s.lowercased()
            switch name {
            case "contains": return .bool(s.contains(try arg(0).text))
            case "containsAll": return .bool(try allArgs().allSatisfy { s.contains($0.text) })
            case "containsAny": return .bool(try allArgs().contains { s.contains($0.text) })
            case "startsWith": return .bool(s.hasPrefix(try arg(0).text))
            case "endsWith": return .bool(s.hasSuffix(try arg(0).text))
            case "lower": return .string(lower)
            case "upper": return .string(s.uppercased())
            case "title": return .string(s.capitalized)
            case "trim": return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
            case "reverse": return .string(String(s.reversed()))
            case "repeat": return .string(String(repeating: s, count: max(0, Int(try arg(0).numberValue ?? 0))))
            case "slice":
                let chars = Array(s)
                let r = sliceRange(chars.count, try arg(0), args.count > 1 ? try arg(1) : nil)
                return .string(String(chars[r]))
            case "replace":
                let pattern = try arg(0)
                let replacement = try arg(1).text
                if case .regex(let re) = pattern {
                    return .string(s.replacingOccurrences(of: re, with: replacement.replacingOccurrences(of: "$", with: "$"), options: .regularExpression))
                }
                return .string(s.replacingOccurrences(of: pattern.text, with: replacement))
            case "split":
                let sep = try arg(0)
                var parts: [String]
                if case .regex(let re) = sep {
                    parts = s.replacingOccurrences(of: re, with: "\u{1}", options: .regularExpression).components(separatedBy: "\u{1}")
                } else {
                    parts = sep.text.isEmpty ? s.map(String.init) : s.components(separatedBy: sep.text)
                }
                if args.count > 1, let n = try arg(1).numberValue { parts = Array(parts.prefix(Int(n))) }
                return .list(parts.map { .string($0) })
            case "matches": return .bool(false)
            default: break
            }
        case .number(let n):
            switch name {
            case "abs": return .number(abs(n))
            case "ceil": return .number(n.rounded(.up))
            case "floor": return .number(n.rounded(.down))
            case "round":
                let digits = try arg(0).numberValue ?? 0
                let f = pow(10, digits)
                return .number((n * f).rounded() / f)
            case "toFixed": return .string(String(format: "%.\(Int(try arg(0).numberValue ?? 0))f", n))
            default: break
            }
        case .date(let d, let hasTime):
            switch name {
            case "date": return .date(Calendar.current.startOfDay(for: d), hasTime: false)
            case "format": return .string(BaseDates.format(d, pattern: try arg(0).text))
            case "time": return .string(BaseDates.format(d, pattern: "HH:mm:ss"))
            case "relative":
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .full
                return .string(f.localizedString(for: d, relativeTo: env.now))
            default: _ = hasTime
            }
        case .list(let l):
            switch name {
            case "contains":
                let x = try arg(0)
                return .bool(l.contains { BaseValue.equals($0, x) })
            case "containsAll": return .bool(try args.map(eval).allSatisfy { x in l.contains { BaseValue.equals($0, x) } })
            case "containsAny": return .bool(try args.map(eval).contains { x in l.contains { BaseValue.equals($0, x) } })
            case "join": return .string(l.map(\.text).joined(separator: args.isEmpty ? "," : try arg(0).text))
            case "reverse": return .list(l.reversed())
            case "sort": return .list(l.sorted { (BaseValue.compare($0, $1) ?? 0) < 0 })
            case "unique":
                var out: [BaseValue] = []
                for x in l where !out.contains(where: { BaseValue.equals($0, x) }) { out.append(x) }
                return .list(out)
            case "flat": return .list(l.flatMap { $0.items })
            case "slice":
                let r = sliceRange(l.count, try arg(0), args.count > 1 ? try arg(1) : nil)
                return .list(Array(l[r]))
            case "filter", "map":
                guard let body = args.first else { return v }
                var out: [BaseValue] = []
                let saved = locals
                defer { locals = saved }
                for (i, x) in l.enumerated() {
                    locals["value"] = x
                    locals["index"] = .number(Double(i))
                    let r = try eval(body)
                    if name == "map" { out.append(r) } else if r.isTruthy { out.append(x) }
                }
                return .list(out)
            case "reduce":
                guard let body = args.first else { return .null }
                var acc = args.count > 1 ? try eval(args[1]) : .null
                let saved = locals
                defer { locals = saved }
                for (i, x) in l.enumerated() {
                    locals["value"] = x
                    locals["index"] = .number(Double(i))
                    locals["acc"] = acc
                    acc = try eval(body)
                }
                return acc
            // Summary helpers on lists of values.
            case "mean", "average":
                let n = l.compactMap(\.numberValue)
                return n.isEmpty ? .null : .number(n.reduce(0, +) / Double(n.count))
            case "sum": return .number(l.compactMap(\.numberValue).reduce(0, +))
            case "min": return l.compactMap(\.numberValue).min().map { .number($0) } ?? .null
            case "max": return l.compactMap(\.numberValue).max().map { .number($0) } ?? .null
            default: break
            }
        case .object(let o):
            switch name {
            case "keys": return .list(o.map { .string($0.0) })
            case "values": return .list(o.map(\.1))
            default: break
            }
        case .regex(let re):
            if name == "matches" {
                return .bool((try arg(0)).text.range(of: re, options: .regularExpression) != nil)
            }
        default:
            break
        }
        if case .null = v { return .null }
        throw EvalError(message: "\(v.typeName) has no function \(name)()")
    }

    func withLocal<T>(_ key: String, _ value: BaseValue, _ body: () throws -> T) rethrows -> T {
        let saved = locals
        locals[key] = value
        defer { locals = saved }
        return try body()
    }

    private func sliceRange(_ count: Int, _ start: BaseValue, _ end: BaseValue?) -> Range<Int> {
        func clamp(_ x: Int) -> Int { min(max(x < 0 ? count + x : x, 0), count) }
        let s = clamp(Int(start.numberValue ?? 0))
        let e = end.flatMap(\.numberValue).map { clamp(Int($0)) } ?? count
        return s..<max(s, e)
    }
}

// MARK: - Base definition and engine

/// A parsed `.base` file or ```base block.
public struct BaseDefinition {
    public enum Filter {
        case statement(String)
        case and([Filter])
        case or([Filter])
        case not([Filter])
    }

    public struct View {
        public var type = "table"
        public var name = ""
        public var filters: Filter?
        public var order: [String] = []
        public var sort: [(property: String, ascending: Bool)] = []
        public var groupBy: (property: String, ascending: Bool)?
        public var limit: Int?
        public var summaries: [String: String] = [:]
        public var image: String?
    }

    public var filters: Filter?
    public var formulas: [String: String] = [:]
    public var displayNames: [String: String] = [:]
    public var summaries: [String: String] = [:]
    public var views: [View] = []

    public init(yaml: String) {
        let root = YAMLLite.parse(yaml)
        filters = root["filters"].flatMap(Self.filter)
        for (k, v) in root["formulas"]?.pairs ?? [] { formulas[k] = v.string ?? "" }
        for (k, v) in root["properties"]?.pairs ?? [] {
            if let name = v["displayName"]?.string { displayNames[Self.normalize(k)] = name }
        }
        for (k, v) in root["summaries"]?.pairs ?? [] { summaries[k] = v.string ?? "" }
        for item in root["views"]?.items ?? [] {
            var view = View()
            view.type = item["type"]?.string ?? "table"
            view.name = item["name"]?.string ?? ""
            view.filters = item["filters"].flatMap(Self.filter)
            view.order = (item["order"]?.items ?? []).compactMap(\.string).map(Self.normalize)
            view.sort = (item["sort"]?.items ?? []).compactMap { s in
                guard let p = s["property"]?.string ?? s.string else { return nil }
                return (Self.normalize(p), (s["direction"]?.string ?? "ASC").uppercased() != "DESC")
            }
            if let g = item["groupBy"], let p = g["property"]?.string ?? g.string {
                view.groupBy = (Self.normalize(p), (g["direction"]?.string ?? "ASC").uppercased() != "DESC")
            }
            view.limit = item["limit"]?.string.flatMap { Int($0) }
            for (k, v) in item["summaries"]?.pairs ?? [] { view.summaries[Self.normalize(k)] = v.string ?? "" }
            view.image = item["image"]?.string.map(Self.normalize)
            views.append(view)
        }
        if views.isEmpty { views = [View(type: "table", name: "Table")] }
    }

    /// Property ids are "note.x", "file.x", "formula.x"; a bare "x" means "note.x".
    static func normalize(_ id: String) -> String {
        let t = id.trimmingCharacters(in: .whitespaces)
        for ns in ["note.", "file.", "formula.", "this."] where t.hasPrefix(ns) { return t }
        return "note." + t
    }

    static func filter(_ v: YAMLValue) -> Filter? {
        switch v {
        case .scalar(let s): return .statement(s)
        case .list(let l): return .and(l.compactMap(filter))
        case .map:
            if let a = v["and"] { return .and(a.items.compactMap(filter)) }
            if let o = v["or"] { return .or(o.items.compactMap(filter)) }
            if let n = v["not"] { return .not(n.items.compactMap(filter)) }
            return nil
        case .null: return nil
        }
    }
}

enum BaseEngine {
    static func evaluate(yaml: String, thisPath: String?, viewName: String?, env: BaseEnvironment) -> BaseResult {
        let def = BaseDefinition(yaml: yaml)
        let formulas = def.formulas.mapValues { src in Result { try BaseParser.parse(src) }.mapError { $0 as? BaseSyntaxError ?? BaseSyntaxError(description: "\($0)") } }
        var parsedStatements: [String: Result<BaseExpr, BaseSyntaxError>] = [:]
        func statement(_ s: String) -> Result<BaseExpr, BaseSyntaxError> {
            if let r = parsedStatements[s] { return r }
            let r = Result { try BaseParser.parse(s) }.mapError { $0 as? BaseSyntaxError ?? BaseSyntaxError(description: "\($0)") }
            parsedStatements[s] = r
            return r
        }
        let this = thisPath.flatMap(env.info)
        let allFiles = env.files.values.sorted { $0.path < $1.path }

        var views: [BaseViewResult] = []
        for view in def.views {
            var errors: [String] = []
            func passes(_ f: BaseDefinition.Filter?, _ ev: BaseEvaluator) -> Bool {
                guard let f else { return true }
                switch f {
                case .statement(let s):
                    switch statement(s) {
                    case .success(let e):
                        do { return try ev.eval(e).isTruthy } catch {
                            if errors.count < 1 { errors.append((error as? BaseEvaluator.EvalError)?.message ?? "\(error)") }
                            return false
                        }
                    case .failure(let err):
                        if errors.count < 1 { errors.append(err.description) }
                        return false
                    }
                case .and(let l): return l.allSatisfy { passes($0, ev) }
                case .or(let l): return l.contains { passes($0, ev) }
                case .not(let l): return !l.contains { passes($0, ev) }
                }
            }

            var rows: [(info: BaseFileInfo, ev: BaseEvaluator)] = []
            for f in allFiles {
                let info = BaseFileInfo(file: f, record: env.records[f.path])
                let ev = BaseEvaluator(env: env, formulas: formulas, row: info, this: this)
                if passes(def.filters, ev) && passes(view.filters, ev) { rows.append((info, ev)) }
            }

            func value(_ id: String, _ ev: BaseEvaluator) -> BaseValue {
                guard let dot = id.firstIndex(of: ".") else { return .null }
                let ns = String(id[..<dot]), name = String(id[id.index(after: dot)...])
                return (try? ev.namespaced(ns, name)) ?? .null
            }

            // Sort: explicit sort keys, then file name for stability.
            rows.sort { a, b in
                for (prop, asc) in view.sort {
                    let x = value(prop, a.ev), y = value(prop, b.ev)
                    if case .null = x, case .null = y { continue }
                    if case .null = x { return false }   // empties last
                    if case .null = y { return true }
                    if let c = BaseValue.compare(x, y), c != 0 { return asc ? c < 0 : c > 0 }
                }
                return a.info.file.basename.localizedStandardCompare(b.info.file.basename) == .orderedAscending
            }
            let total = rows.count
            if let limit = view.limit, limit >= 0 { rows = Array(rows.prefix(limit)) }

            let columnIDs = view.order.isEmpty ? ["file.name"] : view.order
            let columns = columnIDs.map { BaseColumn(id: $0, name: displayName($0, def)) }
            func resolveImage(_ s: String) -> String? {
                if s.contains("://") { return nil }
                return env.resolver.resolve(s, from: thisPath ?? "")
            }
            func cell(_ id: String, _ row: (info: BaseFileInfo, ev: BaseEvaluator)) -> BaseCell {
                if id == "file.name" || id == "file.basename" {
                    // The name column links to the file, as in Obsidian.
                    let f = row.info.file
                    return BaseCell(t: "link", text: f.isNote ? f.basename : f.name, path: f.path)
                }
                return BaseCell(value(id, row.ev), resolveImage: resolveImage)
            }
            func makeRow(_ r: (info: BaseFileInfo, ev: BaseEvaluator)) -> BaseRow {
                var row = BaseRow(path: r.info.file.path, cells: columnIDs.map { cell($0, r) })
                if let img = view.image {
                    let v = value(img, r.ev)
                    switch v {
                    case .link(let p, _): row.image = p.map { BaseCell(t: "image", text: $0, path: $0) }
                    case .file(let p): row.image = BaseCell(t: "image", text: p, path: p)
                    case .null: break
                    default:
                        let s = v.text
                        row.image = BaseCell(t: "image", text: s, path: s.contains("://") ? nil : env.resolver.resolve(
                            s.hasPrefix("[[") ? NoteParser.parseWikiInner(String(s.dropFirst(2).dropLast(2))).target : s,
                            from: r.info.file.path))
                    }
                }
                return row
            }

            var groups: [BaseGroup] = []
            if let (prop, asc) = view.groupBy {
                var order: [String] = []
                var buckets: [String: (key: BaseValue, rows: [BaseRow])] = [:]
                for r in rows {
                    let k = value(prop, r.ev)
                    let key = k.text
                    if buckets[key] == nil { order.append(key); buckets[key] = (k, []) }
                    buckets[key]!.rows.append(makeRow(r))
                }
                order.sort { a, b in
                    let x = buckets[a]!.key, y = buckets[b]!.key
                    if case .null = x { return false }
                    if case .null = y { return true }
                    let c = BaseValue.compare(x, y) ?? 0
                    return asc ? c < 0 : c > 0
                }
                groups = order.map { BaseGroup(key: BaseCell(buckets[$0]!.key, resolveImage: resolveImage), rows: buckets[$0]!.rows) }
            } else {
                groups = [BaseGroup(key: nil, rows: rows.map(makeRow))]
            }

            let summaries = columnIDs.map { id -> String in
                guard let kind = view.summaries[id] else { return "" }
                let values = rows.map { value(id, $0.ev) }
                return summarize(kind, values, custom: def.summaries, env: env, sample: rows.first?.info)
            }

            views.append(BaseViewResult(name: view.name.isEmpty ? view.type.capitalized : view.name, type: view.type,
                                        columns: columns, groups: groups, total: total, summaries: summaries,
                                        error: errors.first))
        }
        let selected = viewName.flatMap { n in views.firstIndex { $0.name.lowercased() == n.lowercased() } } ?? 0
        return BaseResult(views: views, selected: selected, error: nil)
    }

    static func displayName(_ id: String, _ def: BaseDefinition) -> String {
        if let n = def.displayNames[id] { return n }
        if id.hasPrefix("note.") { return String(id.dropFirst(5)) }
        if id.hasPrefix("formula.") { return String(id.dropFirst(8)) }
        if id.hasPrefix("file.") { return "file " + id.dropFirst(5) }
        return id
    }

    static func summarize(_ kind: String, _ values: [BaseValue], custom: [String: String], env: BaseEnvironment,
                          sample: BaseFileInfo?) -> String {
        let nums = values.compactMap { v -> Double? in if case .null = v { return nil }; return v.numberValue }
        let dates = values.compactMap { v -> Date? in if case .date(let d, _) = v { return d }; return nil }
        func n(_ x: Double?) -> String { x.map { BaseValue.format(($0 * 1000).rounded() / 1000) } ?? "" }
        switch kind {
        case "Average": return nums.isEmpty ? "" : n(nums.reduce(0, +) / Double(nums.count))
        case "Sum": return n(nums.reduce(0, +))
        case "Min": return n(nums.min())
        case "Max": return n(nums.max())
        case "Range": return nums.isEmpty ? "" : n(nums.max()! - nums.min()!)
        case "Median":
            guard !nums.isEmpty else { return "" }
            let s = nums.sorted()
            return n(s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
        case "Stddev":
            guard nums.count > 1 else { return "" }
            let mean = nums.reduce(0, +) / Double(nums.count)
            return n((nums.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(nums.count)).squareRoot())
        case "Earliest": return dates.min().map { BaseValue.date($0, hasTime: false).text } ?? ""
        case "Latest": return dates.max().map { BaseValue.date($0, hasTime: false).text } ?? ""
        case "Checked": return String(values.filter { if case .bool(true) = $0 { return true }; return false }.count)
        case "Unchecked": return String(values.filter { if case .bool(true) = $0 { return false }; return true }.count)
        case "Empty": return String(values.filter(\.isEmptyValue).count)
        case "Filled": return String(values.filter { !$0.isEmptyValue }.count)
        case "Unique":
            return String(Set(values.filter { !$0.isEmptyValue }.map(\.text)).count)
        default:
            guard let src = custom[kind], let expr = try? BaseParser.parse(src), let sample else { return "" }
            let ev = BaseEvaluator(env: env, formulas: [:], row: sample, this: nil)
            return (try? ev.evalWithValues(expr, .list(values)).text) ?? ""
        }
    }
}

extension BaseEvaluator {
    /// Custom summaries see the column's values as `values`.
    func evalWithValues(_ e: BaseExpr, _ values: BaseValue) throws -> BaseValue {
        try withLocal("values", values) { try eval(e) }
    }
}
