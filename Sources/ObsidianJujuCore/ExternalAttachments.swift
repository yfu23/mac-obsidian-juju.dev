import Foundation

/// Media files in user-chosen folders outside the vault (e.g. a Google Drive folder), referenced from notes
/// with ObsidianJuju's own syntax — a standard Markdown image whose address has a `juju:` prefix:
///
///     ![](<juju:Pasted image 20261003201825.png>)
///     ![|300](<juju:Pasted image 20261003201825.png>)
///
/// Obsidian shows that as a missing image (it isn't a link, so it never creates a note). A name resolves to the
/// vault first, then to the folders in their configured order. Folders are only read, never written.
public struct ExternalAttachments: Sendable {
    public struct Hit: Equatable, Sendable {
        public let folder: Int
        /// Path relative to that folder.
        public let path: String
    }

    public let folders: [URL]
    /// Lowercased file name → files with that name, folder order then shortest path first.
    private let byName: [String: [Hit]]

    public static let empty = ExternalAttachments(folders: [], byName: [:])

    private init(folders: [URL], byName: [String: [Hit]]) {
        self.folders = folders
        self.byName = byName
    }

    /// Lists media files (images, audio, video, JujuPix `.jjpx` photos) in each folder. Hidden files and packages are skipped.
    public static func scan(_ folders: [URL]) -> ExternalAttachments {
        var byName: [String: [Hit]] = [:]
        for (i, folder) in folders.enumerated() {
            for file in VaultReader.scan(folder).files where [.image, .audio, .video].contains(file.kind) || file.ext == "jjpx" {
                byName[file.name.lowercased(), default: []].append(Hit(folder: i, path: file.path))
            }
        }
        for key in byName.keys {
            byName[key]!.sort { ($0.folder, $0.path.count, $0.path) < ($1.folder, $1.path.count, $1.path) }
        }
        return ExternalAttachments(folders: folders, byName: byName)
    }

    /// `name` is a file name ("a.png") or a path inside a folder ("Sub/a.png"; a trailing match is enough).
    public func resolve(_ name: String) -> Hit? {
        let wanted = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !wanted.isEmpty else { return nil }
        let lower = wanted.lowercased()
        let hits = byName[(lower as NSString).lastPathComponent] ?? []
        guard lower.contains("/") else { return hits.first }
        return hits.first { h in
            let p = h.path.lowercased()
            return p == lower || p.hasSuffix("/" + lower)
        }
    }

    /// Every media file in the folders (folder order, then path), for the "Insert external image" picker.
    public var entries: [Hit] {
        byName.values.flatMap { $0 }.sorted { ($0.folder, $0.path) < ($1.folder, $1.path) }
    }

    /// The shortest name to write after `juju:` that resolves to `hit`: the file name when that's unambiguous,
    /// otherwise as many trailing path components as needed. Nil when an earlier folder has a file at the same
    /// path, so no name can reach this one.
    public func reference(for hit: Hit) -> String? {
        let parts = hit.path.split(separator: "/")
        for n in 1...max(parts.count, 1) {
            let candidate = parts.suffix(n).joined(separator: "/")
            if resolve(candidate) == hit { return candidate }
        }
        return nil
    }

    /// The `juju://ext/<folder>/<path>` URL the renderer loads a hit from.
    public static func url(for hit: Hit) -> String {
        (JujuRef.isEncrypted(hit.path) ? "juju://jjpx/\(hit.folder)/" : "juju://ext/\(hit.folder)/") + JujuRef.encodePath(hit.path)
    }
}

/// The `juju:` image address syntax.
public enum JujuRef {
    /// Markdown image destinations with a `juju:` address, as written (`<…>` form or plain).
    private static let regex = try! NSRegularExpression(
        pattern: #"!\[[^\]\n]*\]\(\s*(?:<juju:([^>\n]+)>|juju:([^\s)]+))"#, options: [.caseInsensitive])

    /// The decoded names referenced with `![…](<juju:name>)` in `text`.
    public static func names(in text: String) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let raw = ns.substring(with: r)
            let name = (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
    }

    /// A JujuPix encrypted photo, decrypted in memory by `JujuPixKeys` and served as `juju://jjpx/…`.
    public static func isEncrypted(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == "jjpx"
    }

    /// The `![](<juju:name>)` text for `name`.
    public static func markdown(_ name: String) -> String {
        "![](<juju:\(name)>)"
    }

    /// Turns what the user pasted (a file name copied in Finder, a full path, a `file://` URL, quoted text)
    /// into a file name or folder-relative path to look up.
    public static func cleanName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>"))
        if s.lowercased().hasPrefix("juju:") { s = String(s.dropFirst(5)) }
        if s.lowercased().hasPrefix("file://") {
            s = URL(string: s)?.path ?? (String(s.dropFirst(7)).removingPercentEncoding ?? s)
        }
        // A full path: keep only the file name (the folders are searched by name).
        if s.hasPrefix("/") || s.hasPrefix("~") { s = (s as NSString).lastPathComponent }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Key used in `RenderPayload.external` (the page looks names up the same way).
    public static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }
}
