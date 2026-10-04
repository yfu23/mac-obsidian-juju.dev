import Foundation

// MARK: - Values

/// A value in the Bases formula language.
public indirect enum BaseValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case date(Date, hasTime: Bool)
    case duration(BaseDuration)
    case list([BaseValue])
    /// A link: `path` is the resolved vault path (nil when unresolved), `display` the text to show.
    case link(path: String?, display: String)
    case file(String)
    case object([(String, BaseValue)])
    case image(String)
    case regex(String)

    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .list(let l): return !l.isEmpty
        case .object(let o): return !o.isEmpty
        default: return true
        }
    }

    /// A list's elements, nothing for null, or the value itself.
    var items: [BaseValue] {
        switch self {
        case .list(let l): return l
        case .null: return []
        default: return [self]
        }
    }

    public var isEmptyValue: Bool {
        switch self {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .list(let l): return l.isEmpty
        case .object(let o): return o.isEmpty
        default: return false
        }
    }

    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .date: return "date"
        case .duration: return "duration"
        case .list: return "list"
        case .link: return "link"
        case .file: return "file"
        case .object: return "object"
        case .image: return "image"
        case .regex: return "regexp"
        }
    }

    /// Display text, as Obsidian shows a value in a cell or when converted with toString().
    public var text: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return BaseValue.format(n)
        case .string(let s): return s
        case .date(let d, let hasTime): return BaseDates.format(d, pattern: hasTime ? "YYYY-MM-DD HH:mm" : "YYYY-MM-DD")
        case .duration(let d): return d.text
        case .list(let l): return l.map(\.text).joined(separator: ", ")
        case .link(_, let display): return display
        case .file(let p): return ((p as NSString).lastPathComponent as NSString).deletingPathExtension
        case .object(let o): return "{" + o.map { "\($0.0): \($0.1.text)" }.joined(separator: ", ") + "}"
        case .image(let s): return s
        case .regex(let r): return "/\(r)/"
        }
    }

    static func format(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.10g", n)
        if s.contains("e") { s = String(n) }
        return s
    }

    /// Number view of a value (numbers, numeric strings, booleans, dates as ms).
    var numberValue: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .date(let d, _): return d.timeIntervalSince1970 * 1000
        case .duration(let d): return d.milliseconds
        default: return nil
        }
    }

    /// Ordering used for sorting and `<`/`>`. nil when the two values aren't comparable.
    static func compare(_ a: BaseValue, _ b: BaseValue) -> Int? {
        switch (a, b) {
        case (.null, .null): return 0
        case (.date(let x, _), .date(let y, _)): return x < y ? -1 : (x > y ? 1 : 0)
        case (.number, _), (_, .number), (.bool, .bool):
            guard let x = a.numberValue, let y = b.numberValue else { return nil }
            return x < y ? -1 : (x > y ? 1 : 0)
        case (.date(let x, _), .string(let s)):
            guard let y = BaseDates.parse(s) else { return nil }
            return x < y.0 ? -1 : (x > y.0 ? 1 : 0)
        case (.string(let s), .date(let y, _)):
            guard let x = BaseDates.parse(s) else { return nil }
            return x.0 < y ? -1 : (x.0 > y ? 1 : 0)
        case (.null, _), (_, .null): return nil
        default:
            let r = a.text.localizedStandardCompare(b.text)
            return r == .orderedAscending ? -1 : (r == .orderedDescending ? 1 : 0)
        }
    }

    static func equals(_ a: BaseValue, _ b: BaseValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.null, _), (_, .null): return false
        case (.list(let x), .list(let y)): return x.count == y.count && zip(x, y).allSatisfy { equals($0, $1) }
        case (.link(let p, _), .file(let f)), (.file(let f), .link(let p, _)): return p == f
        case (.link(let p1, let d1), .link(let p2, let d2)): return p1 != nil ? p1 == p2 : d1 == d2
        case (.file(let x), .file(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        default:
            return compare(a, b) == 0
        }
    }
}

public struct BaseDuration: Sendable {
    public var months = 0
    public var seconds = 0.0

