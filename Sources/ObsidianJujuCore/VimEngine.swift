// Copied from Notepad+++ (NotepadCore/VimEngine.swift) — keep the two in sync when either changes.
// Local additions: resetHistory(), recordUndoPoint().
import Foundation

public enum VimMode: Equatable {
    case normal, insert, visual, visualLine, command
}

/// What the host should do after a key was fed to the engine.
public enum VimEffect: Equatable {
    case none
    case ex(String)          // an ex command line such as "w", "q", "%s/a/b/g"
    case search(String, forward: Bool)
}

/// Pure-Swift modal editing state machine. Positions are Character offsets into `text`.
/// The host feeds keys via `handle(_:)` and mirrors `text`/`cursor`/`selection`/`mode` back into the view.
public final class VimEngine {
    public private(set) var text: [Character]
    public var cursor: Int
    public private(set) var mode: VimMode = .normal
    public private(set) var visualAnchor: Int = 0
    public private(set) var commandLine: String = ""
    public private(set) var register: (text: String, linewise: Bool) = ("", false)
    public private(set) var lastSearch: String?

    private var count: Int?
    private var pendingOperator: Character?
    private var pendingPrefix: Character?      // g, f, t, F, T, r, i, a
    private var undoStack: [([Character], Int)] = []
    private var redoStack: [([Character], Int)] = []
    private var lastFind: (Character, Character)?  // (kind, target)

    public init(text: String = "", cursor: Int = 0) {
        self.text = Array(text)
        self.cursor = cursor
    }

    public var string: String { String(text) }

    public func load(_ s: String, cursor: Int) {
        text = Array(s)
        self.cursor = min(max(0, cursor), max(0, text.count))
        clampCursor()
    }

    /// Selected range (Character offsets, end exclusive) when in a visual mode.
    public var selection: Range<Int>? {
        switch mode {
        case .visual:
            let lo = min(visualAnchor, cursor), hi = max(visualAnchor, cursor)
            return lo..<min(hi + 1, text.count)
        case .visualLine:
            let a = lineRange(at: min(visualAnchor, cursor)).lowerBound
            let b = lineRange(at: max(visualAnchor, cursor)).upperBound
            return a..<b
        default: return nil
        }
    }

    // MARK: - Key handling

    @discardableResult
    public func handle(_ key: String) -> VimEffect {
        switch mode {
        case .insert: return handleInsert(key)
        case .command: return handleCommand(key)
        default: return handleNormal(key)
        }
    }

    private func handleInsert(_ key: String) -> VimEffect {
        switch key {
        case "Escape":
            mode = .normal
            if cursor > 0, cursor > lineRange(at: cursor).lowerBound { cursor -= 1 }
        case "Backspace":
            if cursor > 0 { text.remove(at: cursor - 1); cursor -= 1 }
        case "Enter": insert("\n")
        case "Tab": insert("\t")
        default: if key.count == 1 { insert(key) }
        }
        return .none
    }

    private func handleCommand(_ key: String) -> VimEffect {
        switch key {
        case "Escape": mode = .normal; commandLine = ""
        case "Backspace":
            if commandLine.count <= 1 { mode = .normal; commandLine = "" } else { commandLine.removeLast() }
        case "Enter":
            let line = commandLine
            commandLine = ""; mode = .normal
            if line.hasPrefix(":") { return .ex(String(line.dropFirst())) }
            let q = String(line.dropFirst())
            lastSearch = q
            return .search(q, forward: line.hasPrefix("/"))
        default: if key.count == 1 { commandLine += key }
        }
        return .none
    }

