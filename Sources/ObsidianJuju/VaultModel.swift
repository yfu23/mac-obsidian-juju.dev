import AppKit
import ObsidianJujuCore
import SwiftUI

struct Location: Equatable {
    var path: String
    var subpath: String?
    var highlight: [String] = []
}

struct Tab: Identifiable, Equatable {
    let id: UUID
    var history: [Location] = []
    var position = -1

    var current: Location? { history.indices.contains(position) ? history[position] : nil }
    var canGoBack: Bool { position > 0 }
    var canGoForward: Bool { position + 1 < history.count }
    var title: String {
        guard let p = current?.path else { return "New tab" }
        let name = (p as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? (name as NSString).deletingPathExtension : name
    }
}

struct TreeNode: Identifiable, Hashable {
    let id: String          // vault-relative path ("" for root)
    let name: String
    let isFolder: Bool
    var children: [TreeNode] = []
}

enum LeftPane: String, CaseIterable { case files, search, tags }
enum RightPane: String, CaseIterable { case outline, backlinks, outgoing }
/// A note, file or folder waiting for the user to confirm its deletion.
struct PendingDelete: Identifiable, Equatable {
    let path: String
    let isFolder: Bool
    /// Files inside a folder (0 for a file).
    let fileCount: Int
    let option: NoteWriter.TrashOption
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Attachments only a just-deleted note used, for "Delete file attachments?" (Obsidian's "Ask each time").
struct PendingAttachments: Identifiable, Equatable {
    let note: String
    let paths: [String]
    let option: NoteWriter.TrashOption
    var id: String { note + "|" + paths.joined(separator: "|") }
}

enum Overlay: Equatable {
    case switcher, palette, externalImage
    /// "New note" name prompt; the folder it goes in (vault-relative, "" = root).
    case newNote(String)
}

@MainActor
final class VaultModel: ObservableObject {
    static let shared = VaultModel()

    @Published private(set) var vaultURL: URL?
    @Published private(set) var snapshot = VaultSnapshot.empty
    @Published private(set) var tree = TreeNode(id: "", name: "", isFolder: true)
    @Published private(set) var indexing = false

    @Published var tabs: [Tab] = []
    @Published var activeTabID: UUID?

    @Published var overlay: Overlay? {
        // Hand keys back to the note (arrow/space scrolling) when a palette closes.
        didSet { if overlay == nil && oldValue != nil { focusWebView() } }
    }
    @Published var showSettings = false
    @Published var showLeft = true
    @Published var showRight = true
    @Published var leftPane: LeftPane = .files
    @Published var rightPane: RightPane = .outline
    @Published var expandedFolders: Set<String> = []

    @Published var searchText = ""
    @Published private(set) var searchResults = SearchResults.empty
    @Published private(set) var searching = false
    @Published var searchFocusToken = 0

    @Published var showFindBar = false
    @Published var findFocusToken = 0

    @Published private(set) var outline: [OutlineItem] = []
    @Published private(set) var backlinks: [Backlink] = []
    @Published private(set) var outgoing: [OutgoingLink] = []

    @Published var toast: String?
    /// Notes unlocked for editing, by tab. Empty by default: every note opens read-only.
    @Published private(set) var editSessions: [UUID: EditSession] = [:]
    /// This vault's attachment folders outside the vault (for `![](<juju:name>)`), in lookup order.
    @Published private(set) var attachmentFolders: [String] = []
    /// The media found in `attachmentFolders` (for the "Insert external image" picker).
    private(set) var externalAttachments = ExternalAttachments.empty

    private(set) var index: VaultIndex?
    private var watcher: FileWatcher?
    private var externalWatchers: [FileWatcher] = []
    private var externalScan: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var searchTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var controllers: [UUID: NoteWebController] = [:]
    private var scrolls: [UUID: [Int: Double]] = [:]
    private var closedTabs: [Tab] = []
    private(set) var recentFiles: [String] = []
    var recentCommands: [String] = []
    let schemeHandler = JujuSchemeHandler()
    /// Keys for JujuPix `.jjpx` photos; see JujuPix.swift.
    let jujuPixKeys = JujuPixKeys()
    @Published var jujuPixUnlocked = false
    @Published var showJujuPixUnlock = false
    @Published var pendingDelete: PendingDelete?
    /// Tabs whose `.base` is unlocked: its toolbar, column menus and table cells can change it (and its notes).
    @Published var unlockedBases: Set<UUID> = []
    /// View-only column sorts of read-only .base tabs (by view name), for the path they were chosen on. Never written
    /// to the file; dropped on navigating to another path, closing the tab, or unlocking the base.
    var baseSorts: [UUID: (path: String, sorts: [String: BaseSortKey])] = [:]
    @Published var pendingAttachments: PendingAttachments?
    /// Where "copy" actions put text (the system clipboard; tests use a private pasteboard).
    var copyPasteboard = NSPasteboard.general
    /// The locked photo that was clicked, so the password is checked against its library.
    var jujuPixTarget: URL?
    /// The Keychain was already used since the last lock (asking again wouldn't add keys).
    var jujuPixKeychainTried = false
    /// Bumped on every JujuPix lock/unlock so the page reloads `.jjpx` images instead of reusing cached ones.
    var jujuPixGeneration = 0
    var jujuPixIdleTimer: Timer?

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    var activePath: String? { activeTab?.current?.path }
    var activeController: NoteWebController? { activeTabID.flatMap { controllers[$0] } }
    var vaultName: String { vaultURL?.lastPathComponent ?? "" }

    // MARK: Vault

    func openVault(_ url: URL) {
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        lockAll()
        controllers.removeAll()
        scrolls.removeAll()
        closedTabs.removeAll()
        tabs = []
        activeTabID = nil
        snapshot = .empty
        tree = TreeNode(id: "", name: "", isFolder: true)
        searchText = ""
        searchResults = .empty
        outline = []; backlinks = []; outgoing = []
        expandedFolders = []

        vaultURL = root
        schemeHandler.vaultRoot = root
        schemeHandler.jujuPixKeys = jujuPixKeys
        startJujuPixAutoLock()
        UserDefaults.standard.set(root.path, forKey: SettingsKey.lastVaultPath)
        recentFiles = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        index = VaultIndex(root: root)
        watcher = FileWatcher(root: root) { [weak self] in self?.scheduleRefresh() }
        attachmentFolders = UserDefaults.standard.stringArray(forKey: attachmentFoldersKey) ?? []
        externalAttachments = .empty
        rescanAttachmentFolders(rewatch: true)
        newTab()
        scheduleRefresh(initial: true)
    }

    func closeVault() {
        lockAll()
        watcher = nil
        externalWatchers = []
        externalScan?.cancel()
        externalAttachments = .empty
        index = nil
        vaultURL = nil
        controllers.removeAll()
        tabs = []
        activeTabID = nil
    }

    private var recentKey: String { "recentFiles:" + (vaultURL?.path ?? "") }

    func scheduleRefresh(initial: Bool = false) {
        guard let index else { return }
        if refreshTask != nil { refreshAgain = true; return }
        indexing = initial
        refreshTask = Task { [weak self] in
            let snap = await index.refresh()
            guard let self, self.index === index else { return }
            self.apply(snap, initial: initial)
            self.refreshTask = nil
            self.indexing = false
            if self.refreshAgain {
                self.refreshAgain = false
                self.scheduleRefresh()
            }
        }
    }

    private func apply(_ snap: VaultSnapshot, initial: Bool) {
        let structureChanged = snap.files.map(\.path) != snapshot.files.map(\.path)
        snapshot = snap
        if structureChanged || initial { tree = Self.buildTree(snap) }
        if initial {
            if let first = recentFiles.first(where: { p in snap.files.contains { $0.path == p } }) {
                open(first)
            }
            return
        }
        // Live preview shows images that just appeared (e.g. a pasted image once it's indexed).
        if structureChanged { editSessions.values.forEach { $0.livePreview?.restyle() } }
        // Notes being edited pick up outside changes (or flag a conflict with unsaved edits).
        for session in editSessions.values where snap.changed.contains(session.path) { session.diskChanged() }
        // Live view: re-render tabs showing a file that changed on disk (e.g. edited in Obsidian).
        for tab in tabs {
            guard let p = tab.current?.path else { continue }
            let basesStale = controllers[tab.id]?.showsBases == true && (!snap.changed.isEmpty || structureChanged)
            guard snap.changed.contains(p) || basesStale || (structureChanged && tab.id == activeTabID) else { continue }
            // An unlocked base updates in place, so open menus and edits in progress stay.
            if unlockedBases.contains(tab.id) { updateBaseInPlace(tabID: tab.id) } else { rerender(tabID: tab.id) }
        }
        if !searchText.isEmpty { runSearch(debounce: false) }
        refreshPanels()
    }

    static func buildTree(_ snap: VaultSnapshot) -> TreeNode {
        final class Box { var name: String; var folders: [String: Box] = [:]; var files: [String] = []
            init(_ n: String) { name = n } }
        let root = Box("")
        func folder(_ path: String) -> Box {
            var node = root
            for part in path.split(separator: "/") {
                let key = String(part)
                if let next = node.folders[key] { node = next } else {
                    let b = Box(key); node.folders[key] = b; node = b
                }
            }
            return node
        }
        snap.folders.forEach { _ = folder($0) }
        for f in snap.files { folder(f.folder).files.append(f.path) }
        func build(_ box: Box, path: String) -> TreeNode {
            let folders = box.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { build($0, path: path.isEmpty ? $0.name : path + "/" + $0.name) }
            let files = box.files.map { p -> TreeNode in
                let name = (p as NSString).lastPathComponent
                let display = name.lowercased().hasSuffix(".md") ? (name as NSString).deletingPathExtension : name
                return TreeNode(id: p, name: display, isFolder: false)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return TreeNode(id: path, name: box.name, isFolder: true, children: folders + files)
        }
        return build(root, path: "")
    }

    // MARK: Tabs & navigation

    func controller(for tabID: UUID) -> NoteWebController {
        if let c = controllers[tabID] { return c }
        let c = NoteWebController(tabID: tabID, model: self, schemeHandler: schemeHandler)
        controllers[tabID] = c
        return c
    }

    func newTab() {
        let tab = Tab(id: UUID())
        if let i = tabs.firstIndex(where: { $0.id == activeTabID }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        activate(tab.id)
    }

    func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        // Switching tabs leaves the note: re-lock it.
        if let previous = activeTabID, previous != id { lock(tabID: previous) }
        activeTabID = id
        outline = controllers[id]?.outline ?? []
        refreshPanels()
        focusWebView()
    }

    /// `remember: false` leaves it out of "Undo close tab" (its note was deleted).
    func closeTab(_ id: UUID? = nil, remember: Bool = true) {
        guard let id = id ?? activeTabID, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        lock(tabID: id)
        let tab = tabs.remove(at: i)
        if tab.current != nil, remember { closedTabs.append(tab) }
        controllers[id] = nil
        baseSorts[id] = nil
        if tabs.isEmpty {
            newTab()
        } else if activeTabID == id {
            activate(tabs[min(i, tabs.count - 1)].id)
        }
    }

    func reopenClosedTab() {
        guard let tab = closedTabs.popLast() else { return }
        tabs.append(tab)
        activate(tab.id)
        rerender(tabID: tab.id)
    }

    func selectTab(offset: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeTabID }), !tabs.isEmpty else { return }
        activate(tabs[(i + offset + tabs.count) % tabs.count].id)
    }

    /// CC+1…8 selects that tab; CC+9 the last one (as in Obsidian).
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let i = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(i) { activate(tabs[i].id) }
    }

