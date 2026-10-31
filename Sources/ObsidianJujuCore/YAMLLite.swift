import Foundation

/// A small YAML reader for `.base` files: block mappings and sequences (including `- key: value`
/// items), flow lists `[a, b]` and maps `{a: b}`, quoted and plain scalars, `|`/`>` blocks and comments.
/// Anchors, tags and multi-document streams are not supported (Bases doesn't use them).
public indirect enum YAMLValue: Equatable, Sendable {
    case scalar(String)
    case list([YAMLValue])
    case map([(String, YAMLValue)])
    case null

    public static func == (a: YAMLValue, b: YAMLValue) -> Bool {
        switch (a, b) {
        case (.scalar(let x), .scalar(let y)): return x == y
        case (.list(let x), .list(let y)): return x == y
        case (.map(let x), .map(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.null, .null): return true
        default: return false
        }
    }

    public subscript(key: String) -> YAMLValue? {
        if case .map(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    public var string: String? {
        if case .scalar(let s) = self { return s }
        return nil
    }

    public var items: [YAMLValue] {
        switch self {
        case .list(let l): return l
        case .null: return []
        default: return [self]
        }
    }

    public var pairs: [(String, YAMLValue)] {
        if case .map(let p) = self { return p }
        return []
    }
}

extension YAMLValue {
    /// JSON with the YAML's key order kept (the page edits it and writes YAML back, as Obsidian does). Plain
    /// numbers and true/false become JSON numbers and booleans.
    public var json: String {
        switch self {
        case .null: return "null"
        case .scalar(let s):
            if s == "true" || s == "false" { return s }
            if s.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil { return s }
            return Self.quote(s)
        case .list(let l): return "[" + l.map(\.json).joined(separator: ",") + "]"
        case .map(let p): return "{" + p.map { Self.quote($0.0) + ":" + $0.1.json }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

public enum YAMLLite {
    public static func parse(_ text: String) -> YAMLValue {
        var lines: [(indent: Int, text: String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { lines.append((-1, raw)); continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            lines.append((indent, raw))
        }
        var parser = Parser(lines: lines)
        return parser.parseBlock(minIndent: 0)
    }

    struct Parser {
        let lines: [(indent: Int, text: String)]
        var i = 0

        init(lines: [(indent: Int, text: String)]) { self.lines = lines }

        mutating func skipBlank() { while i < lines.count, lines[i].indent < 0 { i += 1 } }

        mutating func parseBlock(minIndent: Int) -> YAMLValue {
            skipBlank()
            guard i < lines.count, lines[i].indent >= minIndent else { return .null }
            let indent = lines[i].indent
            let content = String(lines[i].text.dropFirst(indent))
            if content == "-" || content.hasPrefix("- ") { return parseSequence(indent: indent) }
            return parseMapping(indent: indent)
        }

        mutating func parseSequence(indent: Int) -> YAMLValue {
            var items: [YAMLValue] = []
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent else { break }
                let content = String(lines[i].text.dropFirst(indent))
                guard content == "-" || content.hasPrefix("- ") else { break }
                let rest = content == "-" ? "" : String(content.dropFirst(2))
                let restTrimmed = rest.trimmingCharacters(in: .whitespaces)
                if restTrimmed.isEmpty {
                    i += 1
                    items.append(parseBlock(minIndent: indent + 1))
                } else if Self.keyColon(in: restTrimmed) != nil, !restTrimmed.hasPrefix("\""), !restTrimmed.hasPrefix("'"),
                          !restTrimmed.hasPrefix("[") , !restTrimmed.hasPrefix("{") {
                    // "- key: value" starts a mapping whose keys are aligned with "key".
                    let itemIndent = indent + 2 + (rest.count - rest.drop(while: { $0 == " " }).count)
                    var rewritten = lines
                    rewritten[i] = (itemIndent, String(repeating: " ", count: itemIndent) + restTrimmed)
                    var sub = Parser(lines: rewritten)
                    sub.i = i
                    items.append(sub.parseMapping(indent: itemIndent))
                    i = sub.i
                } else {
                    i += 1
                    items.append(Self.scalarOrFlow(restTrimmed))
                }
            }
            return .list(items)
        }

        mutating func parseMapping(indent: Int) -> YAMLValue {
            var pairs: [(String, YAMLValue)] = []
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent else { break }
                let content = String(lines[i].text.dropFirst(indent))
                guard let colon = Self.keyColon(in: content) else { i += 1; continue }
                let key = Self.unquote(String(content[..<colon]).trimmingCharacters(in: .whitespaces))
                let value = Self.stripComment(String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
                i += 1
                if value.isEmpty {
                    skipBlank()
                    // A sequence may sit at the same indent as its key.
                    if i < lines.count, lines[i].indent == indent,
                       String(lines[i].text.dropFirst(indent)).hasPrefix("- ") || String(lines[i].text.dropFirst(indent)) == "-" {
                        pairs.append((key, parseSequence(indent: indent)))
                    } else {
                        pairs.append((key, parseBlock(minIndent: indent + 1)))
                    }
                } else if value == "|" || value == ">" || value.hasPrefix("|") || value.hasPrefix(">") {
                    var block: [String] = []
                    var blockIndent: Int?
                    while i < lines.count, lines[i].indent < 0 || lines[i].indent > indent {
                        if lines[i].indent >= 0 {
                            blockIndent = blockIndent ?? lines[i].indent
                            block.append(String(lines[i].text.dropFirst(min(blockIndent!, lines[i].indent))))
                        } else {
                            block.append("")
                        }
                        i += 1
                    }
                    while block.last == "" { block.removeLast() }
                    pairs.append((key, .scalar(block.joined(separator: value.hasPrefix(">") ? " " : "\n"))))
                } else {
                    pairs.append((key, Self.scalarOrFlow(value)))
                }
            }
            return .map(pairs)
        }

        static func scalarOrFlow(_ s: String) -> YAMLValue {
            if s.hasPrefix("[") || s.hasPrefix("{") {
                var idx = s.startIndex
                return parseFlow(s, &idx)
            }
            if s == "~" || s == "null" { return .null }
            return .scalar(unquote(s))
        }

        static func parseFlow(_ s: String, _ idx: inout String.Index) -> YAMLValue {
            func skipSpace() { while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) } }
            skipSpace()
            guard idx < s.endIndex else { return .null }
            let open = s[idx]
            if open == "[" || open == "{" {
                idx = s.index(after: idx)
                var list: [YAMLValue] = []
                var map: [(String, YAMLValue)] = []
                while true {
                    skipSpace()
                    guard idx < s.endIndex else { break }
                    if s[idx] == "]" || s[idx] == "}" { idx = s.index(after: idx); break }
                    if s[idx] == "," { idx = s.index(after: idx); continue }
                    if open == "{" {
                        let keyStart = idx
                        var quote: Character?
                        while idx < s.endIndex {
                            let c = s[idx]
                            if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == ":" { break }
                            idx = s.index(after: idx)
                        }
                        let key = unquote(String(s[keyStart..<idx]).trimmingCharacters(in: .whitespaces))
                        if idx < s.endIndex { idx = s.index(after: idx) }
                        map.append((key, parseFlow(s, &idx)))
                    } else {
                        list.append(parseFlow(s, &idx))
                    }
                }
                return open == "[" ? .list(list) : .map(map)
            }
            // Scalar up to the next , ] } (respecting quotes)
            let start = idx
            var quote: Character?
            while idx < s.endIndex {
                let c = s[idx]
                if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == "," || c == "]" || c == "}" { break }
                idx = s.index(after: idx)
            }
            return .scalar(unquote(String(s[start..<idx]).trimmingCharacters(in: .whitespaces)))
        }

        static func keyColon(in line: String) -> String.Index? {
            var quote: Character?
            var depth = 0
            var idx = line.startIndex
            while idx < line.endIndex {
                let ch = line[idx]
                if let q = quote {
                    if ch == q { quote = nil }
                } else if ch == "\"" || ch == "'" {
                    quote = ch
                } else if ch == "(" || ch == "[" || ch == "{" {
                    depth += 1
                } else if ch == ")" || ch == "]" || ch == "}" {
                    depth -= 1
                } else if ch == ":" && depth <= 0 {
                    let next = line.index(after: idx)
                    if next == line.endIndex || line[next] == " " { return idx }
                }
                idx = line.index(after: idx)
            }
            return nil
        }

        static func stripComment(_ s: String) -> String {
            guard !s.hasPrefix("\""), !s.hasPrefix("'"), let r = s.range(of: " #") else { return s }
            return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        static func unquote(_ s: String) -> String {
            guard s.count >= 2, let f = s.first, let l = s.last else { return s }
            if f == "'" && l == "'" { return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            if f == "\"" && l == "\"" {
                return String(s.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return s
        }
    }
}
