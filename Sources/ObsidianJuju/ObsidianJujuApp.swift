import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppearanceMode.apply()
            Hotkeys.install(model: VaultModel.shared)
            let d = UserDefaults.standard
            if d.object(forKey: SettingsKey.openLastVault) as? Bool ?? true,
               let path = d.string(forKey: SettingsKey.lastVaultPath),
               FileManager.default.fileExists(atPath: path) {
                VaultModel.shared.openVault(URL(fileURLWithPath: path))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { VaultModel.shared.flushEdits() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ObsidianJujuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = VaultModel.shared
    @AppStorage(HotkeyModifier.storageKey) private var modifierRaw = HotkeyModifier.command.rawValue

    private var mod: EventModifiers { (HotkeyModifier(rawValue: modifierRaw) ?? .command).flags }

    var body: some Scene {
        // Shortcuts below are shown in the menus; the key presses themselves are handled by `Hotkeys`
        // so they work from any focused view and follow the CC setting.
        Window("ObsidianJuju", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings = true }.keyboardShortcut(",", modifiers: mod)
            }
            CommandGroup(replacing: .printItem) {}
            CommandGroup(replacing: .newItem) {
                Button("New Note") { model.beginNewNote() }.keyboardShortcut("n", modifiers: mod)
                Button("Duplicate Current File") { model.duplicateFile() }
                Button("Delete Current File…") { model.requestDelete() }
                Button("New Tab") { model.newTab() }.keyboardShortcut("t", modifiers: mod)
                Button("Open Another Vault…") { model.closeVault() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { model.closeTab() }.keyboardShortcut("w", modifiers: mod)
                Button("Undo Close Tab") { model.reopenClosedTab() }.keyboardShortcut("t", modifiers: mod.union(.shift))
                Divider()
                Button("Toggle Editing / Reading View") { model.toggleEdit() }.keyboardShortcut("e", modifiers: mod)
                Button("Lock Note") { if let id = model.activeTabID { model.lock(tabID: id) } }
                Button("Insert External Image…") { model.beginInsertExternalImage() }
                Divider()
                Button("Open in Obsidian") { model.openInObsidian() }
                Button("Reveal in Finder") { model.revealInFinder() }
            }
            CommandMenu("Format") {
                Button("Bold") { model.toggleFormat(.bold) }.keyboardShortcut("b", modifiers: mod)
                Button("Italic") { model.toggleFormat(.italic) }.keyboardShortcut("i", modifiers: mod)
                Button("Strikethrough") { model.toggleFormat(.strikethrough) }
                Button("Highlight") { model.toggleFormat(.highlight) }
                Button("Bold and Italic") { model.toggleFormat(.boldItalic) }
                Divider()
                Button("Add File Property") { model.addFileProperty() }.keyboardShortcut(";", modifiers: mod)
                Button("Toggle Live Preview / Source Mode") { model.toggleLivePreview() }
            }
            CommandMenu("Go") {
                Button("Quick Switcher…") { model.overlay = .switcher }.keyboardShortcut("o", modifiers: mod)
                Button("Command Palette…") { model.overlay = .palette }.keyboardShortcut("p", modifiers: mod)
                Button("Search in All Files") { model.focusSearch() }.keyboardShortcut("f", modifiers: mod.union(.shift))
                Button("Find in Note") { model.showFind() }.keyboardShortcut("f", modifiers: mod)
                Divider()
                Button("Back") { model.goBack() }.keyboardShortcut(.leftArrow, modifiers: mod.union(.option))
                Button("Forward") { model.goForward() }.keyboardShortcut(.rightArrow, modifiers: mod.union(.option))
                Divider()
                Button("Next Tab") { model.selectTab(offset: 1) }.keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab") { model.selectTab(offset: -1) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
                Button("Random Note") { model.openRandomNote() }
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Left Sidebar") { model.showLeft.toggle() }
                Button("Toggle Right Sidebar") { model.showRight.toggle() }
                Divider()
                Button("Zoom In") { model.zoom(0.1) }.keyboardShortcut("=", modifiers: mod)
                Button("Zoom Out") { model.zoom(-0.1) }.keyboardShortcut("-", modifiers: mod)
                Button("Actual Size") { model.zoom(nil) }.keyboardShortcut("0", modifiers: mod)
                Divider()
                Button("Reload Vault Index") { model.scheduleRefresh(); model.rerenderAll() }.keyboardShortcut("r", modifiers: mod)
            }
        }
    }
}