    private func handleNormal(_ key: String) -> VimEffect {
        let visual = mode == .visual || mode == .visualLine

        if key == "Escape" { resetPending(); if visual { mode = .normal }; return .none }

        // Pending two-key prefixes.
        if let p = pendingPrefix {
            pendingPrefix = nil
            guard key.count == 1, let ch = key.first else { resetPending(); return .none }
            switch p {
            case "r":
                if cursor < text.count, text[cursor] != "\n" { snapshot(); text[cursor] = ch }
                resetPending(); return .none
            case "f", "F", "t", "T":
                lastFind = (p, ch)
                return applyMotion { self.findChar(p, ch, count: $0) }
            case "g":
                if ch == "g" { return applyMotion(linewise: true) { n in
                    self.count == nil ? 0 : self.lineStart(ofLine: n - 1) } }
                if ch == "u" || ch == "U" || ch == "~" { return setOperator(ch == "u" ? "\u{1}" : ch == "U" ? "\u{2}" : "\u{3}") }
                resetPending(); return .none
            case "i", "a":
                if let r = textObject(inner: p == "i", ch) { return applyRange(r) }
                resetPending(); return .none
            default: resetPending(); return .none
            }
        }

        // Counts.
        if key.count == 1, let d = key.first?.wholeNumberValue, !(d == 0 && count == nil) {
            count = (count ?? 0) * 10 + d
            return .none
        }

        guard key.count == 1, let ch = key.first else { return .none }

        // Doubled operator: dd, cc, yy, >>, <<.
        if let op = pendingOperator, op == ch {
            return applyRange(lineSpan(count: count ?? 1), linewise: true)
        }

        // Visual modes: x/X/D/s/C/S/Y act on the whole selection (X, D, C, S, Y are linewise, as in Vim).
        if visual, let sel = selection {
            let lineMode = mode == .visualLine
            switch ch {
            case "x", "s": return applyRange(sel, linewise: lineMode, op: ch == "x" ? "d" : "c")
            case "X", "D": return applyRange(lineRange(at: sel.lowerBound).lowerBound..<lineRange(at: max(sel.lowerBound, sel.upperBound - 1)).upperBound, linewise: true, op: "d")
            case "C", "S": return applyRange(lineRange(at: sel.lowerBound).lowerBound..<lineRange(at: max(sel.lowerBound, sel.upperBound - 1)).upperBound, linewise: true, op: "c")
            case "Y": return applyRange(lineRange(at: sel.lowerBound).lowerBound..<lineRange(at: max(sel.lowerBound, sel.upperBound - 1)).upperBound, linewise: true, op: "y")
            default: break
            }
        }

        switch ch {
        case "h": return applyMotion { max(self.lineRange(at: self.cursor).lowerBound, self.cursor - $0) }
        case "l": return applyMotion { self.moveRight($0) }
        case "j": return applyMotion(linewise: true) { self.moveVertical($0) }
        case "k": return applyMotion(linewise: true) { self.moveVertical(-$0) }
        case "w": return applyMotion { self.wordForward($0) }
        case "b": return applyMotion { self.wordBackward($0) }
        case "e": return applyMotion(inclusive: true) { self.wordEnd($0) }
        case "0": return applyMotion { _ in self.lineRange(at: self.cursor).lowerBound }
        case "^": return applyMotion { _ in self.firstNonBlank(self.cursor) }
        case "$": return applyMotion(inclusive: true) { _ in self.lastInLine(self.cursor) }
        case "G": return applyMotion(linewise: true) { _ in
            self.count == nil ? self.lineStart(ofLine: self.lineCount - 1) : self.lineStart(ofLine: self.count! - 1) }
        case "}": return applyMotion { self.paragraph($0) }
        case "{": return applyMotion { self.paragraph(-$0) }
        case "%": return applyMotion(inclusive: true) { _ in self.matchBracket(self.cursor) }
        case ";": if let f = lastFind { return applyMotion { self.findChar(f.0, f.1, count: $0) } }; return .none
        case "g", "f", "F", "t", "T":
            pendingPrefix = ch; return .none
        case "i" where pendingOperator != nil || visual, "a" where pendingOperator != nil || visual:
            pendingPrefix = ch; return .none
        case "d", "c", "y", ">", "<":
            if visual { return applyRange(selection ?? cursor..<cursor, linewise: mode == .visualLine, op: ch) }
            pendingOperator = ch; return .none
        case "x": return applyRange(cursor..<min(cursor + (count ?? 1), lineRange(at: cursor).upperBound - (text.last == "\n" ? 1 : 0)), op: "d")
        case "X": let lo = max(lineRange(at: cursor).lowerBound, cursor - (count ?? 1)); return applyRange(lo..<cursor, op: "d")
        case "D": return applyRange(cursor..<lineEndExclusive(cursor), op: "d")
        case "C": return applyRange(cursor..<lineEndExclusive(cursor), op: "c")
        case "Y": return applyRange(lineSpan(count: count ?? 1), linewise: true, op: "y")
        case "s": return applyRange(cursor..<min(cursor + (count ?? 1), lineEndExclusive(cursor)), op: "c")
        case "r": pendingPrefix = "r"; return .none
        case "i": return enterInsert(at: cursor)
        case "a": return enterInsert(at: min(cursor + 1, lineEndExclusive(cursor)))
        case "I": return enterInsert(at: firstNonBlank(cursor))
        case "A": return enterInsert(at: lineEndExclusive(cursor))
        case "o":
            snapshot(); let e = lineEndExclusive(cursor); text.insert("\n", at: e); return enterInsert(at: e + 1, snap: false)
        case "O":
            snapshot(); let s = lineRange(at: cursor).lowerBound; text.insert("\n", at: s); return enterInsert(at: s, snap: false)
        case "p", "P": paste(after: ch == "p"); resetPending(); return .none
        case "u": undo(); resetPending(); return .none
        case "J":
            let e = lineEndExclusive(cursor)
            if e < text.count { snapshot(); text[e] = " "; cursor = e }
            resetPending(); return .none
        case "~":
            if cursor < text.count { snapshot(); let c = text[cursor]; text[cursor] = Character(c.isUppercase ? c.lowercased() : c.uppercased()); cursor = min(cursor + 1, max(0, lineEndExclusive(cursor) - 1)) }
            resetPending(); return .none
        case "v":
            if mode == .visual { mode = .normal } else { visualAnchor = mode == .normal ? cursor : visualAnchor; mode = .visual }
            resetPending(); return .none
        case "V":
            if mode == .visualLine { mode = .normal } else { visualAnchor = mode == .normal ? cursor : visualAnchor; mode = .visualLine }
            resetPending(); return .none
        case ":", "/", "?":
            mode = .command; commandLine = String(ch); resetPending(); return .none
        case "n", "N":
            resetPending()
            if let q = lastSearch { return .search(q, forward: ch == "n") }
            return .none
        default:
            resetPending(); return .none
        }
    }

