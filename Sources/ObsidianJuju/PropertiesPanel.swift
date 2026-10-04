import AppKit
import ObsidianJujuCore
import SwiftUI

/// The note's Properties at the top of the editor in live preview, edited in place like Obsidian's: click a value
/// to change it, toggle checkboxes, add or remove list items and tags, rename or remove a property from its icon
/// menu, and "+ Add property". Every change goes through `Frontmatter.apply`, which rewrites only that property's
/// YAML lines in the editor (so undo and autosave work as for typing).
struct PropertiesPanel: View {
    let properties: [Property]
    /// Width available to the panel (for the key column, as in the reading view: longest key, at most 40%).
    let width: CGFloat
    let fontSize: CGFloat
    /// "Add file property" was requested: show the new-property row.
    let addRequested: Bool
    let edit: (Frontmatter.Edit) -> Void
    /// The panel's own height changed (a row appeared or went away).
    let relayout: () -> Void
    let addFinished: () -> Void

    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Properties")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(Theme.textNormal)
                .padding(.bottom, 6)
            ForEach(properties, id: \.key) { p in
                PropertyRow(property: p, keyWidth: keyWidth, scale: scale, taken: Set(properties.map(\.key)), edit: edit)
            }
            if adding || addRequested {
                NewPropertyRow(keyWidth: keyWidth, scale: scale, taken: Set(properties.map(\.key))) { key in
                    if let key { edit(.set(key: key, value: .text(""))) }
                    adding = false
                    addFinished()
                    relayout()
                }
            }
            Button {
                adding = true
                relayout()
            } label: {
                Label("Add property", systemImage: "plus")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: width, alignment: .leading)
        .padding(.bottom, 4)
    }

    private var scale: CGFloat { fontSize / SettingsKey.defaultFontSize }

    private var keyWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 14 * scale)
        let widest = (properties.map(\.key) + ["Property name"])
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // icon + gap + name + padding (6 left, 16 right), like .metadata-property-key
        return min(ceil(15 * scale + 6 + widest + 22), width * 0.4)
    }
}

private struct PropertyRow: View {
    let property: Property
    let keyWidth: CGFloat
    let scale: CGFloat
    let taken: Set<String>
    let edit: (Frontmatter.Edit) -> Void
    @State private var hover = false
    @State private var renaming = false
    @State private var newKey = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Menu {
                    Button("Rename…") { newKey = property.key; renaming = true }
                    Button("Remove property", role: .destructive) { edit(.remove(key: property.key)) }
                } label: {
                    Image(systemName: kind.icon).font(.system(size: 12 * scale)).foregroundStyle(Theme.textFaint)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 15 * scale)
                .help("Property menu")
                if renaming {
                    TextField("Property name", text: $newKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14 * scale))
                        .focused($keyFocused)
                        .onSubmit(commitRename)
                        .onKeyPress(.escape) { renaming = false; return .handled }
                        .onChange(of: keyFocused) { _, f in if !f, renaming { commitRename() } }
                        .onAppear { DispatchQueue.main.async { keyFocused = true } }
                } else {
                    Text(property.key)
                        .font(.system(size: 14 * scale))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 6).padding(.trailing, 16).padding(.vertical, 2)
            .frame(width: keyWidth, alignment: .leading)
            value
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30 * scale)
        .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Theme.hover : .clear))
        .onHover { hover = $0 }
    }

    private func commitRename() {
        renaming = false
        let k = newKey.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty, k != property.key, !taken.contains(k) { edit(.rename(from: property.key, to: k)) }
    }

    private enum Kind {
        case text, list, tags, checkbox(Bool), date, number, aliases

        var icon: String {
            switch self {
            case .text: return "text.alignleft"
            case .list: return "list.bullet"
            case .tags: return "tag"
            case .checkbox: return "checklist"
            case .date: return "calendar"
            case .number: return "number"
            case .aliases: return "link"
            }
        }
    }

    private var kind: Kind {
        let key = property.key.lowercased()
        if key == "tags" || key == "tag" { return .tags }
        if key == "aliases" || key == "alias" { return .aliases }
        switch property.value {
        case .list: return .list
        case .text(let s):
            if s == "true" || s == "false" { return .checkbox(s == "true") }
            if s.range(of: #"^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$"#, options: .regularExpression) != nil { return .date }
            if s.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil { return .number }
            return .text
        }
    }

    private var isList: Bool {
        if case .list = property.value { return true }
        return false
    }

    @ViewBuilder private var value: some View {
        switch kind {
        case .checkbox(let on):
            Button { edit(.set(key: property.key, value: .text(on ? "false" : "true"))) } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14 * scale))
                    .foregroundStyle(on ? Theme.accent : Theme.textFaint)
            }
            .buttonStyle(.plain)
        case .tags:
            let tags = (isList ? property.value.items : (property.value.items.first ?? "")
                .split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
                .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }.filter { !$0.isEmpty }
            ListEditor(items: tags, scale: scale, tag: true) { edit(.set(key: property.key, value: .list($0))) }
        case .list:
            ListEditor(items: property.value.items, scale: scale, tag: false) { edit(.set(key: property.key, value: .list($0))) }
        case .aliases where isList:
            ListEditor(items: property.value.items, scale: scale, tag: false) { edit(.set(key: property.key, value: .list($0))) }
        default:
            InlineValue(text: property.value.items.first ?? "", scale: scale) {
                edit(.set(key: property.key, value: .text($0)))
            }
        }
    }
}

