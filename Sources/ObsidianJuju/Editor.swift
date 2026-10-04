import AppKit
import ObsidianJujuCore
import SwiftUI

/// One note unlocked for editing in one tab. Created only by an explicit unlock (header lock button,
/// CC+E or the palette) and dropped as soon as the tab moves to another note, switches away, or closes —
/// so every note is read-only again by default. Saves go through `NoteWriter` (the only vault writer),
/// automatically about a second after typing stops, like Obsidian.
@MainActor
final class EditSession: ObservableObject {
    enum Status: Equatable { case saved, unsaved, failed(String) }

    let root: URL
    let path: String
    @Published var showPreview = false
    @Published private(set) var status: Status = .saved
    /// The note changed on disk (e.g. in Obsidian) while it had unsaved edits here. Autosave stops until
    /// the user picks a side.
    @Published private(set) var conflict = false
    /// Vim mode or command line ("NORMAL", ":wq", …); empty when Vim is off.
    @Published var vimLabel = ""
    /// App-level Vim ex commands (`:w`, `:q`, …), handled by the model.
    var onEx: ((String) -> Void)?

    /// Disk content as of the last load or save; saves only proceed while disk still equals it.
    private(set) var baseline: String
    private(set) var text: String
    weak var textView: NSTextView?
    /// Styles and inline images while editing (set up by `NoteEditorView`).
    var livePreview: LivePreview?
    /// For live preview's inline images (set by `VaultModel.unlock`).
    var resolveImage: ((String) -> EditorImageSource?)?
    var decryptImage: (@Sendable (Data) -> Data?)?
    /// Right-click "Open link" / "Open in new tab" on a link in the editor.
    var openLink: ((String, Bool) -> Void)?
    /// Saves an image on the clipboard into the vault and inserts its embed; false = paste normally.
    var pasteImage: (() -> Bool)?
    private var saveTask: Task<Void, Never>?
    static let autosaveDelay: UInt64 = 1_000_000_000

    init?(root: URL, path: String) {
        guard let disk = NoteWriter.load(root: root, path: path) else { return nil }
        self.root = root
        self.path = path
        baseline = disk
        text = disk
    }

