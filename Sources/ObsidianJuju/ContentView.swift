import ObsidianJujuCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        Group {
            if model.vaultURL == nil {
                VaultPickerView(model: model)
            } else {
                WorkspaceView(model: model)
            }
        }
        .background(Theme.backgroundPrimary)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showJujuPixUnlock) { JujuPixUnlockView(model: model) }
        .sheet(item: $model.pendingDelete) { DeleteConfirmView(model: model, item: $0) }
        .sheet(item: $model.pendingAttachments) { DeleteAttachmentsView(model: model, pending: $0) }
        .navigationTitle(model.vaultURL == nil ? "ObsidianJuju" : model.vaultName)
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: VaultModel
    @AppStorage("leftWidth") private var leftWidth = 260.0
    @AppStorage("rightWidth") private var rightWidth = 280.0

    var body: some View {
        HStack(spacing: 0) {
            if model.showLeft {
                LeftSidebar(model: model)
                    .frame(width: leftWidth)
                ResizeHandle(width: $leftWidth, sign: 1)
            }
            CenterPane(model: model)
                .frame(minWidth: 360)
            if model.showRight {
                ResizeHandle(width: $rightWidth, sign: -1)
                RightSidebar(model: model)
                    .frame(width: rightWidth)
            }
        }
        .overlay { OverlayHost(model: model) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textNormal)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.backgroundSecondary)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 2))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
    }
}

/// Draggable 1px divider between panes.
struct ResizeHandle: View {
    @Binding var width: Double
    let sign: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1)
            .overlay(
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            let base = start ?? width
                            start = base
                            width = min(max(base + sign * g.translation.width, 160), 520)
                        }
                        .onEnded { _ in start = nil })
            )
    }
}

// MARK: Center

struct CenterPane: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        VStack(spacing: 0) {
            TabBar(model: model)
            if let tab = model.activeTab {
                NoteHeader(model: model, tab: tab)
                if let session = model.editSessions[tab.id] { ConflictBar(session: session) }
                if model.showFindBar && tab.current != nil && model.editSessions[tab.id] == nil { FindBar(model: model) }
                ZStack {
                    Theme.backgroundPrimary
                    ForEach(model.tabs) { t in
                        let active = t.id == model.activeTabID
                        if let path = t.current?.path, path.lowercased().hasSuffix(".pdf"), let root = model.vaultURL {
                            PDFFileView(url: root.appendingPathComponent(path))
                                .opacity(active ? 1 : 0)
                                .allowsHitTesting(active)
                        } else if t.current != nil {
                            NoteWebView(controller: model.controller(for: t.id))
                                .opacity(active ? 1 : 0)
                                .allowsHitTesting(active)
                            if let session = model.editSessions[t.id] {
                                EditorHost(session: session, active: active)
                                    .id(ObjectIdentifier(session))
                            }
                        }
                    }
                    if tab.current == nil { EmptyTabView(model: model) }
                }
            }
        }
        .background(Theme.backgroundPrimary)
    }
}

struct TabBar: View {
    @ObservedObject var model: VaultModel
    @State private var hovered: UUID?

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "sidebar.left", help: "Toggle left sidebar") { model.showLeft.toggle() }
                .padding(.horizontal, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.tabs) { tab in tabHeader(tab) }
                    IconButton(symbol: "plus", help: "New tab (\(HotkeyModifier.current.symbol)T)") { model.newTab() }
                        .padding(.leading, 4)
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            IconButton(symbol: "sidebar.right", help: "Toggle right sidebar") { model.showRight.toggle() }
                .padding(.horizontal, 6)
        }
        .frame(height: 40)
        .background(Theme.backgroundSecondary)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func tabHeader(_ tab: Tab) -> some View {
        let active = tab.id == model.activeTabID
        return HStack(spacing: 6) {
            Text(tab.title)
                .font(Theme.uiFont)
                .lineLimit(1)
                .foregroundStyle(active ? Theme.textNormal : Theme.textMuted)
                .frame(maxWidth: 180, alignment: .leading)
            Button { model.closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textMuted)
            .opacity(active || hovered == tab.id ? 1 : 0)
            .help("Close tab (\(HotkeyModifier.current.symbol)W)")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 33)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                .fill(active ? Theme.backgroundPrimary : (hovered == tab.id ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.activate(tab.id) }
        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
        .help(tab.current?.path ?? "")
    }
}