/// A text value: shown rendered (links in the accent colour), edited as raw text after a click.
private struct InlineValue: View {
    let text: String
    let scale: CGFloat
    let commit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("Empty", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14 * scale))
                .foregroundStyle(Theme.textNormal)
                .focused($focused)
                .onSubmit(finish)
                .onKeyPress(.escape) { editing = false; return .handled }
                .onChange(of: focused) { _, f in if !f, editing { finish() } }
                .onAppear { DispatchQueue.main.async { focused = true } }
        } else {
            Group {
                if text.isEmpty {
                    Text("Empty").foregroundStyle(Theme.textFaint)
                } else {
                    Text(Self.display(text)).foregroundStyle(Theme.textNormal)
                }
            }
            .font(.system(size: 14 * scale))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { draft = text; editing = true }
        }
    }

    private func finish() {
        editing = false
        let new = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if new != text { commit(new) }
    }

    /// `[[Note|Alias]]` → "Alias" and `[[Note]]` → "Note" in the accent colour, like links in the reading view.
    static func display(_ s: String) -> AttributedString {
        var out = AttributedString()
        let ns = s as NSString
        let re = try! NSRegularExpression(pattern: #"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#)
        var at = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += AttributedString(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            let label = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 1))
            var link = AttributedString(label)
            link.foregroundColor = Theme.accent
            out += link
            at = NSMaxRange(m.range)
        }
        out += AttributedString(ns.substring(from: at))
        return out
    }
}

/// Pills with a remove button on hover, plus a field that adds an item on Return.
private struct ListEditor: View {
    let items: [String]
    let scale: CGFloat
    let tag: Bool
    let commit: ([String]) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Pill(text: item, scale: scale, tag: tag) {
                    var next = items
                    next.remove(at: i)
                    commit(next)
                }
            }
            TextField(items.isEmpty ? "Empty" : "Add…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * scale))
                .frame(width: 90 * scale)
                .focused($focused)
                .onSubmit(add)
                .onChange(of: focused) { _, f in if !f { add() } }
                // Backspace in the empty field removes the last item, as in Obsidian.
                .onKeyPress(.delete) {
                    guard draft.isEmpty, !items.isEmpty else { return .ignored }
                    commit(Array(items.dropLast()))
                    return .handled
                }
        }
    }

    private func add() {
        var item = draft.trimmingCharacters(in: .whitespaces)
        draft = ""
        if tag, item.hasPrefix("#") { item.removeFirst() }
        guard !item.isEmpty, !items.contains(item) else { return }
        commit(items + [item])
        DispatchQueue.main.async { focused = true }   // keep adding, as in Obsidian
    }
}

private struct Pill: View {
    let text: String
    let scale: CGFloat
    let tag: Bool
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 3) {
            Text(tag ? AttributedString(text) : InlineValue.display(text))
                .font(.system(size: 13 * scale))
                .foregroundStyle(tag ? Theme.accent : Theme.textNormal)
            // Always there (not only on hover), so items can always be removed.
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9 * scale, weight: .semibold))
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hover ? Theme.textNormal : Theme.textFaint)
            .help("Remove")
        }
        .padding(.leading, tag ? 8 : 9).padding(.trailing, 5).padding(.vertical, 2)
        .background(Capsule().fill(tag ? Theme.accent.opacity(0.12) : Theme.hover))
        .onHover { hover = $0 }
        .contextMenu { Button("Remove", action: remove) }
    }
}

/// "+ Add property": type a name, Return adds `name:` (empty value), Escape cancels.
private struct NewPropertyRow: View {
    let keyWidth: CGFloat
    let scale: CGFloat
    let taken: Set<String>
    let done: (String?) -> Void
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.alignleft").font(.system(size: 12 * scale)).foregroundStyle(Theme.textFaint)
                .frame(width: 15 * scale)
            TextField("Property name", text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 14 * scale))
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(.escape) { done(nil); return .handled }
                .onAppear { DispatchQueue.main.async { focused = true } }
            if taken.contains(key.trimmingCharacters(in: .whitespaces)) {
                Text("already exists").font(.system(size: 12 * scale)).foregroundStyle(.red)
            }
        }
        .padding(.leading, 6).padding(.vertical, 2)
        .frame(minHeight: 30 * scale)
    }

    private func commit() {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !taken.contains(k) else { return }
        done(k.isEmpty ? nil : k)
    }
}

/// Wraps its children onto as many lines as needed.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (sub, p) in zip(subviews, arrange(width: bounds.width, subviews).points) {
            sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}
