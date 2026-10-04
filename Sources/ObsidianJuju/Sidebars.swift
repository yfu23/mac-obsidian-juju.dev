import ObsidianJujuCore
import SwiftUI

// MARK: Left sidebar

struct LeftSidebar: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                paneButton(.files, "folder", "Files")
                paneButton(.search, "magnifyingglass", "Search (\(HotkeyModifier.current.symbol)⇧F)")
                paneButton(.tags, "tag", "Tags")
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            Group {
                switch model.leftPane {
                case .files: FileTreeView(model: model)
                case .search: SearchPane(model: model)
                case .tags: TagsPane(model: model)
                }
            }
            .frame(maxHeight: .infinity)

            VaultFooter(model: model)
        }
        .background(Theme.backgroundSecondary)
    }

    private func paneButton(_ pane: LeftPane, _ symbol: String, _ help: String) -> some View {
        Button { model.leftPane = pane } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(model.leftPane == pane ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.leftPane == pane ? Theme.textNormal : Theme.textMuted)
        .help(help)
    }
}

struct VaultFooter: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(KnownVault.fromObsidianConfig()) { v in
                    Button(v.name) { model.openVault(URL(fileURLWithPath: v.path)) }
                }
                Divider()
                Button("Open another vault…") { model.closeVault() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    Text(model.vaultName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(Theme.textNormal)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            if model.indexing { ProgressView().controlSize(.mini).help("Indexing…") }
            IconButton(symbol: "gearshape", help: "Settings (\(HotkeyModifier.current.symbol),)") { model.showSettings = true }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

// MARK: Files

struct FileTreeView: View {
    @ObservedObject var model: VaultModel

    private struct Row: Identifiable {
        let node: TreeNode
        let depth: Int
        var id: String { node.id }
    }

    private var rows: [Row] {
        var out: [Row] = []
        func walk(_ node: TreeNode, _ depth: Int) {
            for child in node.children {
                out.append(Row(node: child, depth: depth))
                if child.isFolder && model.expandedFolders.contains(child.id) { walk(child, depth + 1) }
            }
        }
        walk(model.tree, 0)
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        FileRow(model: model, node: row.node, depth: row.depth).id(row.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.activePath) { _, path in
                if let path { withAnimation { proxy.scrollTo(path, anchor: .center) } }
            }
        }
    }
}

private struct FileRow: View {
    @ObservedObject var model: VaultModel
    let node: TreeNode
    let depth: Int
    @State private var hover = false

    private var isActive: Bool { !node.isFolder && model.activePath == node.id }
    private var expanded: Bool { model.expandedFolders.contains(node.id) }

    var body: some View {
        HStack(spacing: 4) {
            if node.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(Theme.textFaint)
                    .frame(width: 12)
            }
            Text(node.name)
                .font(Theme.uiFont)
                .lineLimit(1)
                .foregroundStyle(isActive || hover ? Theme.textNormal : Theme.textMuted)
            if !node.isFolder, case let ext = (node.id as NSString).pathExtension, ext.lowercased() != "md" {
                Text(ext.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.hover))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16 + (node.isFolder ? 8 : 24))
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Theme.selection : (hover ? Theme.hover : .clear))
            .padding(.horizontal, 6))
        .overlay(alignment: .leading) {
            // Indentation guides, like Obsidian's.
            HStack(spacing: 0) {
                ForEach(0..<depth, id: \.self) { _ in
                    Rectangle().fill(Theme.border).frame(width: 1).padding(.leading, 13).padding(.trailing, 2)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if node.isFolder {
                if expanded { model.expandedFolders.remove(node.id) } else { model.expandedFolders.insert(node.id) }
            } else {
                model.open(node.id, newTab: ccHeld())
            }
        }
        .contextMenu {
            Button("New note") { model.beginNewNote(in: node.isFolder ? node.id : (node.id as NSString).deletingLastPathComponent) }
            Divider()
            if !node.isFolder {
                Button("Open in new tab") { model.open(node.id, newTab: true) }
                if NoteWriter.isEditable(node.id) { Button("Make a copy") { model.duplicateFile(node.id) } }
                Button("Open in Obsidian") { model.open(node.id); model.openInObsidian() }
                Divider()
            }
            Button("Reveal in Finder") {
                if let root = model.vaultURL { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(node.id)]) }
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.id, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { model.requestDelete(node.id, isFolder: node.isFolder) }
        }
    }
}

// MARK: Search