    func open(_ path: String, subpath: String? = nil, highlight: [String] = [], newTab: Bool = false) {
        guard index != nil else { return }
        if newTab || activeTabID == nil { self.newTab() }
        guard let id = activeTabID, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        var tab = tabs[i]
        if tab.current?.path != path { lock(tabID: id) }
        let loc = Location(path: path, subpath: subpath, highlight: highlight)
        if tab.current != loc || !highlight.isEmpty {
            tab.history = Array(tab.history.prefix(tab.position + 1)) + [loc]
            tab.position = tab.history.count - 1
            scrolls[id] = scrolls[id]?.filter { $0.key < tab.position }
            tabs[i] = tab
        }
        noteRecent(path)
        rerender(tabID: id, scrollY: 0)
        refreshPanels()
        focusWebView()
    }

    func goBack() { move(by: -1) }
    func goForward() { move(by: 1) }

    private func move(by delta: Int) {
        guard let id = activeTabID, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = tabs[i].position + delta
        guard tabs[i].history.indices.contains(target) else { return }
        if tabs[i].history[target].path != tabs[i].current?.path { lock(tabID: id) }
        tabs[i].position = target
        rerender(tabID: id)
        refreshPanels()
    }

    func rerender(tabID: UUID, scrollY: Double? = nil) {
        guard let index, let tab = tabs.first(where: { $0.id == tabID }), let loc = tab.current else { return }
        let c = controller(for: tabID)
        let y = scrollY ?? scrolls[tabID]?[tab.position] ?? 0
        let sorts = viewSorts(tabID: tabID, path: loc.path)
        Task {
            var payload = await index.renderPayload(for: loc.path, baseSort: sorts)
            for (k, v) in payload.external where v.hasPrefix("juju://jjpx/") {
                payload.external[k] = v + "?g=\(self.jujuPixGeneration)"
            }
            payload.baseEditable = self.unlockedBases.contains(tabID)
            c.showsBases = payload.base != nil || !payload.bases.isEmpty || payload.embeds.values.contains { $0.base != nil }
            c.usesExternal = ([payload.body] + payload.embeds.values.compactMap(\.body))
                .contains { !JujuRef.names(in: $0).isEmpty }
            // Restoring a saved scroll position takes priority over jumping to a heading.
            let useSubpath = y == 0 ? loc.subpath : nil
            c.render(payload.json(), scrollY: y, subpath: useSubpath, highlight: loc.highlight)
        }
    }

