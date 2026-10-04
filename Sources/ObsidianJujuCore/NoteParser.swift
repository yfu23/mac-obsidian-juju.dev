import Foundation

/// Metadata extracted from one note. Parsing is line-based and skips fenced code, inline code,
/// `%% comments %%` and `$$ math $$`, matching what Obsidian treats as tags and links.
public struct ParsedNote: Sendable {
    public var properties: [Property] = []
    /// Tags without the leading `#`, in first-seen order, deduplicated case-insensitively.
    public var tags: [String] = []
    public var aliases: [String] = []
    public var links: [LinkRef] = []
    public var headings: [Heading] = []
    public var frontmatterLineCount = 0
}

public enum NoteParser {
    public static func parse(_ text: String) -> ParsedNote {
        let fm = Frontmatter.split(text)
        var note = ParsedNote()
        note.properties = fm.properties
        note.frontmatterLineCount = fm.lineCount

        var seenTags = Set<String>()
        func addTag(_ raw: String) {
            var t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { t.removeFirst() }
            guard isValidTag(t), seenTags.insert(t.lowercased()).inserted else { return }
            note.tags.append(t)
        }

        for prop in fm.properties {
            switch prop.key.lowercased() {
            case "tags", "tag":
                for item in prop.value.items {
                    item.split(whereSeparator: { $0 == "," || $0 == " " }).forEach { addTag(String($0)) }
                }
            case "aliases", "alias":
                for item in prop.value.items {
                    let parts = prop.value.items.count == 1 ? item.split(separator: ",").map(String.init) : [item]
                    note.aliases += parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            default:
                // Links inside property values count too (Obsidian shows them in the graph/backlinks).
                for item in prop.value.items { note.links += wikiLinks(in: item, line: 0) }
            }
        }

        var fence: (char: Character, count: Int)?
        var inComment = false
        var inMath = false
        let lines = fm.body.components(separatedBy: "\n")
        for (offset, rawLine) in lines.enumerated() {
            let lineNo = offset + fm.lineCount
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let f = fence {
                if trimmed.hasPrefix(String(repeating: f.char, count: f.count)),
                   trimmed.allSatisfy({ $0 == f.char }) { fence = nil }
                continue
            }
            if let f = fenceOpener(trimmed) { fence = f; continue }

            var content = line
            if inComment {
                guard let r = content.range(of: "%%") else { continue }
                content = String(content[r.upperBound...])
                inComment = false
            }
            if inMath {
                if trimmed.hasSuffix("$$") { inMath = false }
                continue
            }
            if trimmed.hasPrefix("$$") && !(trimmed.count > 2 && trimmed.hasSuffix("$$")) {
                inMath = true
                continue
            }
            content = stripInlineComments(content, inComment: &inComment)
            content = stripInlineCode(content)

            if let h = heading(in: content) {
                note.headings.append(Heading(level: h.level, text: h.text, line: lineNo))
            }
            note.links += wikiLinks(in: content, line: lineNo)
            note.links += markdownLinks(in: content, line: lineNo)
            // Link text like [[#Heading]] must not be read as a tag.
            let linkless = wikiRegex.stringByReplacingMatches(
                in: content, range: NSRange(location: 0, length: (content as NSString).length), withTemplate: " ")
            for tag in inlineTags(in: linkless) { addTag(tag) }
        }
        return note
    }

    // MARK: Pieces (internal so CoreChecks can exercise them)

    static func fenceOpener(_ trimmed: String) -> (char: Character, count: Int)? {
        guard let c = trimmed.first, c == "`" || c == "~" else { return nil }
        let n = trimmed.prefix(while: { $0 == c }).count
        return n >= 3 ? (c, n) : nil
    }

    static func heading(in line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes: "## Title ##"
        if let r = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(r) }
        return text.isEmpty ? nil : (level, text)
    }

    private static let wikiRegex = try! NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n]+?)\]\]"#)
    private static let mdLinkRegex = try! NSRegularExpression(
        pattern: #"(!?)\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*(<[^>\n]+>|[^)\s]+)(?:\s+"[^"]*")?\s*\)"#)
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[\s(\[{,;!?"'>]))#([\p{L}\p{N}_\-/\p{Emoji_Presentation}]+)"#)

    static func wikiLinks(in line: String, line lineNo: Int) -> [LinkRef] {
        let ns = line as NSString
        return wikiRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map { m in
            let embed = m.range(at: 1).length > 0
            let parsed = parseWikiInner(ns.substring(with: m.range(at: 2)))
            return LinkRef(target: parsed.target, subpath: parsed.subpath, alias: parsed.alias,
                           isEmbed: embed, style: .wiki, line: lineNo)
        }
    }

    /// Splits `path#subpath|alias`. Handles the `\|` escape Obsidian uses inside tables.
    public static func parseWikiInner(_ inner: String) -> (target: String, subpath: String?, alias: String?) {
        var body = inner
        var alias: String?
        if let bar = body.firstIndex(of: "|") {
            alias = String(body[body.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<bar])
            if body.hasSuffix("\\") { body.removeLast() }
        }
        var subpath: String?
        if let hash = body.firstIndex(of: "#") {
            subpath = String(body[body.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<hash])
        }
        return (body.trimmingCharacters(in: .whitespaces), subpath?.isEmpty == true ? nil : subpath,
                alias?.isEmpty == true ? nil : alias)
    }

    static func markdownLinks(in line: String, line lineNo: Int) -> [LinkRef] {
        let ns = line as NSString
        return mdLinkRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var url = ns.substring(with: m.range(at: 2))
            if url.hasPrefix("<") { url = String(url.dropFirst().dropLast()) }
            guard let local = localLinkPath(url) else { return nil }
            return LinkRef(target: local.target, subpath: local.subpath, alias: nil,
                           isEmbed: m.range(at: 1).length > 0, style: .markdown, line: lineNo)
        }
    }

    /// For a Markdown-style link URL, the decoded vault path and subpath, or nil for external URLs.
    public static func localLinkPath(_ url: String) -> (target: String, subpath: String?)? {
        let lower = url.lowercased()
        if lower.range(of: #"^[a-z][a-z0-9+.\-]*:"#, options: .regularExpression) != nil { return nil }
        let decoded = url.removingPercentEncoding ?? url
        if let hash = decoded.firstIndex(of: "#") {
            let sub = String(decoded[decoded.index(after: hash)...])
            return (String(decoded[..<hash]), sub.isEmpty ? nil : sub)
        }
        return (decoded, nil)
    }

    static func inlineTags(in line: String) -> [String] {
        let ns = line as NSString
        return tagRegex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    /// Obsidian tags need at least one non-digit character ("#2024" is not a tag).
    static func isValidTag(_ t: String) -> Bool {
        !t.isEmpty && !t.allSatisfy({ $0.isNumber || $0 == "/" || $0 == "-" || $0 == "_" })
    }

    static func stripInlineCode(_ line: String) -> String {
        guard line.contains("`") else { return line }
        return line.replacingOccurrences(of: #"(`+)[^`].*?\1"#, with: " ", options: .regularExpression)
    }

    static func stripInlineComments(_ line: String, inComment: inout Bool) -> String {
        guard line.contains("%%") else { return line }
        var out = ""
        var rest = Substring(line)
        while let r = rest.range(of: "%%") {
            out += rest[..<r.lowerBound]
            let after = rest[r.upperBound...]
            if let close = after.range(of: "%%") {
                rest = after[close.upperBound...]
            } else {
                inComment = true
                return out
            }
        }
        return out + rest
    }
}