    var milliseconds: Double { (Double(months) * 30.4375 * 86400 + seconds) * 1000 }
    var text: String {
        var parts: [String] = []
        if months != 0 { parts.append("\(months) months") }
        if seconds != 0 { parts.append(BaseValue.format(seconds) + " seconds") }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    /// "1d", "2 hours", "1M 3d", "-1w"
    static func parse(_ s: String) -> BaseDuration? {
        let regex = try! NSRegularExpression(pattern: #"([+-]?\d+(?:\.\d+)?)\s*([a-zA-Z]+)"#)
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        // Everything must be consumed by matches (aside from spaces/commas).
        let leftover = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        guard leftover.trimmingCharacters(in: CharacterSet(charactersIn: " ,")).isEmpty else { return nil }
        var d = BaseDuration()
        for m in matches {
            let n = Double(ns.substring(with: m.range(at: 1)))!
            let unit = ns.substring(with: m.range(at: 2))
            switch unit {
            case "y", "year", "years", "Y": d.months += Int(n * 12)
            case "M", "month", "months": d.months += Int(n)
            case "w", "week", "weeks", "W": d.seconds += n * 7 * 86400
            case "d", "day", "days", "D": d.seconds += n * 86400
            case "h", "hour", "hours", "H": d.seconds += n * 3600
            case "m", "minute", "minutes": d.seconds += n * 60
            case "s", "second", "seconds", "S": d.seconds += n
            case "ms", "millisecond", "milliseconds": d.seconds += n / 1000
            default: return nil
            }
        }
        return d
    }

    func applied(to date: Date, sign: Double) -> Date {
        var out = date
        if months != 0 {
            out = Calendar.current.date(byAdding: .month, value: Int(sign) * months, to: out) ?? out
        }
        return out.addingTimeInterval(sign * seconds)
    }
}

enum BaseDates {
    /// Parses "YYYY-MM-DD", "YYYY-MM-DD HH:mm[:ss]" and "YYYY-MM-DDTHH:mm[:ss]" (local time).
    static func parse(_ s: String) -> (Date, Bool)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let regex = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?(?:Z|[+-]\d{2}:?\d{2})?$"#)
        let ns = t as NSString
        guard let m = regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func part(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i))) }
        var c = DateComponents()
        c.year = part(1); c.month = part(2); c.day = part(3)
        c.hour = part(4) ?? 0; c.minute = part(5) ?? 0; c.second = part(6) ?? 0
        guard let d = Calendar.current.date(from: c) else { return nil }
        return (d, part(4) != nil)
    }

    /// Formats with Moment.js tokens (YYYY, MM, DD, HH, mm, ss, ddd, MMMM, A, …; [literal] text).
    static func format(_ date: Date, pattern: String) -> String {
        let map: [(String, String)] = [
            ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
            ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"), ("dd", "EEEEEE"), ("d", "e"),
            ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"), ("ss", "ss"), ("s", "s"),
            ("SSS", "SSS"), ("A", "a"), ("a", "a"), ("ZZ", "xx"), ("Z", "xxx"), ("WW", "ww"), ("W", "w"), ("Q", "Q"),
        ]
        var out = ""
        var i = pattern.startIndex
        var literal = ""
        func flushLiteral() {
            if !literal.isEmpty { out += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"; literal = "" }
        }
        outer: while i < pattern.endIndex {
            if pattern[i] == "[" , let close = pattern[i...].firstIndex(of: "]") {
                literal += pattern[pattern.index(after: i)..<close]
                i = pattern.index(after: close)
                continue
            }
            for (moment, icu) in map where pattern[i...].hasPrefix(moment) {
                flushLiteral()
                out += icu
                i = pattern.index(i, offsetBy: moment.count)
                continue outer
            }
            let ch = pattern[i]
            if ch.isLetter { literal.append(ch) } else { flushLiteral(); out.append(ch == "'" ? "''" : String(ch)) }
            i = pattern.index(after: i)
        }
        flushLiteral()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = out
        return f.string(from: date)
    }
}

// MARK: - Syntax tree

public indirect enum BaseExpr: Sendable {
    case literal(BaseValue)
    case ident(String)
    case member(BaseExpr, String)
    case index(BaseExpr, BaseExpr)
    case call(BaseExpr, [BaseExpr])
    case unary(String, BaseExpr)
    case binary(String, BaseExpr, BaseExpr)
    case list([BaseExpr])
}

public struct BaseSyntaxError: Error, CustomStringConvertible, Sendable {
    public let description: String
}

/// Parser for Bases formulas and filter statements (a JavaScript-like expression language).
public enum BaseParser {
    enum Token: Equatable {
        case number(Double), string(String), ident(String), op(String), regex(String), end
    }

    public static func parse(_ source: String) throws -> BaseExpr {
        var p = Pratt(tokens: try tokenize(source))
        let e = try p.expression(0)
        guard p.peek == .end else { throw BaseSyntaxError(description: "Unexpected \(p.describe(p.peek)) in “\(source)”") }
        return e
    }

