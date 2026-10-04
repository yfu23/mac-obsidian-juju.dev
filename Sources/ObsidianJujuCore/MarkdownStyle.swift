import Foundation

/// A styled run in Markdown source, for the editor's live preview. Ranges are UTF-16 (`NSRange`) offsets into the
/// whole text.
public struct MarkdownSpan: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bold, italic, boldItalic, strikethrough, highlight, code
        case heading(Int)
        /// `[[target]]`, `[[target|alias]]` or `[text](url)`.
        case link
        /// `![[file]]`, `![](path)` or `![](<juju:name>)`: `target` is the file as written, `width` from `|300`.
        case embed(target: String, width: Int?)
        case quote
        /// `> [!type]± title` and the `>` lines after it. `title` is the title text's range (length 0 when the
        /// callout has no title); `fold` is `+`, `-` or empty. Markers: every line's `>` prefix and the `[!type]±`.
        case callout(type: String, title: NSRange, fold: String)
        /// A one-line `<iframe src=…>…</iframe>` HTML block (e.g. a YouTube embed).
        case iframe(src: String, width: Int?, height: Int?)
        case codeBlock
        case frontmatter
    }

    public let kind: Kind
    public let range: NSRange
    /// Syntax characters (`**`, `# `, `[[`, …) that live preview hides when the caret isn't on the line.
    public let markers: [NSRange]
}

/// Finds Markdown styles in source text (Obsidian's syntax) and toggles formatting.
public enum MarkdownStyle {
    // MARK: Spans