    /// Forgets undo/redo history (after the text was replaced from outside, e.g. reloaded from disk).
    public func resetHistory() { undoStack.removeAll(); redoStack.removeAll() }
    /// Saves the current text as an undo point before the host changes it outside the engine (so `u` reverts it).
    public func recordUndoPoint() { snapshot() }

    /// Ctrl-r (redo), routed separately because it carries a modifier.
    public func redo() {
        guard let (t, c) = redoStack.popLast() else { return }
        undoStack.append((text, cursor)); text = t; cursor = c
    }

    // MARK: - Actions

    private func resetPending() { count = nil; pendingOperator = nil; pendingPrefix = nil }

    private func setOperator(_ op: Character) -> VimEffect {
        if mode == .visual || mode == .visualLine { return applyRange(selection ?? cursor..<cursor, op: op) }
        pendingOperator = op; return .none
    }

    private func enterInsert(at pos: Int, snap: Bool = true) -> VimEffect {
        if snap { snapshot() }
        cursor = pos; mode = .insert; resetPending(); return .none
    }

    private func insert(_ s: String) {
        if undoStack.isEmpty { snapshot() }
        for ch in s { text.insert(ch, at: cursor); cursor += 1 }
    }

    /// Runs a motion; moves the cursor, or applies the pending operator over the traversed range.
    private func applyMotion(linewise: Bool = false, inclusive: Bool = false, _ f: (Int) -> Int) -> VimEffect {
        let n = count ?? 1
        let target = f(n)
        if let op = pendingOperator {
            var lo = min(cursor, target), hi = max(cursor, target)
            if linewise { lo = lineRange(at: lo).lowerBound; hi = lineRange(at: hi).upperBound }
            else if inclusive { hi = min(hi + 1, text.count) }
            return applyRange(lo..<hi, linewise: linewise, op: op)
        }
        cursor = target
        clampCursor()
        resetPending()
        return .none
    }

