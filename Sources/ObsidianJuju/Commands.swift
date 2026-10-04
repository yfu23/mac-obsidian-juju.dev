import AppKit
import ObsidianJujuCore
import SwiftUI

/// A command palette entry. Titles follow Obsidian's "Plugin: Action" naming.
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var hint: String = ""
    let action: @MainActor () -> Void
}

extension VaultModel {
    func paletteCommands() -> [PaletteCommand] {
        let m = HotkeyModifier.current.symbol
        return [
            .init(id: "newNote", title: "Create new note", hint: "\(m)N") { self.beginNewNote() },
            .init(id: "cloneNote", title: "Duplicate current file") { self.duplicateFile() },
            .init(id: "deleteFile", title: "Delete current file") { self.requestDelete() },
            .init(id: "switcher", title: "Quick switcher: Open quick switcher", hint: "\(m)O") { self.overlay = .switcher },
            .init(id: "search", title: "Search: Search in all files", hint: "\(m)⇧F") { self.focusSearch() },
            .init(id: "find", title: "Search current file", hint: "\(m)F") { self.showFind() },
            .init(id: "back", title: "Navigate back", hint: "\(m)⌥←") { self.goBack() },
            .init(id: "forward", title: "Navigate forward", hint: "\(m)⌥→") { self.goForward() },
            .init(id: "newTab", title: "New tab", hint: "\(m)T") { self.newTab() },
            .init(id: "closeTab", title: "Close current tab", hint: "\(m)W") { self.closeTab() },
            .init(id: "reopenTab", title: "Undo close tab", hint: "\(m)⇧T") { self.reopenClosedTab() },
            .init(id: "nextTab", title: "Go to next tab", hint: "⌃Tab") { self.selectTab(offset: 1) },
            .init(id: "prevTab", title: "Go to previous tab", hint: "⌃⇧Tab") { self.selectTab(offset: -1) },
            .init(id: "toggleLeft", title: "Toggle left sidebar") { self.showLeft.toggle() },
            .init(id: "toggleRight", title: "Toggle right sidebar") { self.showRight.toggle() },
            .init(id: "files", title: "Files: Show file explorer") { self.showLeft = true; self.leftPane = .files },
            .init(id: "reveal", title: "Files: Reveal current file in navigation") { self.revealActiveFile() },
            .init(id: "collapse", title: "Files: Collapse all folders") { self.expandedFolders = [] },
            .init(id: "tags", title: "Tags view: Show tags") { self.showLeft = true; self.leftPane = .tags },
            .init(id: "outline", title: "Outline: Show outline") { self.showRight = true; self.rightPane = .outline },
            .init(id: "backlinks", title: "Backlinks: Show backlinks") { self.showRight = true; self.rightPane = .backlinks },
            .init(id: "outgoing", title: "Outgoing links: Show outgoing links") { self.showRight = true; self.rightPane = .outgoing },
            .init(id: "random", title: "Random note: Open random note") { self.openRandomNote() },
            .init(id: "toggleEdit", title: "Toggle editing / reading view (unlocks this note)", hint: "\(m)E") { self.toggleEdit() },
            .init(id: "unlock", title: "Edit mode: Unlock current note for editing") {
                if let id = self.activeTabID { self.unlock(tabID: id) }
            },
            .init(id: "lock", title: "Edit mode: Lock current note (read-only)") {
                if let id = self.activeTabID { self.lock(tabID: id) }
            },
            .init(id: "bold", title: "Toggle bold", hint: "\(m)B") { self.toggleFormat(.bold) },
            .init(id: "italic", title: "Toggle italics", hint: "\(m)I") { self.toggleFormat(.italic) },
            .init(id: "strike", title: "Toggle strikethrough") { self.toggleFormat(.strikethrough) },
            .init(id: "highlight", title: "Toggle highlight") { self.toggleFormat(.highlight) },
            .init(id: "boldItalic", title: "Toggle bold and italic") { self.toggleFormat(.boldItalic) },
            .init(id: "addProperty", title: "Add file property", hint: "\(m);") { self.addFileProperty() },
            .init(id: "livePreview", title: "Toggle Live Preview/Source mode") { self.toggleLivePreview() },
            .init(id: "insertExternal", title: "Insert external image") { self.beginInsertExternalImage() },
            .init(id: "jujuPixUnlock", title: "JujuPix: Unlock encrypted photos") { self.requestJujuPixUnlock() },
            .init(id: "jujuPixLock", title: "JujuPix: Lock encrypted photos") { self.lockJujuPix() },
            .init(id: "vim", title: "Vim: Toggle Vim keybindings in the editor") {
                let d = UserDefaults.standard
                d.set(!d.bool(forKey: SettingsKey.vimEnabled), forKey: SettingsKey.vimEnabled)
                self.flash(d.bool(forKey: SettingsKey.vimEnabled) ? "Vim keybindings on" : "Vim keybindings off")
            },
            .init(id: "obsidian", title: "Open current file in Obsidian (to edit)") { self.openInObsidian() },
            .init(id: "defaultApp", title: "Open current file in default app") { self.openInDefaultApp() },
            .init(id: "finder", title: "Reveal current file in Finder") { self.revealInFinder() },
            .init(id: "copyPath", title: "Copy file path") { self.copyPath(absolute: false) },
            .init(id: "copyFullPath", title: "Copy full file path") { self.copyPath(absolute: true) },
            .init(id: "copyURL", title: "Copy Obsidian URL") { self.copyObsidianURL() },
            .init(id: "zoomIn", title: "Zoom in", hint: "\(m)=") { self.zoom(0.1) },
            .init(id: "zoomOut", title: "Zoom out", hint: "\(m)-") { self.zoom(-0.1) },
            .init(id: "zoomReset", title: "Reset zoom", hint: "\(m)0") { self.zoom(nil) },
            .init(id: "readable", title: "Toggle readable line length") {
                let d = UserDefaults.standard
                d.set(!(d.object(forKey: SettingsKey.readableLineWidth) as? Bool ?? true), forKey: SettingsKey.readableLineWidth)
                self.applyViewOptions()
            },
            .init(id: "reload", title: "Reload vault index", hint: "\(m)R") { self.scheduleRefresh(); self.rerenderAll() },
            .init(id: "switchVault", title: "Open another vault…") { self.closeVault() },
            .init(id: "settings", title: "Open settings", hint: "\(m),") { self.showSettings = true },
        ]
    }

