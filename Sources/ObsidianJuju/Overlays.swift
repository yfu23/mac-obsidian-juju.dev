import ObsidianJujuCore
import SwiftUI

struct OverlayHost: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        if let overlay = model.overlay {
            ZStack(alignment: .top) {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { model.overlay = nil }
                Group {
                    switch overlay {
                    case .switcher: QuickSwitcher(model: model)
                    case .palette: CommandPalette(model: model)
                    case .externalImage: ExternalImagePicker(model: model)
                    case .newNote(let folder): NewNotePrompt(model: model, folder: folder)
                    }
                }
                .padding(.top, 80)
            }
        }
    }
}

/// Obsidian-style modal: prompt input on top, results below, instructions in the footer.
struct PickerModal<Item: Identifiable, Row: View>: View {
    let placeholder: String
    let items: (String) -> [Item]
    let instructions: [(String, String)]
    let row: (Item, Bool) -> Row
    let choose: (Item, Bool) -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @State private var results: [Item] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textNormal)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .focused($focused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    choose(press.modifiers.contains(HotkeyModifier.current.flags))
                    return .handled
                }
                // Ctrl+N / Ctrl+P also move, as in Obsidian.
                .onKeyPress(keys: ["n", "p"]) { press in
                    guard press.modifiers == .control else { return .ignored }
                    move(press.characters == "n" ? 1 : -1)
                    return .handled
                }
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                            row(item, i == highlighted)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 5).fill(i == highlighted ? Theme.hover : .clear))
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                                .onTapGesture { highlighted = i; choose(ccHeld()) }
                        }
                        if results.isEmpty {
                            Text("No matches found.").font(Theme.uiFont).foregroundStyle(Theme.textFaint).padding()
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 380)
                .onChange(of: highlighted) { _, i in if results.indices.contains(i) { proxy.scrollTo(results[i].id) } }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 14) {
                ForEach(instructions, id: \.0) { key, label in
                    HStack(spacing: 4) {
                        Text(key).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                        Text(label).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.backgroundPrimary))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .onAppear { results = items(""); takeFocus { focused = true } }
        .onChange(of: query) { _, q in results = items(q); highlighted = 0 }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + d + results.count) % results.count
    }

    private func choose(_ newTab: Bool) {
        guard results.indices.contains(highlighted) else { return }
        let item = results[highlighted]
        close()
        choose(item, newTab)
    }
}

// MARK: Quick switcher

struct SwitcherItem: Identifiable {
    let id: String
    let path: String
    let title: String
    let alias: String?
}

struct QuickSwitcher: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        let m = HotkeyModifier.current.symbol
        PickerModal(
            placeholder: "Find or open a file…",
            items: search,
            instructions: [("↑↓", "to navigate"), ("↵", "to open"), ("\(m)↵", "to open in new tab"), ("esc", "to dismiss")],
            row: { item, _ in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let alias = item.alias {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                            Text(alias).font(.system(size: 14)).foregroundStyle(Theme.textNormal)
                        } else {
                            Text(item.title).font(.system(size: 14)).foregroundStyle(Theme.textNormal)
                        }
                        let ext = (item.path as NSString).pathExtension.lowercased()
                        if ext != "md" {
                            Text(ext.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textFaint)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.hover))
                        }
                    }
                    let folder = (item.path as NSString).deletingLastPathComponent
                    if item.alias != nil || !folder.isEmpty {
                        Text(item.alias != nil ? item.path : folder + "/")
                            .font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                }
            },
            choose: { item, newTab in model.open(item.path, newTab: newTab) },
            close: { model.overlay = nil }
        )
    }

    private func search(_ q: String) -> [SwitcherItem] {
        let files = model.snapshot.files
        let query = q.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            let existing = Set(files.map(\.path))
            let recent = model.recentFiles.filter(existing.contains)
            let rest = files.filter(\.isNote).map(\.path).filter { !recent.contains($0) }
                .sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
            return (recent + rest).prefix(60).map { SwitcherItem(id: $0, path: $0, title: displayName($0), alias: nil) }
        }
        var scored: [(SwitcherItem, Int)] = []
        for f in files {
            let title = displayName(f.path)
            let pathText = f.isNote ? String(f.path.dropLast(3)) : f.path
            let byTitle = Fuzzy.score(query, in: title)
            let byPath = Fuzzy.score(query, in: pathText).map { $0 + 15 }
            if let s = [byTitle, byPath].compactMap({ $0 }).min() {
                // Notes rank above attachments with equal scores.
                scored.append((SwitcherItem(id: f.path, path: f.path, title: title, alias: nil), s + (f.isNote ? 0 : 5)))
            }
            for alias in model.snapshot.aliases[f.path] ?? [] {
                if let s = Fuzzy.score(query, in: alias) {
                    scored.append((SwitcherItem(id: f.path + "|" + alias, path: f.path, title: title, alias: alias), s + 2))
                }
            }
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.title.count < $1.0.title.count : $0.1 < $1.1 }
            .prefix(60).map(\.0)
    }
}