    func textDidChange(_ s: String) {
        text = s
        status = s == baseline ? .saved : .unsaved
        saveTask?.cancel()
        guard !conflict, status == .unsaved else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes pending edits now (before locking, switching views or quitting).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func save() {
        guard !conflict, text != baseline else { return }
        switch NoteWriter.save(text, root: root, path: path, baseline: baseline) {
        case .saved, .unchanged:
            baseline = text
            status = .saved
        case .conflict:
            conflict = true
        case .failed(let message):
            status = .failed(message)
        }
    }

    /// Called when the vault watcher reports this note changed on disk.
    func diskChanged() {
        guard let disk = NoteWriter.load(root: root, path: path), disk != baseline else { return }
        if text == baseline || text == disk {
            replaceText(with: disk)
        } else {
            saveTask?.cancel()
            conflict = true
        }
    }

    /// Conflict resolution: discard edits here and take the disk version.
    func useDiskVersion() {
        guard let disk = NoteWriter.load(root: root, path: path) else { return }
        conflict = false
        replaceText(with: disk)
    }

    /// Conflict resolution: overwrite the disk version with the text here.
    func keepMine() {
        guard let disk = NoteWriter.load(root: root, path: path) else { return }
        baseline = disk
        conflict = false
        flush()
    }

    private func replaceText(with disk: String) {
        baseline = disk
        text = disk
        status = .saved
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        tv.string = disk
        restyle()
        tv.setSelectedRange(NSRange(location: min(sel.location, (disk as NSString).length), length: 0))
        tv.undoManager?.removeAllActions()
        (tv as? VimTextView)?.textReplaced()
    }

    /// Types `snippet` at the caret like a paste (undoable, autosaved).
    func insert(_ snippet: String) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        if let vtv = tv as? VimTextView, vtv.vimActive {
            vtv.syncFromView()
            vtv.vim.recordUndoPoint()
        }
        tv.insertText(snippet, replacementRange: tv.selectedRange())
        (tv as? VimTextView)?.syncFromView()
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    /// Re-applies the editor font and live preview styles (after settings changes or a reload).
    func restyle() {
        if let livePreview { livePreview.restyle() } else if let tv = textView { EditorStyle.apply(to: tv) }
    }

    /// "Add file property" (CC+;): the Properties panel's new-property row.
    func addProperty() {
        livePreview?.beginAddingProperty()
    }

    /// Toggles bold / italic / … around the selection (CC+B, CC+I and the palette's "Toggle …" commands).
    func toggle(_ format: MarkdownStyle.Format) {
        guard let tv = textView else { return }
        let edit = MarkdownStyle.toggle(format, in: tv.string, selection: tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
        if let vtv = tv as? VimTextView, vtv.vimActive {
            vtv.syncFromView()
            vtv.vim.recordUndoPoint()
        }
        tv.insertText(edit.replacement, replacementRange: edit.range)
        tv.setSelectedRange(edit.selection)
        (tv as? VimTextView)?.syncFromView()
    }

    func focus() {
        guard let tv = textView else { return }
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }

    func showFindBar() {
        guard let tv = textView else { return }
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        tv.window?.makeFirstResponder(tv)
        tv.performTextFinderAction(item)
    }

    /// Moves the caret to a heading (outline clicks while editing).
    func reveal(heading: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var found: NSRange?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, _, stop in
            guard let line, line.hasPrefix("#") else { return }
            let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            if title == heading { found = range; stop.pointee = true }
        }
        guard let range = found else { return }
        tv.setSelectedRange(NSRange(location: range.location, length: 0))
        tv.scrollRangeToVisible(range)
        focus()
    }
}

/// Font, colours and line spacing for the source editor, following the note view's settings.
@MainActor
enum EditorStyle {
    static var font: NSFont {
        let d = UserDefaults.standard
        let size = d.object(forKey: SettingsKey.fontSize) as? Double ?? SettingsKey.defaultFontSize
        let zoom = d.object(forKey: SettingsKey.zoom) as? Double ?? 1
        return NSFont.systemFont(ofSize: size * zoom)
    }

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.35
        return p
    }

    static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor(Theme.textNormal), .paragraphStyle: paragraph]
    }

    static func apply(to tv: NSTextView) {
        let attrs = attributes
        tv.typingAttributes = attrs
        tv.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: tv.string.utf16.count))
    }
}

/// Keeps the text column at Obsidian's readable line length (700px, scaled with zoom) when that setting is on.
final class EditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let tv = documentView as? NSTextView else { return }
        let d = UserDefaults.standard
        let readable = d.object(forKey: SettingsKey.readableLineWidth) as? Bool ?? true
        let zoom = d.object(forKey: SettingsKey.zoom) as? Double ?? 1
        let side = readable ? max(32, (contentSize.width - 700 * zoom) / 2) : 32
        if abs(tv.textContainerInset.width - side) > 0.5 { tv.textContainerInset = NSSize(width: side, height: 28) }
    }
}

