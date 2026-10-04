import Foundation

/// Splits YAML frontmatter from a note and parses the subset Obsidian's Properties use:
/// `key: value`, `key: [a, b]`, block lists (`- item`), and `|` / `>` multi-line strings.
/// Anything fancier (nested maps) is kept as raw text so nothing is silently dropped.
public enum Frontmatter {
    public struct Split: Sendable {
        public let properties: [Property]
        /// The note text after the closing `---` line.
        public let body: String
        /// Number of lines the frontmatter block occupies (0 when there is none).
        public let lineCount: Int
    }

    public static func split(_ text: String) -> Split {
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return Split(properties: [], body: text, lineCount: 0)
        }
        // Normalize CRLF for matching only.
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else {
            return Split(properties: [], body: text, lineCount: 0)
        }
        let yaml = Array(lines[1..<end])
        let bodyLines = text.components(separatedBy: "\n").dropFirst(end + 1)
        return Split(properties: parse(yaml), body: bodyLines.joined(separator: "\n"), lineCount: end + 1)
    }

    static func parse(_ lines: [String]) -> [Property] {
        var result: [Property] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.hasPrefix("#"), !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = keyColon(in: line) else { continue }
            let key = unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // Collect indented continuation lines (block list items, multi-line strings, nested maps).
            var block: [String] = []
            while i < lines.count {
                let next = lines[i]
                let isIndented = next.hasPrefix(" ") || next.hasPrefix("\t")
                let isBareItem = next.hasPrefix("- ") || next == "-"
                if isIndented || isBareItem || next.trimmingCharacters(in: .whitespaces).isEmpty && i + 1 < lines.count
                    && (lines[i + 1].hasPrefix(" ") || lines[i + 1].hasPrefix("- ")) {
                    block.append(next)
                    i += 1
                } else { break }
            }

            if rest.isEmpty {
                let trimmed = block.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !trimmed.isEmpty, trimmed.allSatisfy({ $0.hasPrefix("-") }) {
                    let items = trimmed.map { unquote(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) }
                    result.append(Property(key: key, value: .list(items.filter { !$0.isEmpty })))
                } else {
                    result.append(Property(key: key, value: .text(trimmed.joined(separator: "\n"))))
                }
            } else if rest.hasPrefix("[") && rest.hasSuffix("]") {
                let inner = rest.dropFirst().dropLast()
                let items = splitFlowList(String(inner)).map(unquote).filter { !$0.isEmpty }
                result.append(Property(key: key, value: .list(items)))
            } else if rest == "|" || rest == ">" || rest.hasPrefix("|") || rest.hasPrefix(">") {
                let folded = rest.hasPrefix(">")
                let parts = block.map { $0.trimmingCharacters(in: .whitespaces) }
                result.append(Property(key: key, value: .text(parts.joined(separator: folded ? " " : "\n"))))
            } else {
                result.append(Property(key: key, value: .text(unquote(stripComment(rest)))))
            }
        }
        return result
    }

    /// The colon that ends the key: the first `:` followed by a space or end of line, outside quotes.
    private static func keyColon(in line: String) -> String.Index? {
        var quote: Character?
        var idx = line.startIndex
        while idx < line.endIndex {
            let ch = line[idx]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ":" {
                let next = line.index(after: idx)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" { return idx }
            }
            idx = line.index(after: idx)
        }
        return nil
    }

    private static func splitFlowList(_ s: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for ch in s {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch; current.append(ch)
            case "[": depth += 1; current.append(ch)
            case "]": depth -= 1; current.append(ch)
            case "," where depth == 0:
                items.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            default: current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { items.append(current.trimmingCharacters(in: .whitespaces)) }
        return items
    }

    private static func stripComment(_ s: String) -> String {
        guard !s.hasPrefix("\""), !s.hasPrefix("'"), let r = s.range(of: " #") else { return s }
        return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") else { return s }
        let inner = String(s.dropFirst().dropLast())
        if f == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        guard inner.contains("\\") else { return inner }
        var out = "", escaped = false
        for ch in inner {
            if escaped { out.append(ch == "n" ? "\n" : ch == "t" ? "\t" : ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out
    }

    // MARK: Editing (the editor's Properties panel)

    public enum Edit: Equatable, Sendable {
        /// Sets (or adds, at the end) a property's value.
        case set(key: String, value: PropertyValue)
        case rename(from: String, to: String)
        case remove(key: String)
    }

    /// Applies `edit` to the frontmatter of `text`, rewriting only that property's lines (in Obsidian's style:
    /// `key: value`, block lists, quotes only when needed). Creates the frontmatter if the note has none.
    /// Returns nil when there's nothing to change.
    public static func apply(_ edit: Edit, to text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let hasFrontmatter = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
            && lines.dropFirst().contains { $0 == "---" || $0 == "..." || $0 == "---\r" }
        if !hasFrontmatter {
            guard case .set(let key, let value) = edit else { return nil }
            return (["---"] + serialize(key: key, value: value) + ["---"]).joined(separator: "\n") + "\n" + text
        }
        let end = lines.dropFirst().firstIndex { $0 == "---" || $0 == "..." || $0 == "---\r" }!
        // Each property: its key line and the continuation lines that belong to it.
        var blocks: [(key: String, range: Range<Int>)] = []
        var i = 1
        while i < end {
            let line = lines[i]
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"), let colon = keyColon(in: line) else { i += 1; continue }
            let key = unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            var j = i + 1
            while j < end, lines[j].hasPrefix(" ") || lines[j].hasPrefix("\t") || lines[j].hasPrefix("- ") || lines[j] == "-" { j += 1 }
            blocks.append((key, i..<j))
            i = j
        }
        func block(_ key: String) -> Range<Int>? { blocks.first { $0.key == key }?.range }
        switch edit {
        case .set(let key, let value):
            let new = serialize(key: key, value: value)
            if let r = block(key) {
                if Array(lines[r]) == new { return nil }
                lines.replaceSubrange(r, with: new)
            } else {
                lines.insert(contentsOf: new, at: end)
            }
        case .rename(let from, let to):
            guard from != to, let r = block(from), block(to) == nil else { return nil }
            let line = lines[r.lowerBound]
            lines[r.lowerBound] = quoteKey(to) + String(line[keyColon(in: line)!...])
        case .remove(let key):
            guard let r = block(key) else { return nil }
            lines.removeSubrange(r)
        }
        return lines.joined(separator: "\n")
    }

    static func serialize(key: String, value: PropertyValue) -> [String] {
        let k = quoteKey(key)
        switch value {
        case .text(let s):
            return s.isEmpty ? ["\(k):"] : ["\(k): \(quoteValue(s))"]
        case .list(let items):
            return items.isEmpty ? ["\(k):"] : ["\(k):"] + items.map { "  - \(quoteValue($0))" }
        }
    }

    private static func quoteKey(_ key: String) -> String {
        key.contains(":") || key.hasPrefix("-") || key.hasPrefix("#") || key.contains("\"") ? "\"" + escape(key) + "\"" : key
    }

    /// Plain when YAML reads it back unchanged; double-quoted otherwise (e.g. `"[[Note]]"`, as Obsidian writes).
    static func quoteValue(_ s: String) -> String {
        let special: Set<Character> = ["[", "]", "{", "}", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`", "#", ","]
        let needs = s.contains(": ") || s.contains(" #") || s.hasSuffix(":") || s.contains("\n")
            || s.first.map { $0.isWhitespace || special.contains($0) } ?? false
            || s.last?.isWhitespace == true || s == "-" || s.hasPrefix("- ") || s.hasPrefix("? ") || s.hasPrefix(": ")
        if !needs { return s }
        return "\"" + escape(s) + "\""
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