    public static func spans(in text: String) -> [MarkdownSpan] {
        let ns = text as NSString
        var out: [MarkdownSpan] = []
        var fence: String?
        var fenceStart = 0
        var lineNo = 0
        var inFrontmatter = false
        var frontStart = 0
        var callout: (start: Int, end: Int, type: String, title: NSRange, fold: String, markers: [NSRange])?
        func closeCallout() {
            guard let c = callout else { return }
            out.append(.init(kind: .callout(type: c.type, title: c.title, fold: c.fold),
                             range: NSRange(location: c.start, length: c.end - c.start), markers: c.markers))
            callout = nil
        }
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) {
            _, lineRange, _, _ in
            defer { lineNo += 1 }
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Frontmatter: a "---" block at the very top.
            if lineNo == 0, trimmed == "---" { inFrontmatter = true; frontStart = lineRange.location; return }
            if inFrontmatter {
                if trimmed == "---" || trimmed == "..." {
                    inFrontmatter = false
                    out.append(.init(kind: .frontmatter, range: NSRange(location: frontStart, length: NSMaxRange(lineRange) - frontStart), markers: []))
                }
                return
            }
            // Callouts: a `> [!type]` line and the quote lines after it (outside code blocks).
            if fence == nil {
                let full = NSRange(location: 0, length: lineRange.length)
                if callout != nil {
                    if let m = quoteRE.firstMatch(in: line, range: full) {
                        callout!.markers.append(NSRange(location: lineRange.location + m.range.location, length: m.range.length))
                        callout!.end = NSMaxRange(lineRange)
                    } else {
                        closeCallout()
                    }
                }
                if callout == nil, let m = calloutRE.firstMatch(in: line, range: full) {
                    let lineNS = line as NSString
                    let title = m.range(at: 3)
                    callout = (lineRange.location, NSMaxRange(lineRange), lineNS.substring(with: m.range(at: 1)).lowercased(),
                               NSRange(location: lineRange.location + title.location, length: title.length),
                               lineNS.substring(with: m.range(at: 2)),
                               [NSRange(location: lineRange.location, length: title.location)])
                }
            }
            // Fenced code blocks.
            if let f = fence {
                if trimmed.hasPrefix(f), trimmed.drop(while: { $0 == f.first }).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                    out.append(.init(kind: .codeBlock, range: NSRange(location: fenceStart, length: NSMaxRange(lineRange) - fenceStart), markers: []))
                }
                return
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let ch = trimmed.first!
                fence = String(trimmed.prefix { $0 == ch })
                fenceStart = lineRange.location
                return
            }
            lineSpans(line, at: lineRange.location, into: &out)
        }
        closeCallout()
        if let _ = fence {
            out.append(.init(kind: .codeBlock, range: NSRange(location: fenceStart, length: ns.length - fenceStart), markers: []))
        }
        return out
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let headingRE = re(#"^(#{1,6})[ \t]+"#)
    private static let quoteRE = re(#"^(?:>[ \t]?)+"#)
    private static let calloutRE = re(#"^[ \t]{0,3}>[ \t]?\[!([^\]\s]+)\]([+-]?)[ \t]*(.*?)[ \t]*$"#)
    private static let iframeRE = try! NSRegularExpression(pattern: #"^[ \t]*<iframe\b([^>]*)>.*</iframe>[ \t]*$"#, options: .caseInsensitive)
    private static let srcRE = try! NSRegularExpression(pattern: #"\bsrc\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
    private static let widthRE = try! NSRegularExpression(pattern: #"\bwidth\s*=\s*["']?(\d+)"#, options: .caseInsensitive)
    private static let heightRE = try! NSRegularExpression(pattern: #"\bheight\s*=\s*["']?(\d+)"#, options: .caseInsensitive)
    private static let codeRE = re(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let wikiEmbedRE = re(#"!\[\[([^\]\n]+)\]\]"#)
    private static let mdEmbedRE = re(#"!\[([^\]\n]*)\]\(\s*(<[^>\n]+>|[^\s)]+)\s*\)"#)
    private static let wikiLinkRE = re(#"\[\[([^\]\n]+)\]\]"#)
    private static let mdLinkRE = re(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private static let boldItalicRE = re(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private static let boldRE = re(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicStarRE = re(#"(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#)
    private static let italicUnderRE = re(#"(?<![\p{L}\p{N}_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\p{L}\p{N}_])"#)
    private static let strikeRE = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let highlightRE = re(#"==(?=\S)(.+?)(?<=\S)=="#)

    private static func lineSpans(_ line: String, at base: Int, into out: inout [MarkdownSpan]) {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        func shift(_ r: NSRange) -> NSRange { NSRange(location: r.location + base, length: r.length) }
        // Working copy where consumed syntax is blanked out, so later patterns don't match inside it.
        var mask = Array(line.utf16)
        func blank(_ r: NSRange) { for i in r.location..<NSMaxRange(r) where i < mask.count { mask[i] = 0x20 } }
        func masked() -> NSString { String(utf16CodeUnits: mask, count: mask.count) as NSString }

        if let m = iframeRE.firstMatch(in: line, range: full) {
            let attrs = ns.substring(with: m.range(at: 1))
            let ar = NSRange(location: 0, length: (attrs as NSString).length)
            func attr(_ r: NSRegularExpression) -> String? {
                r.firstMatch(in: attrs, range: ar).map { (attrs as NSString).substring(with: $0.range(at: 1)) }
            }
            if let src = attr(srcRE) {
                out.append(.init(kind: .iframe(src: src, width: attr(widthRE).flatMap { Int($0) }, height: attr(heightRE).flatMap { Int($0) }),
                                 range: shift(full), markers: [shift(full)]))
                return
            }
        }
        if let m = headingRE.firstMatch(in: line, range: full) {
            let marker = m.range
            out.append(.init(kind: .heading(m.range(at: 1).length), range: shift(full), markers: [shift(marker)]))
            blank(marker)
        } else if let m = quoteRE.firstMatch(in: line, range: full) {
            out.append(.init(kind: .quote, range: shift(full), markers: [shift(m.range)]))
            blank(m.range)
        }
        for m in codeRE.matches(in: masked() as String, range: full) {
            let tick = m.range(at: 1).length
            out.append(.init(kind: .code, range: shift(m.range), markers: [
                shift(NSRange(location: m.range.location, length: tick)),
                shift(NSRange(location: NSMaxRange(m.range) - tick, length: tick)),
            ]))
            blank(m.range)
        }
        for m in wikiEmbedRE.matches(in: masked() as String, range: full) {
            var target = ns.substring(with: m.range(at: 1))
            var width: Int?
            if let bar = target.lastIndex(of: "|") {
                width = Int(target[target.index(after: bar)...].split(separator: "x").first ?? "")
                target = String(target[..<bar])
            }
            out.append(.init(kind: .embed(target: target, width: width), range: shift(m.range), markers: [shift(m.range)]))
            blank(m.range)
        }
        for m in mdEmbedRE.matches(in: masked() as String, range: full) {
            var target = ns.substring(with: m.range(at: 2))
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            let alt = ns.substring(with: m.range(at: 1))
            let width = alt.split(separator: "|").last.flatMap { Int($0.split(separator: "x").first ?? "") }
            out.append(.init(kind: .embed(target: target.removingPercentEncoding ?? target, width: width),
                             range: shift(m.range), markers: [shift(m.range)]))
            blank(m.range)
        }
        for m in wikiLinkRE.matches(in: masked() as String, range: full) {
            let inner = m.range(at: 1)
            let innerText = ns.substring(with: inner) as NSString
            let bar = innerText.range(of: "|", options: .backwards)
            // Show only the alias when there is one, like Obsidian.
            let open = NSRange(location: m.range.location, length: 2 + (bar.location == NSNotFound ? 0 : bar.location + 1))
            out.append(.init(kind: .link, range: shift(m.range), markers: [
                shift(open), shift(NSRange(location: NSMaxRange(m.range) - 2, length: 2)),
            ]))
            blank(open); blank(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for m in mdLinkRE.matches(in: masked() as String, range: full) {
            let textR = m.range(at: 1)
            let tail = NSRange(location: NSMaxRange(textR), length: NSMaxRange(m.range) - NSMaxRange(textR))
            out.append(.init(kind: .link, range: shift(m.range), markers: [
                shift(NSRange(location: m.range.location, length: 1)), shift(tail),
            ]))
            blank(NSRange(location: m.range.location, length: 1)); blank(tail)
        }
        func emphasis(_ regex: NSRegularExpression, _ kind: MarkdownSpan.Kind, marker: (NSTextCheckingResult) -> Int) {
            for m in regex.matches(in: masked() as String, range: full) {
                let k = marker(m)
                let open = NSRange(location: m.range.location, length: k)
                let close = NSRange(location: NSMaxRange(m.range) - k, length: k)
                out.append(.init(kind: kind, range: shift(m.range), markers: [shift(open), shift(close)]))
                blank(open); blank(close)
            }
        }
        emphasis(boldItalicRE, .boldItalic) { _ in 3 }
        emphasis(boldRE, .bold) { _ in 2 }
        emphasis(italicStarRE, .italic) { _ in 1 }
        emphasis(italicUnderRE, .italic) { _ in 1 }
        emphasis(strikeRE, .strikethrough) { _ in 2 }
        emphasis(highlightRE, .highlight) { _ in 2 }
    }

    // MARK: Links under the pointer

    /// The link target (with `#subpath`, without alias) of the `[[link]]`, `[text](link)` or embed at UTF-16 offset
    /// `index`, for "Open link" / "Open in new tab" in the editor's context menu.
    public static func linkTarget(in text: String, at index: Int) -> String? {
        let ns = text as NSString
        for span in spans(in: text) where NSLocationInRange(index, span.range) {
            switch span.kind {
            case .embed(let target, _):
                return target.hasPrefix("juju:") ? nil : target
            case .link:
                let raw = ns.substring(with: span.range)
                if raw.hasPrefix("[[") {
                    let inner = raw.dropFirst(2).dropLast(2)
                    return String(inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                }
                guard let open = raw.range(of: "](") else { return nil }
                var url = String(raw[open.upperBound...].dropLast()).trimmingCharacters(in: .whitespaces)
                if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
                return url.removingPercentEncoding ?? url
            default:
                continue
            }
        }
        return nil
    }

    // MARK: Formatting toggles

    public enum Format: String, CaseIterable, Sendable {
        case bold, italic, boldItalic, strikethrough, highlight

        /// Marker written when adding the style; italic inside bold uses `_` (Obsidian's "bold and nested italic").
        func marker(nestedInBold: Bool) -> String {
            switch self {
            case .bold: return "**"
            case .italic: return nestedInBold ? "_" : "*"
            case .boldItalic: return "***"
            case .strikethrough: return "~~"
            case .highlight: return "=="
            }
        }

        /// Marker characters and run length that count as "already has this style".
        var detect: [(Character, Int)] {
            switch self {
            case .bold: return [("*", 2), ("_", 2)]
            case .italic: return [("*", 1), ("_", 1)]
            case .boldItalic: return [("*", 3), ("_", 3)]
            case .strikethrough: return [("~", 2)]
            case .highlight: return [("=", 2)]
            }
        }
    }

    /// One text replacement plus the selection afterwards (UTF-16 ranges).
    public struct Edit: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String
        public let selection: NSRange
    }

    /// Adds or removes `format` around the selection, like Obsidian's "Toggle bold" etc. With no selection it
    /// works on the word at the caret, or inserts an empty pair with the caret between.
    public static func toggle(_ format: Format, in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        var r = selection
        func char(_ i: Int) -> Character? {
            guard i >= 0, i < ns.length, let s = UnicodeScalar(ns.character(at: i)) else { return nil }
            return Character(s)
        }
        func isWord(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        if r.length == 0 {
            var lo = r.location, hi = r.location
            while isWord(char(lo - 1)) { lo -= 1 }
            while isWord(char(hi)) { hi += 1 }
            r = NSRange(location: lo, length: hi - lo)
        } else {
            // Keep surrounding spaces outside the markers.
            while r.length > 0, char(r.location)?.isWhitespace == true { r.location += 1; r.length -= 1 }
            while r.length > 0, char(NSMaxRange(r) - 1)?.isWhitespace == true { r.length -= 1 }
        }
        func run(_ c: Character, from i: Int, step: Int) -> Int {
            var n = 0, j = i
            while char(j) == c { n += 1; j += step }
            return n
        }
        func has(_ c: Character, _ k: Int, before b: Int, after a: Int) -> Bool {
            let before = run(c, from: b, step: -1), after = run(c, from: a, step: 1)
            // Single markers: an odd run (1 or 3) means italic is on; `**x**` alone is bold, not italic.
            return k == 1 ? before % 2 == 1 && after % 2 == 1 : before >= k && after >= k
        }
        let caretOffset = selection.length == 0 ? selection.location - r.location : nil
        // Already styled just outside the selection: remove those markers.
        for (c, k) in format.detect where has(c, k, before: r.location - 1, after: NSMaxRange(r)) {
            let outer = NSRange(location: r.location - k, length: r.length + 2 * k)
            let inner = ns.substring(with: r)
            let sel = caretOffset.map { NSRange(location: outer.location + $0, length: 0) }
                ?? NSRange(location: outer.location, length: r.length)
            return Edit(range: outer, replacement: inner, selection: sel)
        }
        // The selection itself includes the markers: remove them.
        for (c, k) in format.detect where r.length > 2 * k {
            let inner = NSRange(location: r.location + k, length: r.length - 2 * k)
            if has(c, k, before: inner.location - 1, after: NSMaxRange(inner)),
               run(c, from: r.location, step: 1) == run(c, from: NSMaxRange(r) - 1, step: -1) {
                return Edit(range: r, replacement: ns.substring(with: inner),
                            selection: NSRange(location: r.location, length: inner.length))
            }
        }
        let nested = format == .italic && spans(in: text).contains { s in
            (s.kind == .bold) && s.range.location < r.location && NSMaxRange(s.range) > NSMaxRange(r)
        }
        let m = format.marker(nestedInBold: nested)
        let k = (m as NSString).length
        let body = ns.substring(with: r)
        let sel = caretOffset.map { NSRange(location: r.location + k + $0, length: 0) }
            ?? NSRange(location: r.location + k, length: r.length)
        return Edit(range: r, replacement: m + body + m, selection: sel)
    }
}