/// Plain-text Markdown editor (NSTextView). A native view so the Vim engine from Notepad+++ can drop in later.
struct NoteEditorView: NSViewRepresentable {
    @ObservedObject var session: EditSession
    var active: Bool

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> EditorScrollView {
        let scroll = EditorScrollView()
        scroll.hasVerticalScroller = true
        // Overlay scrollers never take width, so the text width (and image/panel sizes) can't oscillate.
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.backgroundPrimary)
        // TextKit 1, so live preview can hide Markdown syntax glyphs (NSLayoutManager delegate) and draw callouts.
        let storage = NSTextStorage()
        let layout = JujuLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let tv = VimTextView(frame: .zero, textContainer: container)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        // Markdown is code-like: no smart quotes/dashes, autocorrect or text replacement.
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = false
        tv.insertionPointColor = NSColor(Theme.accent)
        tv.string = session.text
        let preview = LivePreview(textView: tv)
        preview.resolveImage = session.resolveImage
        preview.decrypt = session.decryptImage
        session.livePreview = preview
        tv.delegate = context.coordinator
        let session = session
        tv.onEx = { [weak session] cmd in session?.onEx?(cmd) }
        tv.onPasteImage = { [weak session] in session?.pasteImage?() ?? false }
        tv.onOpenLink = { [weak session] target, newTab in session?.openLink?(target, newTab) }
        tv.onStateChange = { [weak session] label in
            if session?.vimLabel != label { session?.vimLabel = label }
        }
        // Start at the top of the body (not after the last character), so Properties show as a panel.
        tv.setSelectedRange(NSRange(location: LivePreview.isEnabled ? LivePreview.bodyStart(of: tv.string) : 0, length: 0))
        tv.syncFromView()
        session.vimLabel = tv.modeLabel
        scroll.documentView = tv
        session.textView = tv
        preview.restyle()
        if active { session.focus() }
        return scroll
    }

    func updateNSView(_ scroll: EditorScrollView, context: Context) {
        guard let tv = scroll.documentView as? VimTextView else { return }
        session.textView = tv
        if session.vimLabel != tv.modeLabel { DispatchQueue.main.async { session.vimLabel = tv.modeLabel } }
        tv.needsDisplay = true
        // Font size or zoom changed in Settings (not just a different font at the caret).
        if let preview = session.livePreview, preview.appliedFont != EditorStyle.font {
            DispatchQueue.main.async { session.restyle() }
        }
        scroll.needsLayout = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: EditSession
        init(session: EditSession) { self.session = session }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            MainActor.assumeIsolated {
                session.textDidChange(tv.string)
                session.livePreview?.restyle()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated { session.livePreview?.selectionChanged() }
        }
    }
}

/// Header controls for a note: the lock (read-only ⇄ editing), and while editing the editor/preview toggle
/// and save status.
struct EditControls: View {
    @ObservedObject var model: VaultModel
    let tabID: UUID
    let path: String

    var body: some View {
        let m = HotkeyModifier.current.symbol
        if let session = model.editSessions[tabID] {
            EditingControls(model: model, session: session, tabID: tabID)
        } else if NoteWriter.isEditable(path) {
            Button { model.unlock(tabID: tabID) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("Read-only").font(Theme.smallFont)
                }
                .padding(.horizontal, 6).frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textFaint)
            .help("Unlock this note for editing (\(m)E). It locks again when you leave it.")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("Read-only").font(Theme.smallFont)
            }
            .foregroundStyle(Theme.textFaint)
            .help("Only Markdown notes can be edited")
        }
    }
}

private struct EditingControls: View {
    @ObservedObject var model: VaultModel
    @ObservedObject var session: EditSession
    let tabID: UUID

    var body: some View {
        let m = HotkeyModifier.current.symbol
        HStack(spacing: 4) {
            switch session.status {
            case .saved: Text("Saved").font(Theme.smallFont).foregroundStyle(Theme.textFaint)
            case .unsaved: Text("Unsaved").font(Theme.smallFont).foregroundStyle(Theme.textFaint)
            case .failed(let msg): Text("Not saved").font(Theme.smallFont).foregroundStyle(.red).help(msg)
            }
            IconButton(symbol: session.showPreview ? "pencil" : "book",
                       help: session.showPreview ? "Back to editing (\(m)E)" : "Preview (\(m)E)") {
                model.togglePreview(tabID: tabID)
            }
            Button { model.lock(tabID: tabID) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lock.open.fill").font(.system(size: 10))
                    Text("Editing").font(Theme.smallFont)
                }
                .padding(.horizontal, 6).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.14)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help("Lock this note (read-only)")
        }
    }
}

/// Shown above the editor when the note changed on disk while it had unsaved edits here.
struct ConflictBar: View {
    @ObservedObject var session: EditSession

    var body: some View {
        if session.conflict {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("This note changed on disk (maybe in Obsidian) while you had unsaved edits. Autosave is paused.")
                    .font(Theme.uiFont).foregroundStyle(Theme.textNormal)
                Spacer()
                Button("Use disk version") { session.useDiskVersion() }
                Button("Keep my version") { session.keepMine() }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
    }
}