    func runCommand(_ cmd: PaletteCommand) {
        recentCommands.removeAll { $0 == cmd.id }
        recentCommands.insert(cmd.id, at: 0)
        cmd.action()
    }
}

/// All app hotkeys go through one local key monitor so they work no matter which view has focus
/// (including the web view) and honour the CC = Cmd/Ctrl setting. Menu items show the same keys.
@MainActor
enum Hotkeys {
    private static var monitor: Any?

    static func install(model: VaultModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event, model) } ? nil : event
        }
    }

    /// Returns true when the event was consumed.
    private static func handle(_ event: NSEvent, _ model: VaultModel) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let cc = HotkeyModifier.current.eventFlags
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = event.keyCode

        // Vim keeps the Ctrl keys it uses in Normal/Visual mode (Ctrl-r/d/u/f/b) when CC = Ctrl, as in Notepad+++.
        if cc == .control, let tv = NSApp.keyWindow?.firstResponder as? VimTextView, tv.handlesVimControlKey(event) {
            return false
        }
        // Ctrl+Tab / Ctrl+Shift+Tab cycle tabs regardless of CC (Obsidian's default).
        if code == 48, flags == [.control] { model.selectTab(offset: 1); return true }
        if code == 48, flags == [.control, .shift] { model.selectTab(offset: -1); return true }

        // With CC = Control, make Ctrl+C/X/V/A/Z (and Ctrl+Shift+Z) do Copy / Cut / Paste / Select All /
        // Undo / Redo everywhere, including the note editor.
        if cc == .control, flags == cc || flags == cc.union(.shift) {
            let sel: Selector? = switch (key, flags == cc) {
            case ("c", true): #selector(NSText.copy(_:))
            case ("x", true): #selector(NSText.cut(_:))
            case ("v", true): #selector(NSText.paste(_:))
            case ("a", true): #selector(NSResponder.selectAll(_:))
            case ("z", true): Selector(("undo:"))
            case ("z", false): Selector(("redo:"))
            default: nil
            }
            if let sel { return NSApp.sendAction(sel, to: nil, from: nil) }
        }
        // The Settings sheet keeps normal text-field behaviour.
        if model.showSettings { return false }

        guard model.vaultURL != nil else {
            if flags == cc, key == "," { model.showSettings = true; return true }
            return false
        }

        if flags == cc.union(.option) {
            switch code {
            case 123: model.goBack(); return true      // ←
            case 124: model.goForward(); return true   // →
            default: return false
            }
        }
        if flags == cc.union(.shift) {
            switch key {
            case "f": model.focusSearch(); return true
            case "t": model.reopenClosedTab(); return true
            default: return false
            }
        }
        guard flags == cc else { return false }
        // CC+↑ / CC+↓: top / bottom of the note. The editor handles them itself (VimTextView).
        if code == 126 || code == 125, !(NSApp.keyWindow?.firstResponder is NSTextView) {
            model.scrollReadingView(toTop: code == 126)
            return true
        }
        switch code {
        case 116: model.selectTab(offset: -1); return true // Page Up
        case 121: model.selectTab(offset: 1); return true  // Page Down
        default: break
        }
        switch key {
        case "o": model.overlay = model.overlay == .switcher ? nil : .switcher
        case "p": model.overlay = model.overlay == .palette ? nil : .palette
        case "f": model.showFind()
        case "w": model.closeTab()
        case "t": model.newTab()
        case "e": model.toggleEdit()
        case "n": model.beginNewNote()
        case ";":
            guard NSApp.keyWindow?.firstResponder is VimTextView else { return false }
            model.addFileProperty()
        case "b", "i":
            // Formatting only applies in the editor; elsewhere the keys do nothing.
            guard NSApp.keyWindow?.firstResponder is VimTextView else { return false }
            model.toggleFormat(key == "b" ? .bold : .italic)
        case "r": model.scheduleRefresh(); model.rerenderAll()
        case ",": model.showSettings = true
        case "=", "+": model.zoom(0.1)
        case "-": model.zoom(-0.1)
        case "0": model.zoom(nil)
        case "1", "2", "3", "4", "5", "6", "7", "8", "9": model.selectTab(number: Int(key)!)
        default: return false
        }
        return true
    }
}