struct SearchPane: View {
    @ObservedObject var model: VaultModel
    @FocusState private var focused: Bool
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint).font(.system(size: 12))
                TextField("Search…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.uiFont)
                    .focused($focused)
                    .onSubmit { model.runSearch(debounce: false) }
                    .onKeyPress(.escape) { model.focusWebView(); return .handled }
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.backgroundPrimary))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Theme.accent.opacity(0.6) : Theme.border))
            .padding(10)

            if model.searchText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Search options").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    hint("word another", "notes containing both")
                    hint("\"exact phrase\"", "exact match")
                    hint("-word", "exclude")
                    hint("tag:#work", "notes with a tag")
                    hint("path:Projects", "match folder/path")
                    hint("file:plan", "match file name")
                }
                .padding(.horizontal, 14)
                Spacer()
            } else {
                HStack {
                    Text(summary).font(Theme.smallFont).foregroundStyle(Theme.textFaint)
                    Spacer()
                    if model.searching { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 14).padding(.bottom, 4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.searchResults.hits) { hit in hitView(hit) }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 10)
                }
            }
        }
        .onAppear { takeFocus { focused = true } }
        .onChange(of: model.searchFocusToken) { _, _ in takeFocus { focused = true } }
        .onChange(of: model.searchText) { _, _ in model.runSearch() }
    }

    private var summary: String {
        let n = model.searchResults.hits.count
        if model.searching && n == 0 { return "Searching…" }
        return model.searchResults.truncated ? "\(n)+ results" : "\(n) result\(n == 1 ? "" : "s")"
    }

    private func hint(_ q: String, _ desc: String) -> some View {
        HStack {
            Text(q).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textNormal)
            Spacer()
            Text(desc).font(Theme.smallFont).foregroundStyle(Theme.textFaint)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.searchText = q }
    }

    @ViewBuilder
    private func hitView(_ hit: SearchHit) -> some View {
        let isCollapsed = collapsed.contains(hit.path)
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isCollapsed || hit.matches.isEmpty ? 0 : 90))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 12)
                .onTapGesture { if isCollapsed { collapsed.remove(hit.path) } else { collapsed.insert(hit.path) } }
            Text(displayName(hit.path)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textNormal).lineLimit(1)
            Spacer()
            if !hit.matches.isEmpty {
                Text("\(hit.matches.count)").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { open(hit, nil) }
        .help(hit.path)
        .contextMenu { openMenu(hit.path) }

        if !isCollapsed {
            ForEach(hit.matches, id: \.self) { m in
                Text(attributed(m))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.backgroundPrimary))
                    .padding(.leading, 18)
                    .contentShape(Rectangle())
                    .onTapGesture { open(hit, m) }
                    .contextMenu { openMenu(hit.path) }
            }
        }
    }

    @ViewBuilder private func openMenu(_ path: String) -> some View {
        Button("Open in new tab") { model.open(path, highlight: model.searchResults.query.highlightTerms, newTab: true) }
    }

    private func open(_ hit: SearchHit, _ match: SearchMatch?) {
        model.open(hit.path, highlight: model.searchResults.query.highlightTerms, newTab: ccHeld())
    }

    private func attributed(_ m: SearchMatch) -> AttributedString {
        var out = AttributedString()
        for seg in m.segments {
            var piece = AttributedString(seg.text)
            if seg.highlighted {
                piece.backgroundColor = Theme.searchHighlight
                piece.foregroundColor = Theme.textNormal
            }
            out += piece
        }
        return out
    }
}

func displayName(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.lowercased().hasSuffix(".md") ? (name as NSString).deletingPathExtension : name
}

// MARK: Tags

struct TagsPane: View {
    @ObservedObject var model: VaultModel
    @State private var expanded: Set<String> = []

    private struct TagNode: Identifiable {
        let full: String
        let name: String
        var count: Int
        var children: [TagNode]
        var id: String { full.lowercased() }
    }

    private var roots: [TagNode] {
        final class Box { var name = ""; var full = ""; var count = 0; var kids: [String: Box] = [:] }
        let root = Box()
        for (tag, count) in model.snapshot.tagCounts {
            var node = root
            var full = ""
            for part in tag.split(separator: "/") {
                full = full.isEmpty ? String(part) : full + "/" + part
                let key = part.lowercased()
                let next = node.kids[key] ?? { let b = Box(); b.name = String(part); b.full = full; node.kids[key] = b; return b }()
                next.count += count
                node = next
            }
        }
        func build(_ b: Box) -> [TagNode] {
            b.kids.values.map { TagNode(full: $0.full, name: $0.name, count: $0.count, children: build($0)) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return build(root)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.snapshot.tagCounts.isEmpty {
                    Text("No tags found.").font(Theme.uiFont).foregroundStyle(Theme.textFaint).padding()
                }
                ForEach(flatten(roots, 0), id: \.0.id) { node, depth in row(node, depth) }
            }
            .padding(.vertical, 6)
        }
    }

