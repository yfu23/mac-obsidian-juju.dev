import AppKit
import UniformTypeIdentifiers
import ObsidianJujuCore

/// The note editor's text view: plain NSTextView, or modal Vim editing when Settings → "Vim keybindings" is on.
/// Ported from Notepad+++'s EditorTextView (same VimEngine, keys, block cursor and escape chord).
/// Text-only ex commands (`:42`, `:s/…/…/g`, `:%s`) and `/` `?` search run here; the rest go to `onEx`.
final class VimTextView: NSTextView {
    let vim = VimEngine()
    /// App-level ex commands (`:w`, `:q`, `:wq`, `:tabnew`, …).
    var onEx: ((String) -> Void)?
    /// Mode or command line changed.
    var onStateChange: ((String) -> Void)?
    /// Paste: returns true when it handled an image on the clipboard (saved as an attachment, like Obsidian).
    var onPasteImage: (() -> Bool)?
    /// Opens a link target (`Note#Heading`, a URL); the Bool is "in a new tab".
    var onOpenLink: ((String, Bool) -> Void)?
    private var menuLinkTarget: String?
    private var pendingEscape: (Character, Date)?

    var vimActive: Bool { UserDefaults.standard.bool(forKey: SettingsKey.vimEnabled) }
    var modeLabel: String {
        guard vimActive else { return "" }
        switch vim.mode {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        case .visualLine: return "V-LINE"
        case .command: return vim.commandLine
        }
    }

    /// The text was replaced from outside (reloaded from disk): drop Vim's undo history for the old text.
    func textReplaced() {
        vim.resetHistory()
        syncFromView()
        notifyState()
    }

    // MARK: Key handling

