import Foundation

/// Where new notes go, from Obsidian's own setting (Settings → Files and links → "Default location for new
/// notes", stored in `.obsidian/app.json` as `newFileLocation` / `newFileFolderPath`).
public enum NewNoteLocation {
    private static func config(_ root: URL) -> [String: Any]? {
        let url = root.appendingPathComponent(".obsidian/app.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    /// Obsidian's "Default location for new attachments" (`attachmentFolderPath`): "/" or unset = vault root,
    /// "./" = the note's folder, "./sub" = a subfolder of the note's folder, otherwise that vault folder.
    public static func attachmentFolder(vault root: URL, notePath: String) -> String {
        let setting = (config(root)?["attachmentFolderPath"] as? String ?? "/").trimmingCharacters(in: .whitespaces)
        let noteFolder = (notePath as NSString).deletingLastPathComponent
        func clean(_ s: String) -> String { s.split(separator: "/").filter { $0 != "." && !$0.isEmpty }.joined(separator: "/") }
        if setting.isEmpty || setting == "/" { return "" }
        if setting == "." || setting.hasPrefix("./") {
            let sub = clean(String(setting.dropFirst(1)))
            return [noteFolder, sub].filter { !$0.isEmpty }.joined(separator: "/")
        }
        return clean(setting)
    }

    /// Obsidian's "Use [[Wikilinks]]" setting is off (`useMarkdownLinks`).
    /// Obsidian's "Delete attachments when deleting files" (`deleteUnlinkedAttachments`): "ask" (default),
    /// "always" or "never".
    public enum DeleteAttachments: String, Sendable {
        case ask, always, never

        public var label: String {
            switch self {
            case .ask: return "Ask each time"
            case .always: return "Always"
            case .never: return "Never"
            }
        }
    }

    public static func deleteAttachments(vault root: URL) -> DeleteAttachments {
        (config(root)?["deleteUnlinkedAttachments"] as? String).flatMap(DeleteAttachments.init) ?? .ask
    }

    /// Obsidian's "Deleted files" setting; the macOS Trash unless the vault says otherwise.
    public static func trashOption(vault root: URL) -> NoteWriter.TrashOption {
        (config(root)?["trashOption"] as? String).flatMap(NoteWriter.TrashOption.init) ?? .system
    }

    public static func usesMarkdownLinks(vault root: URL) -> Bool {
        config(root)?["useMarkdownLinks"] as? Bool ?? false
    }

    /// "Pasted image 20261003201825.png", Obsidian's name for pasted images.
    public static func pastedImageName(date: Date = Date(), ext: String = "png") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return "Pasted image \(f.string(from: date)).\(ext)"
    }

    /// The text written into the note for a newly saved attachment at vault path `path`.
    /// Wikilinks use the bare file name unless another vault file has the same name (Obsidian's "shortest path").
    public static func embed(path: String, markdown: Bool, nameIsUnique: Bool) -> String {
        let name = (path as NSString).lastPathComponent
        guard markdown else { return "![[\(nameIsUnique ? name : path)]]" }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()")
        return "![](" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path) + ")"
    }

    /// Vault-relative folder ("" = vault root) for a new note, given the note currently open (if any).
    public static func folder(vault root: URL, currentPath: String?, existingFolders: Set<String>) -> String {
        let json = config(root)
        switch json?["newFileLocation"] as? String {
        case "current":
            return currentPath.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        case "folder":
            let folder = (json?["newFileFolderPath"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return folder.isEmpty || existingFolders.contains(folder) ? folder : ""
        default:
            return ""
        }
    }
}