    private func applyRange(_ r: Range<Int>, linewise: Bool = false, op explicit: Character? = nil) -> VimEffect {
        let op = explicit ?? pendingOperator ?? "y"
        let range = r.clamped(to: 0..<text.count)
        resetPending()
        let wasVisual = mode == .visual || mode == .visualLine
        if wasVisual { mode = .normal }
        let yanked = String(text[range])
        switch op {
        case "y":
            register = (yanked, linewise)
            cursor = range.lowerBound
        case "d", "c":
            snapshot()
            register = (yanked, linewise)
            var rr = range
            if op == "c", linewise, rr.upperBound > rr.lowerBound, text[rr.upperBound - 1] == "\n" { rr = rr.lowerBound..<(rr.upperBound - 1) }
            text.removeSubrange(rr)
            cursor = rr.lowerBound
            if op == "c" { mode = .insert } else { clampCursor() }
        case ">", "<":
            snapshot()
            for ls in lineStarts(in: range).reversed() {
                if op == ">" { text.insert("\t", at: ls) }
                else if ls < text.count, text[ls] == "\t" || text[ls] == " " { text.remove(at: ls) }
            }
            cursor = firstNonBlank(range.lowerBound)
        case "\u{1}", "\u{2}", "\u{3}":
            snapshot()
            for i in range {
                let c = text[i]
                text[i] = Character(op == "\u{1}" ? c.lowercased() : op == "\u{2}" ? c.uppercased() : (c.isUppercase ? c.lowercased() : c.uppercased()))
            }
            cursor = range.lowerBound
        default: break
        }
        return .none
    }

    private func paste(after: Bool) {
        guard !register.text.isEmpty else { return }
        snapshot()
        let n = count ?? 1
        let chunk = Array(String(repeating: register.text, count: n))
        if register.linewise {
            var at = after ? lineRange(at: cursor).upperBound : lineRange(at: cursor).lowerBound
            var c = chunk
            if at == text.count, text.last != "\n", after { text.append("\n"); at += 1; if c.last == "\n" { c.removeLast() } }
            text.insert(contentsOf: c, at: at)
            cursor = firstNonBlank(at)
        } else {
            let at = after && cursor < text.count ? cursor + 1 : cursor
            text.insert(contentsOf: chunk, at: at)
            cursor = at + chunk.count - 1
        }
    }

    private func snapshot() { undoStack.append((text, cursor)); redoStack.removeAll() }

    private func undo() {
        guard let (t, c) = undoStack.popLast() else { return }
        redoStack.append((text, cursor)); text = t; cursor = c; clampCursor()
    }

    // MARK: - Geometry helpers

