import Foundation

/// Listing and reading vault contents. There is deliberately no write API here — the only vault writer is
/// `NoteWriter` (per-note edit mode), and `scripts/check_readonly.sh` fails the build if write calls appear
/// anywhere outside `NoteWriter.swift` and `IndexCache.swift` (which writes only to ~/Library/Caches).
public enum VaultReader {
    public static func scan(_ root: URL) -> (files: [VaultFile], folders: [String]) {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath, isDirectory: true), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        var files: [VaultFile] = []
        var folders: [String] = []
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for case let url as URL in walker {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(prefix) else { continue }
            let rel = String(full.dropFirst(prefix.count))
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                folders.append(rel)
            } else {
                files.append(VaultFile(path: rel,
                                       mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                       size: values.fileSize ?? 0,
                                       ctime: values.creationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return (files, folders)
    }

    public static func url(_ root: URL, _ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    public static func readText(_ root: URL, _ path: String) -> String? {
        let url = url(root, path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Reads raw bytes for serving attachments, refusing anything that resolves outside the vault.
    public static func readData(_ root: URL, _ path: String) -> Data? {
        guard let url = containedURL(root, path) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    public static func containedURL(_ root: URL, _ path: String) -> URL? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let target = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return target.path.hasPrefix(prefix) ? target : nil
    }
}

/// Vaults the official Obsidian app knows about (from its obsidian.json).
public struct KnownVault: Hashable, Sendable, Identifiable {
    public let path: String
    public let lastOpened: Date?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public static func fromObsidianConfig() -> [KnownVault] {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return [] }
        return vaults.values.compactMap { v -> KnownVault? in
            guard let path = v["path"] as? String,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            let ts = (v["ts"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return KnownVault(path: path, lastOpened: ts)
        }
        .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
    }
}
