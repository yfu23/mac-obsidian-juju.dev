import Foundation

/// Obsidian-style search query: words (all must match), "exact phrases", -exclusions,
/// and the `tag:`, `path:` and `file:` operators. Matching is case-insensitive substring.
public struct SearchQuery: Sendable, Equatable {
    public enum Term: Sendable, Equatable {
        case text(String)
        case tag(String)
        case path(String)
        case file(String)
    }

    public var include: [Term] = []
    public var exclude: [Term] = []

    public var isEmpty: Bool { include.isEmpty && exclude.isEmpty }

    /// Strings to highlight in the opened note.
    public var highlightTerms: [String] {
        include.compactMap {
            switch $0 {
            case .text(let s): return s
            case .tag(let t): return "#" + t
            default: return nil
            }
        }
    }

    public init(_ raw: String) {
        for word in Self.split(raw) {
            var w = word
            var negate = false
            if w.hasPrefix("-"), w.count > 1 { negate = true; w.removeFirst() }
            let term: Term
            if let r = w.range(of: ":"), case let op = w[..<r.lowerBound].lowercased(),
               ["tag", "path", "file"].contains(op) {
                var value = Frontmatter.unquote(String(w[r.upperBound...]))
                guard !value.isEmpty else { continue }
                switch op {
                case "tag":
                    if value.hasPrefix("#") { value.removeFirst() }
                    term = .tag(value.lowercased())
                case "path": term = .path(value.lowercased())
                default: term = .file(value.lowercased())
                }
            } else {
                let value = Frontmatter.unquote(w)
                guard !value.isEmpty else { continue }
                term = .text(value.lowercased())
            }
            if negate { exclude.append(term) } else { include.append(term) }
        }
    }

    /// Whitespace split that keeps "quoted phrases" (including `op:"quoted value"`) together.
    static func split(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuote = false
        for ch in raw {
            if ch == "\"" { inQuote.toggle(); current.append(ch); continue }
            if ch.isWhitespace && !inQuote {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

public struct SearchMatch: Sendable, Hashable {
    public struct Segment: Sendable, Hashable {
        public let text: String
        public let highlighted: Bool
    }

    public let line: Int
    public let segments: [Segment]
}

public struct SearchHit: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let matches: [SearchMatch]
}

public struct SearchResults: Sendable {
    public let query: SearchQuery
    public let hits: [SearchHit]
    /// True when the result list was cut off at the limit.
    public let truncated: Bool

    public static let empty = SearchResults(query: SearchQuery(""), hits: [], truncated: false)
}

enum Snippets {
    /// Lines of `text` containing any of `terms`, with the matches marked. Long lines are windowed
    /// around the first match.
    static func matches(in text: String, terms: [String], maxLines: Int, lineOffset: Int = 0) -> [SearchMatch] {
        let terms = terms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        var out: [SearchMatch] = []
        for (i, rawLine) in text.components(separatedBy: "\n").enumerated() {
            guard let m = mark(rawLine, terms: terms) else { continue }
            out.append(SearchMatch(line: i + lineOffset, segments: m))
            if out.count >= maxLines { break }
        }
        return out
    }

    static func mark(_ rawLine: String, terms: [String]) -> [SearchMatch.Segment]? {
        var ranges: [Range<String.Index>] = []
        for term in terms {
            var from = rawLine.startIndex
            while let r = rawLine.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<rawLine.endIndex) {
                ranges.append(r)
                from = r.upperBound
                if r.isEmpty { break }
            }
        }
        guard !ranges.isEmpty else { return nil }
        ranges.sort { $0.lowerBound < $1.lowerBound }

        // Window long lines around the first match.
        var start = rawLine.startIndex
        var end = rawLine.endIndex
        let maxLen = 220
        if rawLine.count > maxLen {
            start = rawLine.index(ranges[0].lowerBound, offsetBy: -60, limitedBy: rawLine.startIndex) ?? rawLine.startIndex
            end = rawLine.index(start, offsetBy: maxLen, limitedBy: rawLine.endIndex) ?? rawLine.endIndex
        }
        var segments: [SearchMatch.Segment] = []
        var cursor = start
        if start > rawLine.startIndex { segments.append(.init(text: "…", highlighted: false)) }
        for r in ranges where r.lowerBound >= cursor && r.upperBound <= end {
            if cursor < r.lowerBound { segments.append(.init(text: String(rawLine[cursor..<r.lowerBound]), highlighted: false)) }
            segments.append(.init(text: String(rawLine[r]), highlighted: true))
            cursor = r.upperBound
        }
        if cursor < end { segments.append(.init(text: String(rawLine[cursor..<end]), highlighted: false)) }
        if end < rawLine.endIndex { segments.append(.init(text: "…", highlighted: false)) }
        // Trim leading indentation for display.
        if let first = segments.first, !first.highlighted {
            segments[0] = .init(text: String(first.text.drop(while: { $0 == " " || $0 == "\t" })), highlighted: false)
        }
        return segments
    }
}
