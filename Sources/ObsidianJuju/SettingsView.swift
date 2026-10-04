import AppKit
import SwiftUI
import ObsidianJujuCore

struct SettingsView: View {
    @ObservedObject var model: VaultModel
    @AppStorage(HotkeyModifier.storageKey) private var modifierRaw = HotkeyModifier.command.rawValue
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.fontSize) private var fontSize = SettingsKey.defaultFontSize
    @AppStorage(SettingsKey.readableLineWidth) private var readable = true
    @AppStorage(SettingsKey.openLastVault) private var openLastVault = true
    @AppStorage(SettingsKey.vimEnabled) private var vimEnabled = false
    @AppStorage(SettingsKey.escapeChord) private var escapeChord = ""
    @AppStorage(SettingsKey.livePreview) private var livePreview = true
    @AppStorage(SettingsKey.confirmFileDeletion) private var confirmDeletion = true
    @AppStorage(SettingsKey.jujuPixAutoLockMinutes) private var jujuPixAutoLock = SettingsKey.defaultJujuPixAutoLockMinutes
    @AppStorage(SettingsKey.jujuPixRememberInKeychain) private var jujuPixKeychain = false

    private var modifier: HotkeyModifier { HotkeyModifier(rawValue: modifierRaw) ?? .command }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Hotkey modifier (CC)").font(.headline)
                Picker("", selection: $modifierRaw) {
                    ForEach(HotkeyModifier.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance").font(.headline)
                Picker("", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                HStack {
                    Text("Font size")
                    Slider(value: $fontSize, in: 12...24, step: 1).frame(width: 160)
                    Text("\(Int(fontSize)) px").monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("Readable line length", isOn: $readable)
                Toggle("Reopen the last vault on launch", isOn: $openLastVault)
                Toggle("Confirm before deleting notes and folders", isOn: $confirmDeletion)
                if let root = model.vaultURL {
                    let trash: String = switch NewNoteLocation.trashOption(vault: root) {
                    case .system: "Move to system trash"
                    case .local: "Move to Obsidian trash (.trash folder)"
                    case .none: "Permanently delete"
                    }
                    Text("Deleted files: \(trash). Delete attachments when deleting files: "
                         + "\(NewNoteLocation.deleteAttachments(vault: root).label). "
                         + "These follow this vault’s Obsidian settings (Files and links).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Editor").font(.headline)
                Toggle("Live preview (styles and images while editing, like Obsidian)", isOn: $livePreview)
                    .onChange(of: livePreview) { _, _ in model.editSessions.values.forEach { $0.restyle() } }
                Toggle("Vim keybindings (as in Notepad+++)", isOn: $vimEnabled)
                HStack {
                    Text("Escape chord")
                    TextField("e.g. jk", text: $escapeChord).frame(width: 60)
                        .onChange(of: escapeChord) { _, v in if v.count > 2 { escapeChord = String(v.prefix(2)) } }
                    Text("two keys typed quickly leave Insert mode").font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!vimEnabled)
            }

            if model.vaultURL != nil { AttachmentFoldersSection(model: model) }

            VStack(alignment: .leading, spacing: 6) {
                Text("JujuPix encrypted photos").font(.headline)
                Picker("Lock again", selection: $jujuPixAutoLock) {
                    Text("After 5 minutes idle").tag(5)
                    Text("After 15 minutes idle").tag(15)
                    Text("After 30 minutes idle").tag(30)
                    Text("After 1 hour idle").tag(60)
                    Text("Only when quitting").tag(0)
                }
                .frame(width: 300)
                Toggle("Remember in Keychain (unlock with Touch ID)", isOn: $jujuPixKeychain)
                    .onChange(of: jujuPixKeychain) { _, on in model.jujuPixKeychainSettingChanged(on) }
                Text(jujuPixKeychain
                     ? "The unlocked keys (not your password) are kept in your Keychain; unlocking asks for Touch ID or your Mac password."
                     : "You’re asked for your JujuPix password each time photos are unlocked.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Hotkeys").font(.headline)
                let m = modifier.symbol
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    row("\(m)O", "Quick switcher")
                    row("\(m)P", "Command palette")
                    row("\(m)⇧F", "Search in all files")
                    row("\(m)F", "Find in current note")
                    row("\(m)E", "Unlock note for editing / toggle preview")
                    row("\(m)N", "New note")
                    row("\(m)B / \(m)I", "Bold / italic (while editing)")
                    row("\(m)↑ / \(m)↓, Home / End", "Start / end of note, of line")
                    row("\(m)⌥← / \(m)⌥→", "Navigate back / forward")
                    row("\(m)-click", "Open link in new tab")
                    row("\(m)T / \(m)W", "New tab / close tab")
                    row("\(m)⇧T", "Undo close tab")
                    row("⌃Tab / ⌃⇧Tab, \(m)PgDn / \(m)PgUp", "Next / previous tab")
                    row("\(m)1 … \(m)8, \(m)9", "Go to tab N / last tab")
                    row("\(m)= / \(m)- / \(m)0", "Zoom in / out / reset")
                    row("\(m)R", "Reload vault index")
                    row("\(m),", "Settings")
                }
                .font(.callout)
            }

            Text("Notes are read-only until you unlock one; only an unlocked note is ever written, and new notes are only created when you ask. The search index is kept in ~/Library/Caches/ObsidianJuju.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { model.showSettings = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: appearanceRaw) { _, _ in AppearanceMode.apply() }
        .onChange(of: fontSize) { _, _ in model.applyViewOptions() }
        .onChange(of: readable) { _, _ in model.applyViewOptions() }
    }

    fileprivate func row(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).font(.callout.monospaced())
            Text(action).foregroundStyle(.secondary)
        }
    }
}

/// Folders outside the vault that `![](<juju:name>)` images are looked up in (after the vault), per vault.
private struct AttachmentFoldersSection: View {
    @ObservedObject var model: VaultModel
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attachment folders outside the vault").font(.headline)
            Text("For images, audio and video written as ![](<juju:file name.png>) (add |300 after the brackets' text for a width, e.g. ![|300](<juju:a.png>)). Looked up in the vault first, then in these folders from top to bottom. They are only read.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(Array(model.attachmentFolders.enumerated()), id: \.offset) { i, path in
                    Text(path).lineLimit(1).truncationMode(.middle).help(path).tag(i)
                }
            }
            .frame(height: 90)
            .overlay {
                if model.attachmentFolders.isEmpty {
                    Text("No folders").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Button("Add Folder…") { add() }
                Button("Remove") {
                    guard let i = selection else { return }
                    var f = model.attachmentFolders
                    f.remove(at: i)
                    selection = nil
                    model.setAttachmentFolders(f)
                }
                .disabled(selection == nil)
                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                    .disabled((selection ?? 0) == 0).help("Search this folder earlier")
                Button { move(1) } label: { Image(systemName: "arrow.down") }
                    .disabled(selection.map { $0 >= model.attachmentFolders.count - 1 } ?? true).help("Search this folder later")
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder of attachments outside the vault"
        if panel.runModal() == .OK, let url = panel.url { model.addAttachmentFolder(url) }
    }

    private func move(_ delta: Int) {
        guard let i = selection, model.attachmentFolders.indices.contains(i + delta) else { return }
        var f = model.attachmentFolders
        f.swapAt(i, i + delta)
        model.setAttachmentFolders(f)
        selection = i + delta
    }
}