    func rerenderAll() {
        for tab in tabs { rerender(tabID: tab.id) }
    }

    func recordScroll(tabID: UUID, y: Double) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        scrolls[tabID, default: [:]][tab.position] = y
    }

    func followLink(from tabID: UUID, path: String?, target: String, subpath: String?, newTab: Bool) {
        guard let path else {
            flash("“\(target)” doesn’t exist yet — the viewer is read-only, so it can’t be created here.")
            return
        }
        if activeTabID != tabID { activate(tabID) }
        open(path, subpath: subpath, newTab: newTab)
    }

    private func noteRecent(_ path: String) {
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        recentFiles = Array(recentFiles.prefix(30))
        UserDefaults.standard.set(recentFiles, forKey: recentKey)
    }

    func focusWebView() {
        if let s = activeTabID.flatMap({ editSessions[$0] }), !s.showPreview { s.focus(); return }
        guard let web = activeController?.webView else { return }
        DispatchQueue.main.async { web.window?.makeFirstResponder(web) }
    }

    // MARK: Side panels

    func outlineDidChange(for tabID: UUID, _ items: [OutlineItem]) {
        if tabID == activeTabID { outline = items }
    }

    func refreshPanels() {
        guard let index, let path = activePath else {
            backlinks = []; outgoing = []
            if activePath == nil { outline = [] }
            return
        }
        Task {
            let b = await index.backlinks(to: path)
            let o = await index.outgoing(from: path)
            guard self.activePath == path else { return }
            self.backlinks = b
            self.outgoing = o
        }
    }