    private func flatten(_ nodes: [TagNode], _ depth: Int) -> [(TagNode, Int)] {
        nodes.flatMap { n in [(n, depth)] + (expanded.contains(n.id) ? flatten(n.children, depth + 1) : []) }
    }

    private func row(_ node: TagNode, _ depth: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(expanded.contains(node.id) ? 90 : 0))
                .foregroundStyle(Theme.textFaint)
                .frame(width: 12)
                .opacity(node.children.isEmpty ? 0 : 1)
                .onTapGesture { if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) } }
            TagChip(tag: node.name)
            Spacer()
            Text("\(node.count)").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
        }
        .padding(.leading, CGFloat(depth) * 16 + 8).padding(.trailing, 12)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture { model.searchTag(node.full) }
    }
}

// MARK: Right sidebar

struct RightSidebar: View {
    @ObservedObject var model: VaultModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                paneButton(.outline, "list.bullet.indent", "Outline")
                paneButton(.backlinks, "link", "Backlinks")
                paneButton(.outgoing, "arrow.up.right", "Outgoing links")
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch model.rightPane {
                    case .outline: outline
                    case .backlinks: backlinks
                    case .outgoing: outgoing
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(Theme.backgroundSecondary)
    }

    private func paneButton(_ pane: RightPane, _ symbol: String, _ help: String) -> some View {
        Button { model.rightPane = pane } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(model.rightPane == pane ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.rightPane == pane ? Theme.textNormal : Theme.textMuted)
        .help(help)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 14).padding(.bottom, 6)
    }

    private func empty(_ s: String) -> some View {
        Text(s).font(Theme.uiFont).foregroundStyle(Theme.textFaint).padding(.horizontal, 14)
    }

    @ViewBuilder private var outline: some View {
        if model.outline.isEmpty {
            empty(model.activePath == nil ? "No file open." : "No headings in this note.")
        } else {
            let minLevel = model.outline.map(\.level).min() ?? 1
            ForEach(model.outline) { item in
                HoverRow {
                    Text(item.text).font(Theme.uiFont).foregroundStyle(Theme.textMuted).lineLimit(2)
                        .padding(.leading, CGFloat(item.level - minLevel) * 14)
                } action: { model.scrollToHeading(item) }
            }
        }
    }

    @ViewBuilder private var backlinks: some View {
        sectionTitle("Linked mentions  \(model.backlinks.count)")
        if model.backlinks.isEmpty { empty("No backlinks found.") }
        ForEach(model.backlinks) { b in
            HoverRow {
                Text(displayName(b.source)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textNormal).lineLimit(1)
            } action: { model.open(b.source, newTab: ccHeld()) }
            .contextMenu { Button("Open in new tab") { model.open(b.source, newTab: true) } }
            ForEach(b.matches, id: \.self) { m in
                Text(m.segments.map(\.text).joined())
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.backgroundPrimary))
                    .padding(.leading, 20).padding(.trailing, 10).padding(.bottom, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { model.open(b.source, newTab: ccHeld()) }
                    .contextMenu { Button("Open in new tab") { model.open(b.source, newTab: true) } }
            }
        }
    }

    @ViewBuilder private var outgoing: some View {
        sectionTitle("Links  \(model.outgoing.count)")
        if model.outgoing.isEmpty { empty("No outgoing links.") }
        ForEach(model.outgoing) { link in
            HoverRow {
                HStack(spacing: 6) {
                    Image(systemName: link.isEmbed ? "photo" : "doc.text").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    Text(link.resolved.map(displayName) ?? link.target).font(Theme.uiFont)
                        .foregroundStyle(link.resolved == nil ? Theme.textFaint : Theme.textMuted).lineLimit(1)
                    if link.resolved == nil { Text("not created").font(.system(size: 10)).foregroundStyle(Theme.textFaint) }
                }
            } action: { if let p = link.resolved { model.open(p, newTab: ccHeld()) } }
            .contextMenu { if let p = link.resolved { Button("Open in new tab") { model.open(p, newTab: true) } } }
        }
    }
}

struct HoverRow<Content: View>: View {
    @ViewBuilder let content: Content
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack { content; Spacer(minLength: 0) }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Theme.hover : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
    }
}
