import Foundation

/// Resolves link text to a vault file the way Obsidian does:
/// exact vault path → path relative to the linking note → "folder/name" suffix match → bare file name
/// (preferring the linking note's folder, then the shortest path). Matching is case-insensitive and
/// `.md` is implied when the link has no extension.
public struct LinkResolver: Sendable {
    private var byPath: [String: String] = [:]          // lowercased path → path
    private var byName: [String: [String]] = [:]        // lowercased file name (with ext) → paths

    public init(paths: some Sequence<String>) {
        for p in paths { insert(p) }
    }

    public mutating func insert(_ path: String) {
        byPath[path.lowercased()] = path
        byName[(path as NSString).lastPathComponent.lowercased(), default: []].append(path)
    }

    public mutating func remove(_ path: String) {
        byPath[path.lowercased()] = nil
        let key = (path as NSString).lastPathComponent.lowercased()
        byName[key]?.removeAll { $0 == path }
        if byName[key]?.isEmpty == true { byName[key] = nil }
    }

    public func contains(_ path: String) -> Bool { byPath[path.lowercased()] != nil }

    /// - Parameters:
    ///   - target: the link's path part (no `#subpath`, no `|alias`). Empty means "the linking note itself".
    ///   - source: vault-relative path of the note containing the link.
    public func resolve(_ target: String, from source: String) -> String? {
        var t = target.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return byPath[source.lowercased()] }
        if t.hasPrefix("/") { t.removeFirst() }
        let candidates = (t as NSString).pathExtension.isEmpty ? [t + ".md"] : [t + ".md", t]
        for c in candidates {
            if let hit = resolveExact(c, from: source) { return hit }
        }
        return nil
    }

    private func resolveExact(_ t: String, from source: String) -> String? {
        let lower = t.lowercased()
        if let hit = byPath[lower] { return hit }

        let sourceFolder = (source as NSString).deletingLastPathComponent
        if !sourceFolder.isEmpty || t.hasPrefix(".") {
            let joined = Self.normalize(sourceFolder.isEmpty ? t : sourceFolder + "/" + t)
            if let joined, let hit = byPath[joined.lowercased()] { return hit }
        }

        let name = (lower as NSString).lastPathComponent
        guard let sameName = byName[name], !sameName.isEmpty else { return nil }
        var matches = sameName
        if lower.contains("/") {
            let suffix = "/" + lower
            matches = sameName.filter { ("/" + $0.lowercased()).hasSuffix(suffix) }
        }
        if matches.count <= 1 { return matches.first }
        if let local = matches.first(where: { ($0 as NSString).deletingLastPathComponent == sourceFolder }) {
            return local
        }
        return matches.min { ($0.count, $0) < ($1.count, $1) }
    }

    /// Collapses `.` and `..` segments; nil if the path escapes the vault root.
    static func normalize(_ path: String) -> String? {
        var parts: [Substring] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." {
                if parts.isEmpty { return nil }
                parts.removeLast()
            } else {
                parts.append(seg)
            }
        }
        return parts.joined(separator: "/")
    }
}