    func scrollToHeading(_ item: OutlineItem) {
        if let s = activeTabID.flatMap({ editSessions[$0] }), !s.showPreview { s.reveal(heading: item.text); return }
        activeController?.scrollToHeading(id: item.id)
    }

    func revealActiveFile() {
        guard let path = activePath else { return }
        var folder = (path as NSString).deletingLastPathComponent
        while !folder.isEmpty {
            expandedFolders.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        leftPane = .files
        showLeft = true
    }

    // MARK: Search

    func focusSearch(_ text: String? = nil) {
        showLeft = true
        leftPane = .search
        if let text { searchText = text; runSearch(debounce: false) }
        searchFocusToken += 1
    }

    func searchTag(_ tag: String) {
        focusSearch("tag:#" + tag)
    }

    func runSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let query = searchText
        guard let index, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = .empty
            searching = false
            return
        }
        searching = true
        searchTask = Task {
            if debounce { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            let results = await index.search(query)
            guard !Task.isCancelled, self.searchText == query else { return }
            self.searchResults = results
            self.searching = false
        }
    }

    // MARK: Find in note

    func showFind() {
        if let s = activeTabID.flatMap({ editSessions[$0] }), !s.showPreview { s.showFindBar(); return }
        showFindBar = true
        findFocusToken += 1
    }

    // MARK: File actions

    func openInObsidian() {
        guard let root = vaultURL, let path = activePath else { return }
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path", value: root.appendingPathComponent(path).path)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    func openInDefaultApp() {
        guard let root = vaultURL, let path = activePath else { return }
        NSWorkspace.shared.open(root.appendingPathComponent(path))
    }

