import AppKit
import SwiftUI

/// Obsidian default-theme colors for the native chrome (sidebars, tabs, modals),
/// matching the CSS variables in Resources/Web/obsidian.css.
enum Theme {
    static let backgroundPrimary = dynamic(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let backgroundSecondary = dynamic(light: 0xF6F6F6, dark: 0x262626)
    static let titlebar = dynamic(light: 0xEDEDED, dark: 0x181818)
    static let border = dynamic(light: 0xE0E0E0, dark: 0x363636)
    static let textNormal = dynamic(light: 0x222222, dark: 0xDADADA)
    static let textMuted = dynamic(light: 0x5C5C5C, dark: 0xB3B3B3)
    static let textFaint = dynamic(light: 0xABABAB, dark: 0x666666)
    static let accent = dynamic(light: 0x8A5CF5, dark: 0xA68AF9)
    static let hover = Color(nsColor: NSColor(name: nil) { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.075)
    })
    static let selection = Color(nsColor: NSColor(name: nil) { a in
        isDark(a) ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)
    })
    static let searchHighlight = Color(nsColor: NSColor(red: 1, green: 0.82, blue: 0, alpha: 0.4))

    static let uiFont = Font.system(size: 13)
    static let smallFont = Font.system(size: 12)

    static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in nsColor(isDark(a) ? dark : light) })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Obsidian-style #tag pill for native views.
struct TagChip: View {
    let tag: String
    var body: some View {
        Text("#" + tag)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
    }
}
