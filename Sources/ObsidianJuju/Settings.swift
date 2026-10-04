import AppKit
import SwiftUI

/// The "CC" modifier from the hotkey spec: Ctrl or Cmd, configurable in Settings.
/// Same storage key and labels as BetterFileExplorer and PSY.
enum HotkeyModifier: String, CaseIterable, Identifiable {
    case command, control

    var id: String { rawValue }
    var flags: EventModifiers { self == .command ? .command : .control }
    var eventFlags: NSEvent.ModifierFlags { self == .command ? .command : .control }
    var label: String { self == .command ? "Command (⌘)" : "Control (⌃)" }
    var symbol: String { self == .command ? "⌘" : "⌃" }

    static let storageKey = "hotkeyModifier"
    static var current: HotkeyModifier {
        HotkeyModifier(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .command
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    static let storageKey = "appearance"

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func apply() {
        let mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
        NSApp.appearance = mode.nsAppearance
    }
}

enum SettingsKey {
    static let fontSize = "fontSize"
    static let readableLineWidth = "readableLineWidth"
    static let zoom = "zoom"
    static let lastVaultPath = "lastVaultPath"
    static let openLastVault = "openLastVault"
    static let defaultFontSize = 16.0
    /// Vim keybindings in the note editor (same key name as Notepad+++).
    static let vimEnabled = "vimEnabled"
    /// Two-letter chord that leaves Insert mode (e.g. "jk"); empty = off.
    static let escapeChord = "escapeChord"
    /// Obsidian-style live preview in the note editor (styles and images while editing); off = plain source.
    static let livePreview = "livePreview"
    /// Ask before deleting a note or folder (default on); "Don't ask again" in the dialog turns it off.
    static let confirmFileDeletion = "confirmFileDeletion"
    /// JujuPix encrypted photos: minutes of idle time before they lock again; 0 = only when quitting.
    static let jujuPixAutoLockMinutes = "jujuPixAutoLockMinutes"
    static let defaultJujuPixAutoLockMinutes = 15
    /// Save the unlocked JujuPix keys in the Keychain (opened with Touch ID or the Mac password) instead of
    /// asking for the JujuPix password each time.
    static let jujuPixRememberInKeychain = "jujuPixRememberInKeychain"
}