    func revealInFinder() {
        guard let root = vaultURL, let path = activePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)])
    }

    func copyPath(absolute: Bool) {
        guard let root = vaultURL, let path = activePath else { return }
        copy(absolute ? root.appendingPathComponent(path).path : path, label: absolute ? "Full path" : "Vault path")
    }

    func copyObsidianURL() {
        guard let path = activePath else { return }
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "vault", value: vaultName),
                            URLQueryItem(name: "file", value: path)]
        if let s = comps.url?.absoluteString { copy(s, label: "Obsidian URL") }
    }

    private func copy(_ s: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        flash("\(label) copied")
    }

    func openRandomNote() {
        guard let f = snapshot.files.filter(\.isNote).randomElement() else { return }
        open(f.path)
    }

    // MARK: View settings

    func zoom(_ delta: Double?) {
        let d = UserDefaults.standard
        let current = d.object(forKey: SettingsKey.zoom) as? Double ?? 1
        let next = delta.map { min(max(current + $0, 0.5), 3) } ?? 1
        d.set(next, forKey: SettingsKey.zoom)
        controllers.values.forEach { $0.applyOptions() }
    }

    func applyViewOptions() {
        controllers.values.forEach { $0.applyOptions() }
    }

    // MARK: Attachment folders outside the vault

    private var attachmentFoldersKey: String { "attachmentFolders:" + (vaultURL?.path ?? "") }

    func addAttachmentFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !attachmentFolders.contains(path) else { return }
        setAttachmentFolders(attachmentFolders + [path])
    }

    func setAttachmentFolders(_ folders: [String]) {
        attachmentFolders = folders
        UserDefaults.standard.set(folders, forKey: attachmentFoldersKey)
        rescanAttachmentFolders(rewatch: true)
    }

    /// Lists the folders' media off the main thread, then re-renders notes that use `juju:` images.
    private func rescanAttachmentFolders(rewatch: Bool) {
        guard let index else { return }
        let urls = attachmentFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if rewatch {
            externalWatchers = urls.compactMap { url in
                FileWatcher(root: url, latency: 2) { [weak self] in self?.rescanAttachmentFolders(rewatch: false) }
            }
        }
        externalScan?.cancel()
        externalScan = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) { ExternalAttachments.scan(urls) }.value
            guard !Task.isCancelled, let self, self.index === index else { return }
            await index.setExternalAttachments(scanned)
            self.externalAttachments = scanned
            self.schemeHandler.externalFolders = urls
            for tab in self.tabs where rewatch || self.controllers[tab.id]?.usesExternal == true {
                self.rerender(tabID: tab.id)
            }
        }
    }

    // MARK: Edit mode (per note, no global switch)

    /// Unlocks the tab's current note for editing. Only Markdown notes can be unlocked.
    func unlock(tabID: UUID) {
        guard editSessions[tabID] == nil, let root = vaultURL,
              let path = tabs.first(where: { $0.id == tabID })?.current?.path else { return }
        if Self.isBase(path) {
            guard unlockedBases.insert(tabID).inserted else { return }
            baseSorts[tabID] = nil   // the editor shows (and saves) the file's own sort
            rerender(tabID: tabID)
            return
        }
        guard NoteWriter.isEditable(path) else { flash("Only Markdown notes can be edited"); return }
        guard let session = EditSession(root: root, path: path) else {
            flash("This note can’t be edited (missing or not UTF-8 text)")
            return
        }
        showFindBar = false
        session.onEx = { [weak self] cmd in self?.runVimEx(cmd, tabID: tabID) }
        session.resolveImage = { [weak self] target in self?.editorImageSource(target, from: path) }
        session.openLink = { [weak self] target, newTab in self?.openLinkTarget(target, from: path, newTab: newTab) }
        session.pasteImage = { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.pasteImage(into: session)
        }
        let keys = jujuPixKeys
        session.decryptImage = { data in
            if case .image(let decrypted, _) = keys.open(data) { return decrypted }
            return nil
        }
        editSessions[tabID] = session
        if tabID == activeTabID { session.focus() }
    }

    /// Saves any pending edits and makes the note read-only again.
    func lock(tabID: UUID) {
        if unlockedBases.remove(tabID) != nil {
            rerender(tabID: tabID)
            return
        }
        guard let session = editSessions.removeValue(forKey: tabID) else { return }
        session.livePreview?.detach()
        session.flush()
        if session.conflict || session.status != .saved {
            // Never lose typing: unsaved text that couldn't be written (conflict or error) goes to the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.text, forType: .string)
            flash("Couldn’t save “\((session.path as NSString).lastPathComponent)” — your version was copied to the clipboard")
        }
        rerender(tabID: tabID)
        if tabID == activeTabID { focusWebView() }
    }

    func lockAll() {
        for id in Array(editSessions.keys) + Array(unlockedBases) { lock(tabID: id) }
    }

    /// Writes pending edits everywhere (app quit).
    func flushEdits() {
        editSessions.values.forEach { $0.flush() }
    }

    func togglePreview(tabID: UUID) {
        guard let session = editSessions[tabID] else { return }
        session.flush()
        session.showPreview.toggle()
        if session.showPreview { rerender(tabID: tabID) }
        if tabID == activeTabID { focusWebView() }
    }

    /// Vim ex commands that act on the app. Autosave means `:w` only flushes; `:q` locks the note (the edits are
    /// already saved, so `:q!` can't discard them).
    private func runVimEx(_ cmd: String, tabID: UUID) {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "w": editSessions[tabID]?.flush()
        case "wq", "x", "q", "q!", "wq!", "x!": lock(tabID: tabID)
        case "tabnew", "enew": newTab()
        case "bn", "tabn": selectTab(offset: 1)
        case "bp", "tabp": selectTab(offset: -1)
        case "qa", "qa!", "wqa", "xa": NSApp.terminate(nil)
        default: NSSound.beep()
        }
    }

    /// "Insert external image": unlocks the current note if needed, shows the editor and opens the picker.
    func beginInsertExternalImage() {
        guard let id = activeTabID, activeTab?.current != nil else { return }
        guard !attachmentFolders.isEmpty else {
            flash("Add an attachment folder outside the vault in Settings first")
            showSettings = true
            return
        }
        if editSessions[id] == nil { unlock(tabID: id) }
        guard let session = editSessions[id] else { return }
        if session.showPreview { togglePreview(tabID: id) }
        overlay = .externalImage
    }

    /// Writes `![](<juju:name>)` at the caret of the current note's editor (replacing any selection).
    func insertExternalImage(_ name: String) {
        guard let id = activeTabID, let session = editSessions[id], !session.showPreview else { return }
        session.insert(JujuRef.markdown(name))
    }

    // MARK: Editor: inline images, formatting, live preview

    private static var resolverCache: (generation: Int, resolver: LinkResolver)?

    private func linkResolver() -> LinkResolver {
        if Self.resolverCache?.generation != snapshot.generation {
            Self.resolverCache = (snapshot.generation, LinkResolver(paths: snapshot.files.map(\.path)))
        }
        return Self.resolverCache!.resolver
    }

    /// "Open link" / "Open in new tab" for a link right-clicked in the editor: `target` as written
    /// (`Note#Heading`, `folder/Note.md`, `https://…`).
    func openLinkTarget(_ target: String, from source: String, newTab: Bool) {
        let t = target.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "obsidian"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let parts = t.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0], subpath = parts.count > 1 ? parts[1] : nil
        guard let id = activeTabID else { return }
        if name.isEmpty {
            open(source, subpath: subpath, newTab: newTab)   // a heading in this note
            return
        }
        followLink(from: id, path: linkResolver().resolve(name, from: source), target: name, subpath: subpath, newTab: newTab)
    }

    /// Where live preview loads an embedded image from (`![[a.png]]`, `![](a.png)`, `![](<juju:a.png>)`, URLs).
    func editorImageSource(_ target: String, from source: String) -> EditorImageSource? {
        guard let root = vaultURL else { return nil }
        let t = target.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: t).map { .remote($0) } }
        let resolver = linkResolver()
        func isImage(_ p: String) -> Bool { FileKind(ext: (p as NSString).pathExtension) == .image || JujuRef.isEncrypted(p) }
        func make(_ url: URL, _ p: String) -> EditorImageSource { JujuRef.isEncrypted(p) ? .encrypted(url) : .file(url) }
        if lower.hasPrefix("juju:") {
            let name = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let inVault = resolver.resolve(name, from: source), isImage(inVault) {
                return make(root.appendingPathComponent(inVault), inVault)
            }
            let ext = externalAttachments
            guard let hit = ext.resolve(name), isImage(hit.path) else { return nil }
            return make(ext.folders[hit.folder].appendingPathComponent(hit.path), hit.path)
        }
        let path = t.components(separatedBy: "#").first ?? t
        guard let inVault = resolver.resolve(path.removingPercentEncoding ?? path, from: source), isImage(inVault) else { return nil }
        return make(root.appendingPathComponent(inVault), inVault)
    }

    /// Pasting an image (a screenshot, an image copied from an app, or image files copied in Finder) into an
    /// unlocked note saves it where Obsidian's "Default location for new attachments" says, named like Obsidian
    /// ("Pasted image 20261004101530.png"; copied files keep their names), and writes `![[…]]` at the caret.
    /// Returns false when the clipboard holds no image, so the normal text paste happens.
    func pasteImage(into session: EditSession, from pb: NSPasteboard = .general) -> Bool {
        guard let root = vaultURL else { return false }
        var items: [(data: Data, name: String)] = []
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { FileKind(ext: $0.pathExtension) == .image }
        if !files.isEmpty {
            items = files.compactMap { url in (try? Data(contentsOf: url)).map { ($0, url.lastPathComponent) } }
        } else if pb.string(forType: .string) != nil {
            return false   // text (possibly with a picture of it, e.g. from a spreadsheet) pastes as text
        } else if let png = pb.data(forType: .png) {
            items = [(png, NewNoteLocation.pastedImageName())]
        } else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            items = [(png, NewNoteLocation.pastedImageName())]
        }
        guard !items.isEmpty else { return false }
        let folder = NewNoteLocation.attachmentFolder(vault: root, notePath: session.path)
        let markdown = NewNoteLocation.usesMarkdownLinks(vault: root)
        var embeds: [String] = []
        for item in items {
            switch NoteWriter.saveAttachment(item.data, root: root, folder: folder, name: item.name) {
            case .created(let path):
                let name = (path as NSString).lastPathComponent.lowercased()
                let unique = !snapshot.files.contains { $0.name.lowercased() == name && $0.path != path }
                embeds.append(NewNoteLocation.embed(path: path, markdown: markdown, nameIsUnique: unique))
            case .failed(let message):
                flash("Couldn’t save the pasted image: \(message)")
            }
        }
        if !embeds.isEmpty {
            session.insert(embeds.joined(separator: "\n"))
            scheduleRefresh()
        }
        return true
    }

    /// CC+↑ / CC+↓ in the reading view: top / bottom of the note.
    func scrollReadingView(toTop: Bool) {
        activeController?.webView.evaluateJavaScript(toTop ? "window.scrollTo(0, 0)" : "window.scrollTo(0, document.documentElement.scrollHeight)")
    }

    /// CC+B / CC+I and the palette's "Toggle …" commands; only in an unlocked note's editor.
    func toggleFormat(_ format: MarkdownStyle.Format) {
        guard let id = activeTabID, let session = editSessions[id], !session.showPreview else {
            flash("Unlock the note to format text (\(HotkeyModifier.current.symbol)E)")
            return
        }
        session.toggle(format)
    }

    /// "Add file property" (CC+;), as in Obsidian: a new row in the editor's Properties panel.
    func addFileProperty() {
        guard let id = activeTabID, let session = editSessions[id], !session.showPreview else {
            flash("Unlock the note to add a property (\(HotkeyModifier.current.symbol)E)")
            return
        }
        guard LivePreview.isEnabled else { flash("Turn on live preview to edit properties in the panel"); return }
        session.addProperty()
    }

    func toggleLivePreview() {
        let on = !LivePreview.isEnabled
        UserDefaults.standard.set(on, forKey: SettingsKey.livePreview)
        editSessions.values.forEach { $0.restyle() }
        flash(on ? "Live preview on" : "Source mode (live preview off)")
    }

    // MARK: New notes

    /// CC+N: asks for a name, then creates the note in `folder` (default: Obsidian's "Default location for new
    /// notes") and opens it unlocked for editing.
    func beginNewNote(in folder: String? = nil) {
        guard let root = vaultURL else { return }
        let target = folder ?? NewNoteLocation.folder(vault: root, currentPath: activePath, existingFolders: Set(snapshot.folders))
        overlay = .newNote(target)
    }

    func untitledName(in folder: String) -> String {
        NoteWriter.availableName("Untitled", folder: folder, existing: Set(snapshot.files.map(\.path)))
    }

    /// Returns an error message, or nil when the note was created and opened.
    func createNote(folder: String, name: String) -> String? {
        guard let root = vaultURL else { return "No vault is open" }
        switch NoteWriter.create(root: root, folder: folder, name: name) {
        case .failed(let message):
            return message
        case .created(let path):
            overlay = nil
            open(path)
            if let id = activeTabID { unlock(tabID: id) }
            scheduleRefresh()
            return nil
        }
    }

    /// "Duplicate current file" / "Make a copy": copies the note (saving pending edits first) to "Name 1.md" next to it
    /// and opens the copy — unlocked if the original was being edited.
    func duplicateFile(_ path: String? = nil) {
        guard let root = vaultURL, let path = path ?? activePath else { return }
        let editing = activeTabID.flatMap { editSessions[$0] }.map { $0.path == path } ?? false
        editSessions.values.filter { $0.path == path }.forEach { $0.flush() }
        switch NoteWriter.copyNote(root: root, path: path) {
        case .failed(let message):
            flash("Couldn’t duplicate the file: \(message)")
        case .created(let copy):
            open(copy)
            if editing, let id = activeTabID { unlock(tabID: id) }
            scheduleRefresh()
            flash("Duplicated to “\((copy as NSString).lastPathComponent)”")
        }
    }

    /// The file behind an image address in the reading view (`juju://vault|ext|jjpx/…`), or the address of a web image.
    func imageLocation(src: String) -> (name: String, path: String)? {
        guard let c = URLComponents(string: src), let scheme = c.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            let name = URL(string: src)?.lastPathComponent ?? src
            return (name.removingPercentEncoding ?? name, src)
        }
        guard scheme == "juju", let host = c.host, let raw = c.percentEncodedPath.removingPercentEncoding else { return nil }
        let path = String(raw.drop { $0 == "/" })
        var file: URL?
        switch host {
        case "jjpx":
            file = jujuPixFile(src: src)
        case "vault":
            file = vaultURL.flatMap { VaultReader.containedURL($0, path) }
        case "ext":
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            let folders = externalAttachments.folders
            if parts.count == 2, let i = Int(parts[0]), folders.indices.contains(i) {
                file = VaultReader.containedURL(folders[i], parts[1])
            }
        default:
            break
        }
        return file.map { ($0.lastPathComponent, $0.path) }
    }

    /// The reading view's image hover buttons: copies the image's file name or full path.
    func copyImageFile(src: String, path: Bool) {
        guard let location = imageLocation(src: src) else { return flash("Couldn’t find this image’s file") }
        copyPasteboard.clearContents()
        copyPasteboard.setString(path ? location.path : location.name, forType: .string)
        flash(path ? "Copied the path of “\(location.name)”" : "Copied “\(location.name)”")
    }

    /// "Delete current file" / right-click → Delete: asks first (unless the user chose "Don't ask again"), then
    /// deletes as Obsidian's "Deleted files" setting says (the macOS Trash by default).
    func requestDelete(_ path: String? = nil, isFolder: Bool = false) {
        guard let root = vaultURL, let path = path ?? activePath, !path.isEmpty else { return }
        let count = isFolder ? snapshot.files.filter { $0.path.hasPrefix(path + "/") }.count : 0
        let item = PendingDelete(path: path, isFolder: isFolder, fileCount: count,
                                 option: NewNoteLocation.trashOption(vault: root))
        if UserDefaults.standard.object(forKey: SettingsKey.confirmFileDeletion) as? Bool ?? true {
            pendingDelete = item
        } else {
            performDelete(item)
        }
    }

    func performDelete(_ item: PendingDelete) {
        pendingDelete = nil
        guard let root = vaultURL else { return }
        func inside(_ p: String?) -> Bool { p.map { $0 == item.path || $0.hasPrefix(item.path + "/") } ?? false }
        // Save and close the tabs showing it first, so no pending edit is written back after the delete.
        for tab in tabs where inside(tab.current?.path) { closeTab(tab.id, remember: false) }
        expandedFolders = expandedFolders.filter { !inside($0) }
        // Obsidian's "Delete attachments when deleting files" applies to files, not folders.
        let setting = item.isFolder ? .never : NewNoteLocation.deleteAttachments(vault: root)
        guard setting != .never, let index else {
            _ = deleteNow(item, root: root)
            return
        }
        // Links typed in other notes but not saved yet count as uses.
        editSessions.values.forEach { $0.flush() }
        Task { [weak self] in
            let snap = await index.refresh()
            let unused = await index.unlinkedAttachments(of: item.path)
            guard let self, self.index === index else { return }
            self.apply(snap, initial: false)
            guard self.deleteNow(item, root: root, attachments: setting == .always ? unused : []), !unused.isEmpty,
                  setting == .ask else { return }
            self.pendingAttachments = PendingAttachments(note: item.name, paths: unused, option: item.option)
        }
    }

    /// Deletes `item` (and, for "Always", its unused `attachments`) and says so. Returns false if it failed.
    private func deleteNow(_ item: PendingDelete, root: URL, attachments: [String] = []) -> Bool {
        defer { scheduleRefresh() }
        let where_: String
        switch NoteWriter.delete(root: root, path: item.path, option: item.option) {
        case .failed(let message):
            flash("Couldn’t delete “\(item.name)”: \(message)")
            return false
        case .trashed: where_ = "to the Trash"
        case .movedToVaultTrash: where_ = "to the vault’s .trash folder"
        case .deleted: where_ = ""
        }
        let removed = attachments.filter { path in
            if case .failed = NoteWriter.delete(root: root, path: path, option: item.option) { return false }
            return true
        }
        let what = "“\(item.name)”" + (removed.isEmpty ? "" : " and \(removed.count) attachment\(removed.count == 1 ? "" : "s")")
        flash(where_.isEmpty ? "Deleted \(what)" : "Moved \(what) \(where_)")
        return true
    }

    /// The "Delete file attachments?" dialog's choice.
    func deleteAttachments(_ paths: [String], of pending: PendingAttachments) {
        pendingAttachments = nil
        guard let root = vaultURL, !paths.isEmpty else { return }
        var failed: [String] = []
        for path in paths {
            if case .failed(let message) = NoteWriter.delete(root: root, path: path, option: pending.option) {
                failed.append("\((path as NSString).lastPathComponent): \(message)")
            }
        }
        let n = paths.count - failed.count
        flash(failed.isEmpty ? "Deleted \(n) attachment\(n == 1 ? "" : "s")" : "Couldn’t delete \(failed.joined(separator: "; "))")
        scheduleRefresh()
    }

    /// CC+E: unlock the current note, or toggle editor/preview once it's unlocked (Obsidian's edit toggle).
    func toggleEdit() {
        guard let id = activeTabID, activeTab?.current != nil else { return }
        if unlockedBases.contains(id) { lock(tabID: id); return }
        if editSessions[id] == nil { unlock(tabID: id) } else { togglePreview(tabID: id) }
    }

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self.toast = nil
        }
    }
}