// MARK: Command palette

struct CommandPalette: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        PickerModal(
            placeholder: "Select a command…",
            items: search,
            instructions: [("↑↓", "to navigate"), ("↵", "to use"), ("esc", "to dismiss")],
            row: { cmd, _ in
                HStack {
                    Text(cmd.title).font(.system(size: 14)).foregroundStyle(Theme.textNormal)
                    Spacer()
                    if !cmd.hint.isEmpty {
                        Text(cmd.hint)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.hover))
                    }
                }
            },
            choose: { cmd, _ in
                // Let the modal close first so commands that move focus aren't undone.
                DispatchQueue.main.async { model.runCommand(cmd) }
            },
            close: { model.overlay = nil }
        )
    }

    private func search(_ q: String) -> [PaletteCommand] {
        let all = model.paletteCommands()
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            let recent = model.recentCommands.compactMap { id in all.first { $0.id == id } }
            return recent + all.filter { c in !recent.contains { $0.id == c.id } }
        }
        return all.compactMap { c in Fuzzy.score(q, in: c.title).map { (c, $0) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }
}

// MARK: Insert external image

struct ExternalImageItem: Identifiable {
    let id: String
    /// What goes after `juju:`.
    let reference: String
    let fileName: String
    /// "Folder/sub/" for a found file; nil for a name inserted as typed.
    let location: String?
}

/// Picks a file from the attachment folders outside the vault. Typing or pasting a file name (Finder's Copy,
/// a full path or a `file://` URL all work) narrows the list; ↵ writes `![](<juju:name>)` into the note.
struct ExternalImagePicker: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        PickerModal(
            placeholder: "Type or paste an image file name…",
            items: search,
            instructions: [("↑↓", "to navigate"), ("↵", "to insert"), ("esc", "to dismiss")],
            row: { item, _ in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: icon(item.fileName)).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        Text(item.fileName).font(.system(size: 14)).foregroundStyle(Theme.textNormal)
                    }
                    Text(item.location ?? "Not found in the attachment folders — insert as typed")
                        .font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                }
            },
            choose: { item, _ in
                // Let the modal close (and focus return to the editor) first.
                DispatchQueue.main.async { model.insertExternalImage(item.reference) }
            },
            close: { model.overlay = nil }
        )
    }

    private func icon(_ name: String) -> String {
        if JujuRef.isEncrypted(name) { return "lock.fill" }
        return switch FileKind(ext: (name as NSString).pathExtension) {
        case .audio: "waveform"
        case .video: "film"
        default: "photo"
        }
    }

    private func item(_ hit: ExternalAttachments.Hit, vaultNames: Set<String>) -> ExternalImageItem {
        let ext = model.externalAttachments
        let folder = ext.folders.indices.contains(hit.folder) ? ext.folders[hit.folder].lastPathComponent : "?"
        let sub = (hit.path as NSString).deletingLastPathComponent
        let reference = ext.reference(for: hit)
        // Names resolve in the vault first, then folder by folder: say when another file will be shown instead.
        let note = reference == nil ? "  ·  an earlier folder has the same file name; that one will show"
            : vaultNames.contains(reference!.lowercased()) ? "  ·  the vault has a file with this name; the vault’s copy will show"
            : ""
        return ExternalImageItem(
            id: "\(hit.folder)/\(hit.path)", reference: reference ?? hit.path,
            fileName: (hit.path as NSString).lastPathComponent,
            location: folder + "/" + (sub.isEmpty ? "" : sub + "/") + note)
    }

    private func search(_ q: String) -> [ExternalImageItem] {
        let ext = model.externalAttachments
        // Lowercased vault file names and paths (a `juju:` name finds these first).
        let vaultNames = Set(model.snapshot.files.flatMap { [$0.name.lowercased(), $0.path.lowercased()] })
        let item = { (hit: ExternalAttachments.Hit) in self.item(hit, vaultNames: vaultNames) }
        let name = JujuRef.cleanName(q)
        guard !name.isEmpty else { return ext.entries.prefix(100).map(item) }
        let exact = ext.resolve(name)
        var scored: [(ExternalAttachments.Hit, Int)] = []
        for hit in ext.entries where hit != exact {
            let fileName = (hit.path as NSString).lastPathComponent
            let byName = Fuzzy.score(name, in: fileName)
            let byPath = Fuzzy.score(name, in: hit.path).map { $0 + 15 }
            if let s = [byName, byPath].compactMap({ $0 }).min() { scored.append((hit, s)) }
        }
        let ranked = scored.sorted { $0.1 == $1.1 ? $0.0.path.count < $1.0.path.count : $0.1 < $1.1 }.prefix(100).map(\.0)
        var items = (exact.map { [$0] } ?? []).map(item) + ranked.map(item)
        if exact == nil {
            items.append(ExternalImageItem(id: "typed:" + name, reference: name,
                                           fileName: (name as NSString).lastPathComponent, location: nil))
        }
        return items
    }
}