    private var lineCount: Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } - (text.last == "\n" ? 1 : 0) }

    /// Range of the line containing `pos`, including its trailing newline.
    func lineRange(at pos: Int) -> Range<Int> {
        var s = min(pos, text.count)
        while s > 0, text[s - 1] != "\n" { s -= 1 }
        var e = min(pos, text.count)
        while e < text.count, text[e] != "\n" { e += 1 }
        if e < text.count { e += 1 }
        return s..<e
    }

    private func lineEndExclusive(_ pos: Int) -> Int {
        let r = lineRange(at: pos)
        return r.upperBound > r.lowerBound && r.upperBound <= text.count && r.upperBound > 0 && text[r.upperBound - 1] == "\n" ? r.upperBound - 1 : r.upperBound
    }

    private func lastInLine(_ pos: Int) -> Int { max(lineRange(at: pos).lowerBound, lineEndExclusive(pos) - 1) }

    private func lineStart(ofLine n: Int) -> Int {
        var line = 0, i = 0
        let target = max(0, n)
        while i < text.count, line < target { if text[i] == "\n" { line += 1 }; i += 1 }
        return i
    }

    private func lineStarts(in r: Range<Int>) -> [Int] {
        var out = [lineRange(at: r.lowerBound).lowerBound]
        var i = out[0]
        while i < r.upperBound, i < text.count {
            let nl = lineRange(at: i).upperBound
            if nl < r.upperBound, nl < text.count { out.append(nl) }
            if nl == i { break }
            i = nl
        }
        return out
    }

    private func lineSpan(count n: Int) -> Range<Int> {
        let s = lineRange(at: cursor).lowerBound
        var e = s
        for _ in 0..<max(1, n) { let next = lineRange(at: e).upperBound; if next == e { break }; e = next }
        return s..<e
    }

    private func firstNonBlank(_ pos: Int) -> Int {
        let r = lineRange(at: pos)
        var i = r.lowerBound
        while i < r.upperBound, text[i] == " " || text[i] == "\t" { i += 1 }
        return min(i, max(r.lowerBound, lastInLine(pos)))
    }

    private func moveRight(_ n: Int) -> Int { min(cursor + n, lastInLine(cursor) + (pendingOperator != nil ? 1 : 0)) }

    private func moveVertical(_ delta: Int) -> Int {
        let col = cursor - lineRange(at: cursor).lowerBound
        var pos = lineRange(at: cursor).lowerBound
        if delta > 0 {
            for _ in 0..<delta { let n = lineRange(at: pos).upperBound; if n >= text.count { break }; pos = n }
        } else {
            for _ in 0..<(-delta) { if pos == 0 { break }; pos = lineRange(at: pos - 1).lowerBound }
        }
        let r = lineRange(at: pos)
        return min(r.lowerBound + col, max(r.lowerBound, lastInLine(pos)))
    }

    private func clampCursor() {
        cursor = min(max(0, cursor), max(0, text.count))
        if mode == .normal || mode == .visual || mode == .visualLine, cursor >= text.count { cursor = max(0, text.count - 1) }
        if mode == .normal, cursor < text.count, text[cursor] == "\n", cursor > lineRange(at: cursor).lowerBound { cursor -= 1 }
    }

    private enum CharClass { case space, word, punct }
    private func cls(_ c: Character) -> CharClass { c.isWhitespace ? .space : (c.isLetter || c.isNumber || c == "_") ? .word : .punct }

    private func wordForward(_ n: Int) -> Int {
        var i = cursor
        for _ in 0..<n {
            guard i < text.count else { break }
            let c = cls(text[i])
            if c != .space { while i < text.count, cls(text[i]) == c { i += 1 } }
            while i < text.count, cls(text[i]) == .space, !(text[i] == "\n" && i + 1 < text.count && text[i + 1] == "\n") { i += 1 }
        }
        return min(i, text.count)
    }

    private func wordBackward(_ n: Int) -> Int {
        var i = cursor
        for _ in 0..<n {
            while i > 0, cls(text[i - 1]) == .space { i -= 1 }
            guard i > 0 else { break }
            let c = cls(text[i - 1])
            while i > 0, cls(text[i - 1]) == c { i -= 1 }
        }
        return i
    }

    private func wordEnd(_ n: Int) -> Int {
        var i = cursor
        for _ in 0..<n {
            if i + 1 < text.count { i += 1 }
            while i < text.count, cls(text[i]) == .space { i += 1 }
            guard i < text.count else { return text.count - 1 }
            let c = cls(text[i])
            while i + 1 < text.count, cls(text[i + 1]) == c { i += 1 }
        }
        return min(i, max(0, text.count - 1))
    }

    private func paragraph(_ n: Int) -> Int {
        var i = cursor
        let step = n > 0 ? 1 : -1
        for _ in 0..<abs(n) {
            i += step
            while i > 0, i < text.count - 1, !(text[i] == "\n" && (i == 0 || text[i - 1] == "\n")) { i += step }
        }
        return min(max(0, i), max(0, text.count - 1))
    }

    private func findChar(_ kind: Character, _ target: Character, count n: Int) -> Int {
        let r = lineRange(at: cursor)
        var i = cursor, left = n
        let forward = kind == "f" || kind == "t"
        while left > 0 {
            i += forward ? 1 : -1
            guard i >= r.lowerBound, i < r.upperBound else { return cursor }
            if text[i] == target { left -= 1 }
        }
        if kind == "t" { i -= 1 } else if kind == "T" { i += 1 }
        return i
    }

    private func matchBracket(_ pos: Int) -> Int {
        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", ")": "(", "]": "[", "}": "{"]
        var i = pos
        let r = lineRange(at: pos)
        while i < r.upperBound, pairs[text[i]] == nil { i += 1 }
        guard i < text.count, let match = pairs[text[i]] else { return pos }
        let open = text[i]
        let forward = "([{".contains(open)
        var depth = 0
        var j = i
        while j >= 0, j < text.count {
            if text[j] == open { depth += 1 } else if text[j] == match { depth -= 1; if depth == 0 { return j } }
            j += forward ? 1 : -1
        }
        return pos
    }

    /// Text objects: iw aw ip ap i" a" i( a( i{ a{ i[ a[.
    private func textObject(inner: Bool, _ ch: Character) -> Range<Int>? {
        guard !text.isEmpty else { return nil }
        switch ch {
        case "w":
            let pos = min(cursor, text.count - 1)
            let c = cls(text[pos])
            var s = pos, e = pos + 1
            while s > 0, cls(text[s - 1]) == c { s -= 1 }
            while e < text.count, cls(text[e]) == c { e += 1 }
            if !inner { while e < text.count, cls(text[e]) == .space, text[e] != "\n" { e += 1 } }
            return s..<e
        case "p":
            var s = lineRange(at: cursor).lowerBound, e = lineRange(at: cursor).upperBound
            func blank(_ p: Int) -> Bool { let r = lineRange(at: p); return text[r].allSatisfy { $0.isWhitespace } }
            while s > 0, !blank(s - 1) { s = lineRange(at: s - 1).lowerBound }
            while e < text.count, !blank(e) { e = lineRange(at: e).upperBound }
            if !inner { while e < text.count, blank(e) { e = lineRange(at: e).upperBound } }
            return s..<e
        case "\"", "'", "`":
            let r = lineRange(at: cursor)
            let idx = (r.lowerBound..<r.upperBound).filter { text[$0] == ch }
            for k in stride(from: 0, to: idx.count - 1, by: 2) where idx[k] <= cursor && cursor <= idx[k + 1] {
                return inner ? (idx[k] + 1)..<idx[k + 1] : idx[k]..<(idx[k + 1] + 1)
            }
            return nil
        case "(", ")", "b", "[", "]", "{", "}", "B":
            let (o, c): (Character, Character) = "()b".contains(ch) ? ("(", ")") : "[]".contains(ch) ? ("[", "]") : ("{", "}")
            var depth = 0, s = cursor
            if s < text.count, text[s] == o { } else {
                while s >= 0 {
                    if s < text.count { if text[s] == c { depth += 1 } else if text[s] == o { if depth == 0 { break }; depth -= 1 } }
                    s -= 1
                }
            }
            guard s >= 0, s < text.count, text[s] == o else { return nil }
            depth = 0
            var e = s
            while e < text.count {
                if text[e] == o { depth += 1 } else if text[e] == c { depth -= 1; if depth == 0 { break } }
                e += 1
            }
            guard e < text.count else { return nil }
            return inner ? (s + 1)..<e : s..<(e + 1)
        default: return nil
        }
    }
}

private extension Range where Bound == Int {
    func clamped(to limits: Range<Int>) -> Range<Int> {
        let lo = Swift.min(Swift.max(lowerBound, limits.lowerBound), limits.upperBound)
        let hi = Swift.min(Swift.max(upperBound, lo), limits.upperBound)
        return lo..<hi
    }
}