// MARK: Editing bases (toolbar, column menus and table cells, as in Obsidian)

extension VaultModel {
    static func isBase(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "base" }

    /// The page changed an unlocked base's settings: writes the whole file, as Obsidian does.
    func saveBase(tabID: UUID, path: String, yaml: String) {
        guard let root = vaultURL, unlockedBases.contains(tabID), Self.isBase(path),
              tabs.first(where: { $0.id == tabID })?.current?.path == path else { return }
        guard case .map = YAMLLite.parse(yaml) else { return flash("Couldn’t save the base: invalid settings") }
        guard let url = VaultReader.containedURL(root, path),
              let disk = (try? Data(contentsOf: url)).flatMap({ String(data: $0, encoding: .utf8) }) else {
            return flash("Couldn’t save the base: it no longer exists on disk")
        }
        switch NoteWriter.rewrite(yaml, root: root, path: path, baseline: disk) {
        case .saved, .unchanged:
            updateBaseInPlace(tabID: tabID)
            scheduleRefresh()
        case .conflict:
            flash("The base changed on disk; showing the new version")
            rerender(tabID: tabID)
        case .failed(let message):
            flash("Couldn’t save the base: \(message)")
        }
    }

    /// A value edited in an unlocked base's table: sets that note's property (only that property's lines change).
    func setBaseCell(tabID: UUID, notePath: String, property: String, value: PropertyValue) {
        guard let root = vaultURL, unlockedBases.contains(tabID), NoteWriter.isEditable(notePath), !property.isEmpty else { return }
        // Pending typing in that note is saved first, so the edit applies on top of it.
        editSessions.values.filter { $0.path == notePath }.forEach { $0.flush() }
        guard let disk = NoteWriter.load(root: root, path: notePath),
              let next = Frontmatter.apply(.set(key: property, value: value), to: disk) else {
            return flash("Couldn’t change “\(property)” in “\((notePath as NSString).lastPathComponent)”")
        }
        switch NoteWriter.rewrite(next, root: root, path: notePath, baseline: disk) {
        case .saved, .unchanged:
            scheduleRefresh()   // re-evaluates the base (and any tab showing the note)
        case .conflict:
            flash("“\((notePath as NSString).lastPathComponent)” changed on disk; try again")
            scheduleRefresh()
        case .failed(let message):
            flash("Couldn’t change “\(property)”: \(message)")
        }
    }

