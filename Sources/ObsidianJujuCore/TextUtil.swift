import Foundation

public enum Tokenizer {
    /// Lowercased word tokens. Letters, digits and `_` form words; each CJK character is its own token
    /// (CJK text has no spaces, so whole-run tokens would make substring search miss).
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty { out.append(String(current)); current.removeAll(keepingCapacity: true) }
        }
        for scalar in text.lowercased().unicodeScalars {
            if isCJK(scalar) {
                flush()
                out.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

public enum Fuzzy {
    /// Subsequence fuzzy match; lower scores are better, nil means no match.
    /// Consecutive runs and matches at word starts score better, like Obsidian's quick switcher.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var qi = 0, score = 0, last = -1
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            let gap = last < 0 ? ti : ti - last - 1
            let wordStart = ti == 0 || !(t[ti - 1].isLetter || t[ti - 1].isNumber)
            score += gap * 2 - (wordStart ? 3 : 0)
            last = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        if text.lowercased().contains(String(q)) { score -= 20 }
        return score + t.count / 8
    }
}

/// Extracts the part of a note an embed or link points at.
public enum NoteSections {
    /// The heading section named by `subpath` ("Heading" or "Parent#Child": the last component is
    /// matched), from the heading line up to the next heading of the same or higher level.
    /// For a block reference ("^id"), the block carrying that id, with the id removed.
    public static func extract(_ body: String, subpath: String) -> String? {
        if subpath.hasPrefix("^") { return block(body, id: String(subpath.dropFirst())) }
        let wanted = normalizeHeading(String(subpath.split(separator: "#").last ?? Substring(subpath)))
        let lines = body.components(separatedBy: "\n")
        var fence: (char: Character, count: Int)?
        var start: Int?
        var level = 0
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if trimmed.hasPrefix(String(repeating: f.char, count: f.count)) { fence = nil }
                continue
            }
            if let f = NoteParser.fenceOpener(trimmed) { fence = f; continue }
            guard let h = NoteParser.heading(in: line) else { continue }
            if let s = start {
                if h.level <= level { return lines[s..<i].joined(separator: "\n") }
            } else if normalizeHeading(h.text) == wanted {
                start = i
                level = h.level
            }
        }
        if let s = start { return lines[s...].joined(separator: "\n") }
        return nil
    }

    /// Obsidian compares headings ignoring case and characters that can't appear in links.
    public static func normalizeHeading(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[\[\]#|^:\\]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func block(_ body: String, id: String) -> String? {
        let lines = body.components(separatedBy: "\n")
        let marker = "^" + id
        guard let i = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == marker || t.hasSuffix(" " + marker)
        }) else { return nil }
        let line = lines[i].trimmingCharacters(in: .whitespaces)

        func strip(_ s: String) -> String {
            guard let r = s.range(of: " " + marker, options: .backwards) else { return s }
            return String(s[..<r.lowerBound]) + s[r.upperBound...]
        }

        if line == marker {
            // Standalone id after a list, table or quote: it names the preceding block.
            var end = i - 1
            while end >= 0, lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            guard end >= 0 else { return nil }
            var begin = end
            while begin > 0, !lines[begin - 1].trimmingCharacters(in: .whitespaces).isEmpty { begin -= 1 }
            return lines[begin...end].joined(separator: "\n")
        }
        if line.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil {
            return strip(lines[i])
        }
        // A paragraph: neighbouring non-blank lines, stopping at headings and code fences.
        func joins(_ n: Int) -> Bool {
            let t = lines[n].trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && NoteParser.heading(in: t) == nil && NoteParser.fenceOpener(t) == nil
        }
        var begin = i
        while begin > 0, joins(begin - 1) { begin -= 1 }
        var end = i
        while end + 1 < lines.count, joins(end + 1) { end += 1 }
        var out = Array(lines[begin...end])
        out[i - begin] = strip(out[i - begin])
        return out.joined(separator: "\n")
    }
}
