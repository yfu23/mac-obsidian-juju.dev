import Foundation

/// Per-note index data, persisted between launches so a large vault doesn't need re-parsing.
public struct NoteRecord: Codable, Sendable {
    public let path: String
    public let mtime: Double
    public let size: Int
    public let tags: [String]
    public let aliases: [String]
    public let links: [LinkRef]
    public let headings: [Heading]
    /// Frontmatter properties (for Bases).
    public let properties: [Property]
    /// Unique search tokens from the content and file name.
    public let tokens: [String]
}

/// Persists the index under ~/Library/Caches/ObsidianJuju — never inside the vault.
/// This file is the only place in the app allowed to write to disk (see scripts/check_readonly.sh).
enum IndexCache {
    static let version = 2

    private struct Payload: Codable {
        let version: Int
        let root: String
        let records: [NoteRecord]
    }

    static func cacheURL(for root: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // FNV-1a hash keeps the file name stable and short for any vault path.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in root.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return caches.appendingPathComponent("ObsidianJuju/index-\(String(hash, radix: 16)).json")
    }

    static func load(for root: URL) -> [String: NoteRecord] {
        guard let data = try? Data(contentsOf: cacheURL(for: root)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version, payload.root == root.standardizedFileURL.path else { return [:] }
        return Dictionary(payload.records.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func save(_ records: [NoteRecord], for root: URL) {
        let url = cacheURL(for: root)
        guard url.path.hasPrefix(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path)
        else { return }
        let payload = Payload(version: version, root: root.standardizedFileURL.path, records: records)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