    /// A column header clicked in a read-only .base tab: sorts that view for viewing only (nil = the file's sort).
    func setBaseSort(tabID: UUID, path: String, view: String, sort: BaseSortKey?) {
        guard !unlockedBases.contains(tabID), Self.isBase(path),
              tabs.first(where: { $0.id == tabID })?.current?.path == path else { return }
        var sorts = viewSorts(tabID: tabID, path: path)
        sorts[view] = sort
        baseSorts[tabID] = sorts.isEmpty ? nil : (path, sorts)
        updateBaseInPlace(tabID: tabID)
    }

    /// The tab's view-only base sorts, if they were chosen on `path` (stale ones are dropped).
    func viewSorts(tabID: UUID, path: String) -> [String: BaseSortKey] {
        guard let entry = baseSorts[tabID] else { return [:] }
        if entry.path == path, !unlockedBases.contains(tabID) { return entry.sorts }
        baseSorts[tabID] = nil
        return [:]
    }

    /// Re-evaluates a base and hands the page the new results without reloading it.
    func updateBaseInPlace(tabID: UUID) {
        guard let index, let path = tabs.first(where: { $0.id == tabID })?.current?.path, Self.isBase(path) else { return }
        let c = controller(for: tabID)
        let sorts = viewSorts(tabID: tabID, path: path)
        Task {
            var payload = await index.renderPayload(for: path, baseSort: sorts)
            payload.baseEditable = self.unlockedBases.contains(tabID)
            c.webView.evaluateJavaScript("window.juju.updateBase(\(payload.json()))", completionHandler: nil)
        }
    }
}