struct NoteHeader: View {
    @ObservedObject var model: VaultModel
    let tab: Tab

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "arrow.left", help: "Navigate back (\(HotkeyModifier.current.symbol)⌥←)") { model.goBack() }
                .disabled(!tab.canGoBack).opacity(tab.canGoBack ? 1 : 0.4)
            IconButton(symbol: "arrow.right", help: "Navigate forward (\(HotkeyModifier.current.symbol)⌥→)") { model.goForward() }
                .disabled(!tab.canGoForward).opacity(tab.canGoForward ? 1 : 0.4)
            Spacer()
            if let path = tab.current?.path {
                breadcrumb(path)
            }
            Spacer()
            if let path = tab.current?.path {
                EditControls(model: model, tabID: tab.id, path: path)
                IconButton(symbol: "arrow.up.forward.app", help: "Open in Obsidian (to edit)") { model.openInObsidian() }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Theme.backgroundPrimary)
    }

    private func breadcrumb(_ path: String) -> some View {
        let folder = (path as NSString).deletingLastPathComponent
        return HStack(spacing: 0) {
            if !folder.isEmpty {
                Text(folder.replacingOccurrences(of: "/", with: " / ") + " / ").foregroundStyle(Theme.textFaint)
            }
            Text(tab.title).foregroundStyle(Theme.textNormal)
        }
        .font(Theme.uiFont)
        .lineLimit(1)
        .truncationMode(.head)
    }
}

/// The source editor over a tab's web view, hidden while that note shows its preview.
private struct EditorHost: View {
    @ObservedObject var session: EditSession
    let active: Bool
    @AppStorage(SettingsKey.vimEnabled) private var vimEnabled = false

    var body: some View {
        if !session.showPreview {
            VStack(spacing: 0) {
                NoteEditorView(session: session, active: active)
                if vimEnabled { VimStatusBar(label: session.vimLabel) }
            }
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
        }
    }
}

/// Vim mode / command line under the editor, like Notepad+++'s status bar.
private struct VimStatusBar: View {
    let label: String

    var body: some View {
        HStack {
            Text(label.isEmpty ? " " : label)
                .font(.system(size: 12, weight: label.hasPrefix(":") || label.hasPrefix("/") || label.hasPrefix("?") ? .regular : .semibold,
                              design: .monospaced))
                .foregroundStyle(label == "INSERT" ? Theme.accent : Theme.textMuted)
            Spacer()
            Text("Vim").font(Theme.smallFont).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.backgroundSecondary)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

struct FindBar: View {
    @ObservedObject var model: VaultModel
    @State private var text = ""
    @State private var notFound = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
            TextField("Find in note…", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .focused($focused)
                .onSubmit { find(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onKeyPress(.escape) { close(); return .handled }
            if notFound { Text("No results").font(Theme.smallFont).foregroundStyle(Theme.textFaint) }
            IconButton(symbol: "chevron.up", help: "Previous (⇧↩)") { find(backwards: true) }
            IconButton(symbol: "chevron.down", help: "Next (↩)") { find(backwards: false) }
            IconButton(symbol: "xmark", help: "Close (esc)") { close() }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.backgroundSecondary)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .onAppear { takeFocus { focused = true } }
        .onChange(of: model.findFocusToken) { _, _ in takeFocus { focused = true } }
        .onChange(of: text) { _, _ in notFound = false }
    }

    private func find(backwards: Bool) {
        guard !text.isEmpty, let c = model.activeController else { return }
        c.find(text, backwards: backwards) { found in notFound = !found }
    }

    private func close() {
        model.showFindBar = false
        model.focusWebView()
    }
}

struct EmptyTabView: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        VStack(spacing: 14) {
            Text("No file is open").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.textNormal)
            if model.indexing {
                ProgressView().controlSize(.small)
                Text("Indexing vault…").font(Theme.uiFont).foregroundStyle(Theme.textMuted)
            }
            VStack(spacing: 6) {
                LinkButton("Go to file (\(HotkeyModifier.current.symbol)O)") { model.overlay = .switcher }
                LinkButton("Search all files (\(HotkeyModifier.current.symbol)⇧F)") { model.focusSearch() }
                LinkButton("Command palette (\(HotkeyModifier.current.symbol)P)") { model.overlay = .palette }
                if model.tabs.count > 1 { LinkButton("Close") { model.closeTab() } }
            }
            let recent = model.recentFiles.prefix(8)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(Theme.smallFont).foregroundStyle(Theme.textFaint).padding(.bottom, 2)
                    ForEach(Array(recent), id: \.self) { p in
                        LinkButton(((p as NSString).lastPathComponent as NSString).deletingPathExtension) { model.open(p) }
                    }
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundPrimary)
    }
}

// MARK: Small shared controls

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textMuted)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct LinkButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }

    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 14)).foregroundStyle(Theme.accent) }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

/// True when the CC modifier is held — CC+click opens in a new tab, as in Obsidian.
@MainActor
func ccHeld() -> Bool {
    NSEvent.modifierFlags.contains(HotkeyModifier.current.eventFlags)
}

/// Moves keyboard focus to a SwiftUI text field. The note's WKWebView is an AppKit first responder that
/// SwiftUI's @FocusState can't take focus from, so release it first, then focus on the next run loop
/// pass (and once more shortly after, in case the field wasn't in the window yet).
@MainActor
func takeFocus(_ focus: @escaping @MainActor () -> Void) {
    NSApp.keyWindow?.makeFirstResponder(nil)
    DispatchQueue.main.async { focus() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus() }
}