// MARK: New note

/// Asks for the new note's name (prefilled with "Untitled", like Obsidian's default name).
struct NewNotePrompt: View {
    @ObservedObject var model: VaultModel
    let folder: String
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").foregroundStyle(Theme.textFaint)
                TextField("Name of the new note", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textNormal)
                    .focused($focused)
                    .onSubmit(create)
                    .onKeyPress(.escape) { model.overlay = nil; return .handled }
                    .onChange(of: name) { _, _ in error = nil }
                Text(".md").font(.system(size: 14)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 14) {
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                } else {
                    Text("In " + (folder.isEmpty ? "the vault root" : folder + "/"))
                        .font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("↵").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    Text("to create").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
                HStack(spacing: 4) {
                    Text("esc").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    Text("to dismiss").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.backgroundPrimary))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .onAppear {
            name = model.untitledName(in: folder)
            takeFocus { focused = true }
        }
    }

    private func create() {
        error = model.createNote(folder: folder, name: name)
    }
}

// MARK: Vault picker

struct VaultPickerView: View {
    @ObservedObject var model: VaultModel
    @State private var vaults = KnownVault.fromObsidianConfig()

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("ObsidianJuju").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.textNormal)
            Text("A read-only viewer for your Obsidian vaults").font(.system(size: 14)).foregroundStyle(Theme.textMuted)

            VStack(alignment: .leading, spacing: 0) {
                if vaults.isEmpty {
                    Text("No vaults found in Obsidian's settings.")
                        .font(Theme.uiFont).foregroundStyle(Theme.textFaint).padding(14)
                }
                ForEach(vaults) { v in
                    HoverRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textNormal)
                            Text(v.path).font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.vertical, 4)
                    } action: { model.openVault(URL(fileURLWithPath: v.path)) }
                }
            }
            .padding(.vertical, 6)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.backgroundSecondary))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))

            Button("Open folder as vault…", action: chooseFolder)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundPrimary)
        .onAppear { vaults = KnownVault.fromObsidianConfig() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Vault"
        if panel.runModal() == .OK, let url = panel.url { model.openVault(url) }
    }
}

/// Asks before deleting a note, file or folder (Obsidian's "Delete file" dialog), with "Don't ask again".
struct DeleteConfirmView: View {
    @ObservedObject var model: VaultModel
    let item: PendingDelete
    @State private var dontAskAgain = false

    private var detail: String {
        let what: String
        if item.isFolder {
            what = item.fileCount == 0 ? "This empty folder"
                : "This folder and the \(item.fileCount) file\(item.fileCount == 1 ? "" : "s") in it"
        } else {
            what = "This file"
        }
        switch item.option {
        case .system: return "\(what) will be moved to the macOS Trash."
        case .local: return "\(what) will be moved to the vault’s .trash folder."
        case .none: return "\(what) will be deleted permanently. This can’t be undone."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(item.isFolder ? "Delete folder" : "Delete file", systemImage: "trash").font(.title3.bold())
            Text("Are you sure you want to delete “\(item.name)”?")
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.callout).foregroundStyle(item.option == .none ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Don’t ask again", isOn: $dontAskAgain)
                Spacer()
                Button("Cancel") { model.pendingDelete = nil }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    if dontAskAgain { UserDefaults.standard.set(false, forKey: SettingsKey.confirmFileDeletion) }
                    model.performDelete(item)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// Obsidian's "Delete file attachments?": the attachments only the deleted note used, all ticked.
struct DeleteAttachmentsView: View {
    @ObservedObject var model: VaultModel
    let pending: PendingAttachments
    @State private var unchecked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Delete file attachments?", systemImage: "paperclip").font(.title3.bold())
            Text(pending.paths.count == 1
                 ? "This attachment is no longer used in any notes. Would you like to delete it?"
                 : "These \(pending.paths.count) attachments are no longer used in any notes. Would you like to delete them?")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pending.paths, id: \.self) { path in
                        Toggle(isOn: Binding(get: { !unchecked.contains(path) },
                                             set: { on in if on { unchecked.remove(path) } else { unchecked.insert(path) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text((path as NSString).lastPathComponent)
                                let folder = (path as NSString).deletingLastPathComponent
                                if !folder.isEmpty { Text(folder).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("Cancel") { model.pendingAttachments = nil }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    model.deleteAttachments(pending.paths.filter { !unchecked.contains($0) }, of: pending)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(unchecked.count == pending.paths.count)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