    static func tokenize(_ s: String) throws -> [Token] {
        var out: [Token] = []
        let chars = Array(s)
        var i = 0
        let ops3 = ["===", "!=="]
        let ops2 = ["==", "!=", ">=", "<=", "&&", "||"]
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                out.append(.number(Double(String(chars[i..<j])) ?? 0))
                i = j
                continue
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                var str = ""
                while j < chars.count, chars[j] != c {
                    if chars[j] == "\\", j + 1 < chars.count {
                        j += 1
                        switch chars[j] { case "n": str.append("\n"); case "t": str.append("\t"); default: str.append(chars[j]) }
                    } else {
                        str.append(chars[j])
                    }
                    j += 1
                }
                guard j < chars.count else { throw BaseSyntaxError(description: "Unterminated string in “\(s)”") }
                out.append(.string(str))
                i = j + 1
                continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" { j += 1 }
                out.append(.ident(String(chars[i..<j])))
                i = j
                continue
            }
            // Regex literal: /pattern/flags where a value can't precede it.
            if c == "/" {
                let prevIsValue: Bool
                switch out.last {
                case .number, .string, .ident, .regex: prevIsValue = true
                case .op(let o): prevIsValue = o == ")" || o == "]"
                default: prevIsValue = false
                }
                if !prevIsValue, let close = chars[(i + 1)...].firstIndex(of: "/") {
                    out.append(.regex(String(chars[(i + 1)..<close])))
                    i = close + 1
                    while i < chars.count, chars[i].isLetter { i += 1 }
                    continue
                }
            }
            let rest = String(chars[i..<min(i + 3, chars.count)])
            if let op = ops3.first(where: { rest.hasPrefix($0) }) {
                out.append(.op(String(op.dropLast()))); i += 3; continue
            }
            if let op = ops2.first(where: { rest.hasPrefix($0) }) {
                out.append(.op(op)); i += 2; continue
            }
            if "()[]{},.!+-*/%<>?:".contains(c) {
                out.append(.op(String(c))); i += 1; continue
            }
            throw BaseSyntaxError(description: "Unexpected character “\(c)” in “\(s)”")
        }
        out.append(.end)
        return out
    }

    struct Pratt {
        let tokens: [Token]
        var pos = 0

        var peek: Token { tokens[pos] }
        mutating func next() -> Token { defer { pos += 1 }; return tokens[pos] }

        func describe(_ t: Token) -> String {
            switch t {
            case .number(let n): return BaseValue.format(n)
            case .string(let s): return "\"\(s)\""
            case .ident(let s): return s
            case .op(let o): return "“\(o)”"
            case .regex(let r): return "/\(r)/"
            case .end: return "end of formula"
            }
        }

        mutating func expect(_ op: String) throws {
            guard next() == .op(op) else { throw BaseSyntaxError(description: "Expected “\(op)”") }
        }

        static func precedence(_ op: String) -> Int {
            switch op {
            case "?": return 1
            case "||": return 2
            case "&&": return 3
            case "==", "!=": return 4
            case "<", ">", "<=", ">=": return 5
            case "+", "-": return 6
            case "*", "/", "%": return 7
            default: return -1
            }
        }

        mutating func expression(_ minPrec: Int) throws -> BaseExpr {
            var left = try unary()
            while case .op(let op) = peek, Self.precedence(op) > minPrec || (op == "?" && minPrec < 1) {
                _ = next()
                if op == "?" {
                    let a = try expression(0)
                    try expect(":")
                    let b = try expression(0)
                    left = .call(.ident("if"), [left, a, b])
                    continue
                }
                let right = try expression(Self.precedence(op))
                left = .binary(op, left, right)
            }
            return left
        }

        mutating func unary() throws -> BaseExpr {
            if case .op(let op) = peek, op == "!" || op == "-" || op == "+" {
                _ = next()
                return .unary(op, try unary())
            }
            return try postfix(primary())
        }

        mutating func primary() throws -> BaseExpr {
            switch next() {
            case .number(let n): return .literal(.number(n))
            case .string(let s): return .literal(.string(s))
            case .regex(let r): return .literal(.regex(r))
            case .ident(let name):
                switch name {
                case "true": return .literal(.bool(true))
                case "false": return .literal(.bool(false))
                case "null", "undefined": return .literal(.null)
                default: return .ident(name)
                }
            case .op("("):
                let e = try expression(0)
                try expect(")")
                return e
            case .op("["):
                var items: [BaseExpr] = []
                if peek != .op("]") {
                    repeat { items.append(try expression(0)) } while try consumeComma()
                }
                try expect("]")
                return .list(items)
            case let t:
                throw BaseSyntaxError(description: "Unexpected \(describe(t))")
            }
        }

        mutating func consumeComma() throws -> Bool {
            if peek == .op(",") { _ = next(); return true }
            return false
        }

        mutating func postfix(_ base: BaseExpr) throws -> BaseExpr {
            var e = base
            while true {
                switch peek {
                case .op("."):
                    _ = next()
                    guard case .ident(let name) = next() else { throw BaseSyntaxError(description: "Expected a name after “.”") }
                    e = .member(e, name)
                case .op("["):
                    _ = next()
                    let idx = try expression(0)
                    try expect("]")
                    e = .index(e, idx)
                case .op("("):
                    _ = next()
                    var args: [BaseExpr] = []
                    if peek != .op(")") {
                        repeat { args.append(try expression(0)) } while try consumeComma()
                    }
                    try expect(")")
                    e = .call(e, args)
                default:
                    return e
                }
            }
        }
    }
}