    /// Right-click on a `[[link]]`, `[text](link)` or embed: "Open link" and "Open in new tab" at the top.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard onOpenLink != nil, index < (string as NSString).length,
              let target = MarkdownStyle.linkTarget(in: string, at: index), !target.isEmpty else { return menu }
        menuLinkTarget = target
        let open = NSMenuItem(title: "Open link", action: #selector(openMenuLink(_:)), keyEquivalent: "")
        let newTab = NSMenuItem(title: "Open in new tab", action: #selector(openMenuLink(_:)), keyEquivalent: "")
        newTab.tag = 1
        for item in [open, newTab] { item.target = self }
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(newTab, at: 0)
        menu.insertItem(open, at: 0)
        return menu
    }

    @objc private func openMenuLink(_ sender: NSMenuItem) {
        guard let target = menuLinkTarget else { return }
        onOpenLink?(target, sender.tag == 1)
    }

    override func paste(_ sender: Any?) {
        if onPasteImage?() == true { return }
        super.paste(sender)
    }

    /// A plain-text view disables Edit → Paste (CC+V) when the clipboard has no text; keep it on for images.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPasteImage != nil, isEditable, Self.clipboardHasImage(.general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    static func clipboardHasImage(_ pb: NSPasteboard) -> Bool {
        pb.canReadItem(withDataConformingToTypes: [UTType.png.identifier, UTType.tiff.identifier])
            || pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                                                   .urlReadingContentsConformToTypes: [UTType.image.identifier]])
    }

    /// Obsidian's keys: Home / End = start / end of the line, CC+↑ / CC+↓ = start / end of the note (Shift extends
    /// the selection). macOS text views otherwise only scroll on Home / End.
    private func handleNavigation(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let shift = flags.contains(.shift), rest = flags.subtracting(.shift)
        let action: Selector
        switch event.keyCode {
        case 115 where rest.isEmpty:
            action = shift ? #selector(moveToBeginningOfLineAndModifySelection(_:)) : #selector(moveToBeginningOfLine(_:))
        case 119 where rest.isEmpty:
            action = shift ? #selector(moveToEndOfLineAndModifySelection(_:)) : #selector(moveToEndOfLine(_:))
        case 126 where rest == HotkeyModifier.current.eventFlags:
            action = shift ? #selector(moveToBeginningOfDocumentAndModifySelection(_:)) : #selector(moveToBeginningOfDocument(_:))
        case 125 where rest == HotkeyModifier.current.eventFlags:
            action = shift ? #selector(moveToEndOfDocumentAndModifySelection(_:)) : #selector(moveToEndOfDocument(_:))
        default:
            return false
        }
        // Vim Normal/Visual mode maps plain Home / End to 0 / $ itself (so Visual selections extend).
        if vimActive, vim.mode != .insert, event.keyCode == 115 || event.keyCode == 119, !shift { return false }
        doCommand(by: action)
        if vimActive { syncFromView(); notifyState() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleNavigation(event) { return }
        guard vimActive else { super.keyDown(with: event); return }
        // Arrow keys drive the engine (h/j/k/l; End = $, Home = 0) outside Insert mode, so Visual selections extend.
        let arrows: [UInt16: String] = [123: "h", 124: "l", 125: "j", 126: "k", 119: "$", 115: "0"]
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if vim.mode != .insert, let mapped = arrows[event.keyCode], plain {
            if vim.mode == .command { return }
            feed(mapped); return
        }
        // Insert mode: macOS End/Home only scroll, so move the caret explicitly.
        if vim.mode == .insert, plain {
            if event.keyCode == 119 { moveToEndOfLine(nil); syncFromView(); notifyState(); return }
            if event.keyCode == 115 { moveToBeginningOfLine(nil); syncFromView(); notifyState(); return }
        }
        guard let key = Self.keyName(event) else { super.keyDown(with: event); return }

        // Escape chord (e.g. "jk") while inserting.
        let chord = UserDefaults.standard.string(forKey: SettingsKey.escapeChord) ?? ""
        if vim.mode == .insert, chord.count == 2, key.count == 1 {
            let first = chord.first!, second = chord.last!
            if let p = pendingEscape, p.0 == first, Character(key) == second, Date().timeIntervalSince(p.1) < 0.4 {
                pendingEscape = nil
                super.deleteBackward(nil)          // remove the first chord char already inserted
                feed("Escape"); return
            }
            pendingEscape = Character(key) == first ? (first, Date()) : nil
        }
        if vim.mode == .insert, key != "Escape", !event.modifierFlags.contains(.control) {
            super.keyDown(with: event)             // AppKit inserts (IME, undo grouping); the engine mirrors on change
            syncFromView()
            notifyState()
            return
        }
        feed(key)
    }

    /// Vim's Ctrl keys in Normal/Visual mode: Ctrl-r redo, Ctrl-d/u half page, Ctrl-f/b page.
    /// (With CC = Ctrl the app's hotkey monitor lets these through; see `Hotkeys`.)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlesVimControlKey(event) {
            let ch = event.charactersIgnoringModifiers ?? ""
            syncFromView()
            if ch == "r" { vim.redo() } else {
                let page = ch == "d" || ch == "u" ? 10 : 20
                for _ in 0..<page { vim.handle(ch == "d" || ch == "f" ? "j" : "k") }
            }
            syncToView()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func handlesVimControlKey(_ event: NSEvent) -> Bool {
        vimActive && vim.mode != .insert && window?.firstResponder === self
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock]) == .control
            && ["r", "d", "u", "f", "b"].contains(event.charactersIgnoringModifiers ?? "")
    }

    private func feed(_ key: String) {
        syncFromView()
        let effect = vim.handle(key)
        syncToView()
        switch effect {
        case .ex(let cmd): runEx(cmd)
        case .search(let q, let forward): search(q, forward: forward)
        case .none: break
        }
    }

    static func keyName(_ e: NSEvent) -> String? {
        switch e.keyCode {
        case 53: return "Escape"
        case 36, 76: return "Enter"
        case 51: return "Backspace"
        case 48: return "Tab"
        case 123, 124, 125, 126: return nil
        default: break
        }
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) { return nil }
        return e.characters
    }

    private func notifyState() {
        onStateChange?(modeLabel)
    }

    // MARK: Ex commands and search (text-only ones)

    private func runEx(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(cmd) { goto(line: n); return }
        if cmd.hasPrefix("s/") || cmd.hasPrefix("%s/") { substitute(cmd); return }
        onEx?(cmd)
    }

    private func goto(line: Int) {
        let ns = string as NSString
        var loc = 0, l = 1
        while l < line, loc < ns.length { loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0))); l += 1 }
        setSelectedRange(NSRange(location: min(loc, ns.length), length: 0))
        scrollRangeToVisible(selectedRange())
        syncFromView()
        notifyState()
    }

    private func search(_ q: String, forward: Bool) {
        let ns = string as NSString
        let from = selectedRange().location
        var r: NSRange
        if forward {
            let start = min(from + 1, ns.length)
            r = ns.range(of: q, options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
            if r.location == NSNotFound { r = ns.range(of: q, options: .caseInsensitive) }
        } else {
            r = ns.range(of: q, options: [.caseInsensitive, .backwards], range: NSRange(location: 0, length: from))
            if r.location == NSNotFound { r = ns.range(of: q, options: [.caseInsensitive, .backwards]) }
        }
        guard r.location != NSNotFound else { NSSound.beep(); return }
        setSelectedRange(NSRange(location: r.location, length: 0))
        scrollRangeToVisible(r)
        syncFromView()
        showFindIndicator(for: r)
        notifyState()
    }

    /// `:s/pat/rep/[g]` on the current line, `:%s/…` on the whole note (regex; `$1` in the replacement).
    private func substitute(_ cmd: String) {
        let whole = cmd.hasPrefix("%")
        let body = cmd.drop { $0 != "s" }.dropFirst(2)
        let seg = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard seg.count >= 2, let re = try? NSRegularExpression(pattern: seg[0]) else { NSSound.beep(); return }
        let global = seg.count > 2 && seg[2].contains("g")
        let ns = string as NSString
        let range = whole ? NSRange(location: 0, length: ns.length) : ns.lineRange(for: selectedRange())
        let src = ns.substring(with: range)
        // Vim semantics: without /g only the first match on each line is replaced.
        let out = src.components(separatedBy: "\n").map { line -> String in
            let l = line as NSString
            var res = "", last = 0
            for m in re.matches(in: line, range: NSRange(location: 0, length: l.length)) {
                res += l.substring(with: NSRange(location: last, length: m.range.location - last))
                res += re.replacementString(for: m, in: line, offset: 0, template: seg[1])
                last = NSMaxRange(m.range)
                if !global { break }
            }
            return res + l.substring(from: last)
        }.joined(separator: "\n")
        guard out != src else { return }
        insertText(out, replacementRange: range)
        syncFromView()
        notifyState()
    }

    // MARK: Engine <-> view sync

    func syncFromView() {
        // In visual modes the engine's cursor is authoritative (selectedRange().location is only the start).
        let visual = vim.mode == .visual || vim.mode == .visualLine
        vim.load(string, cursor: visual ? vim.cursor : charOffset(fromUTF16: selectedRange().location))
    }

    func syncToView() {
        let newText = vim.string
        if newText != string {
            let old = string as NSString, new = newText as NSString
            var p = 0
            let maxP = min(old.length, new.length)
            while p < maxP, old.character(at: p) == new.character(at: p) { p += 1 }
            var s = 0
            while s < maxP - p, old.character(at: old.length - 1 - s) == new.character(at: new.length - 1 - s) { s += 1 }
            let oldRange = NSRange(location: p, length: old.length - p - s)
            let repl = new.substring(with: NSRange(location: p, length: new.length - p - s))
            if shouldChangeText(in: oldRange, replacementString: repl) {
                textStorage?.replaceCharacters(in: oldRange, with: repl)
                didChangeText()
            }
        }
        if let sel = vim.selection {
            let lo = utf16Offset(fromChar: sel.lowerBound), hi = utf16Offset(fromChar: sel.upperBound)
            setSelectedRange(NSRange(location: lo, length: hi - lo))
        } else {
            setSelectedRange(NSRange(location: utf16Offset(fromChar: vim.cursor), length: 0))
        }
        scrollRangeToVisible(selectedRange())
        needsDisplay = true
        notifyState()
    }

    private func utf16Offset(fromChar c: Int) -> Int { String(vim.text[0..<min(c, vim.text.count)]).utf16.count }
    private func charOffset(fromUTF16 u: Int) -> Int {
        let s = string as NSString
        return s.substring(to: min(u, s.length)).count
    }

    // MARK: Block cursor outside Insert mode

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard vimActive, vim.mode != .insert, let lm = layoutManager, let tc = textContainer else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag); return
        }
        guard flag else { needsDisplay = true; return }
        let loc = selectedRange().location
        var r = rect
        if loc < (string as NSString).length {
            let g = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: 1), actualCharacterRange: nil)
            r = lm.boundingRect(forGlyphRange: g, in: tc)
            r.origin.x += textContainerInset.width; r.origin.y += textContainerInset.height
            if r.width < 2 { r.size.width = rect.width + 6 }
        } else { r.size.width = 8 }
        color.withAlphaComponent(0.5).setFill(); r.fill()
    }
    override var shouldDrawInsertionPoint: Bool { true }
}
