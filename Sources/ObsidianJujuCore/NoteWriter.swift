import Foundation

/// The one audited place that writes to a vault. It only ever overwrites an existing Markdown note that the
/// user has unlocked for editing (see `EditSession`), and only when the note on disk still matches what the
/// editor last loaded or saved — so a change made elsewhere (e.g. in Obsidian) is never silently clobbered.
/// Besides that it only creates new, empty notes the user asked for (`create`), copies of a note (`copyNote`) and
/// images the user pasted into a note (`saveAttachment`); none of them ever overwrites anything.
/// It never renames or moves files, and deletes only what the user chose to delete (`delete`, after a
/// confirmation in the app), the way Obsidian's "Deleted files" setting says. `scripts/check_readonly.sh` allows
/// writes only here and in `IndexCache.swift`.
public enum NoteWriter {
    public enum Outcome: Equatable, Sendable {
        case saved
        /// Disk already holds `text`; nothing written.
        case unchanged
        /// The note changed on disk since `baseline`; carries the current disk text. Nothing written.
        case conflict(String)
        case failed(String)
    }

    /// Reads a note as UTF-8 for editing (nil when missing or not UTF-8; such notes can't be edited).
    public static func load(root: URL, path: String) -> String? {
        guard isEditable(path), let url = VaultReader.containedURL(root, path),
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func isEditable(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "md"
    }

    public enum CreateOutcome: Equatable, Sendable {
        /// Vault-relative path of the new note.
        case created(String)
        case failed(String)
    }

    /// Characters Obsidian doesn't allow in note names (they break links), plus path separators.
    /// (A plain `Set<Character>`: `CharacterSet.contains` passed as a function was wrongly matched every character in release builds,
    /// rejecting every name.)
    static let forbiddenNameCharacters: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|", "#", "^", "[", "]"]

    /// Why `name` can't be a note name, or nil when it can. `name` is without ".md".
    public static func nameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Type a name for the note" }
        if trimmed.hasPrefix(".") { return "Names can’t start with a dot" }
        if trimmed.contains(where: { forbiddenNameCharacters.contains($0) }) {
            return "Names can’t contain any of  \\ / : * ? \" < > | # ^ [ ]"
        }
        if trimmed.utf8.count > 250 { return "That name is too long" }
        return nil
    }

    /// "Untitled", "Untitled 1", "Untitled 2", … — the first name not taken in `folder` (case-insensitive).
    public static func availableName(_ base: String, folder: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        func path(_ n: String) -> String { (folder.isEmpty ? "" : folder + "/") + n + ".md" }
        if !taken.contains(path(base).lowercased()) { return base }
        var i = 1
        while taken.contains(path("\(base) \(i)").lowercased()) { i += 1 }
        return "\(base) \(i)"
    }

    /// Creates an empty note `name`.md in `folder` (vault-relative, "" = root), which must already exist.
    /// Never overwrites: fails if any file with that name is already there.
    public static func create(root: URL, folder: String, name: String) -> CreateOutcome {
        var name = name.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        if let problem = nameProblem(name) { return .failed(problem) }
        let path = (folder.isEmpty ? "" : folder + "/") + name + ".md"
        guard let url = VaultReader.containedURL(root, path) else { return .failed("Outside the vault") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDir),
              isDir.boolValue else { return .failed("The folder “\(folder)” doesn’t exist") }
        // O_EXCL: fails instead of overwriting if the file appeared in the meantime (also case-insensitively on APFS).
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else {
            return .failed(errno == EEXIST ? "“\(name)” already exists" : String(cString: strerror(errno)))
        }
        close(fd)
        return .created(path)
    }

    /// Saves pasted image bytes as a new file `name` in `folder` (vault-relative). If that name is taken it uses
    /// "name 1.png", "name 2.png", … like Obsidian; it never overwrites. Creates `folder` if missing (Obsidian's
    /// attachment folder, e.g. "./attachments", appears on first use). Returns the new file's vault path.
    public static func saveAttachment(_ data: Data, root: URL, folder: String, name: String) -> CreateOutcome {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        if let problem = nameProblem(base) { return .failed(problem) }
        // The vault root itself is Obsidian's default attachment location.
        guard let dir = folder.isEmpty ? root : VaultReader.containedURL(root, folder) else { return .failed("Outside the vault") }
        if !FileManager.default.fileExists(atPath: dir.path) {
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
                return .failed(error.localizedDescription)
            }
        }
        return writeNew(data, root: root, folder: folder, base: base, ext: ext, firstSuffix: 0)
    }

    /// Copies note `path` byte for byte to "Name 1.md" (or the next free number) in the same folder, like
    /// Obsidian's "Make a copy". Returns the copy's vault path.
    public static func copyNote(root: URL, path: String) -> CreateOutcome {
        guard isEditable(path) else { return .failed("Only Markdown notes can be duplicated") }
        guard let url = VaultReader.containedURL(root, path), let data = try? Data(contentsOf: url) else {
            return .failed("The note no longer exists on disk")
        }
        let folder = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return writeNew(data, root: root, folder: folder, base: base, ext: (path as NSString).pathExtension, firstSuffix: 1)
    }

    /// Obsidian's "Deleted files" setting (`trashOption` in .obsidian/app.json).
    public enum TrashOption: String, Sendable {
        /// Move to the macOS Trash (Obsidian's default).
        case system
        /// Move to the vault's `.trash` folder.
        case local
        /// Delete permanently.
        case none
    }

    public enum DeleteOutcome: Equatable, Sendable {
        /// Moved to the macOS Trash; where it is now (when the system says).
        case trashed(URL?)
        /// Moved to the vault's `.trash` folder; its vault path there.
        case movedToVaultTrash(String)
        case deleted
        case failed(String)
    }

    /// Deletes the note, file or folder (with everything in it) at `path` as `option` says. Refuses the vault itself,
    /// `.obsidian` and anything outside the vault. A symlink is deleted itself, never what it points to.
    public static func delete(root: URL, path: String, option: TrashOption) -> DeleteOutcome {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(".."), !parts.contains(".") else { return .failed("Nothing to delete") }
        if parts.first == ".obsidian" { return .failed("Obsidian’s settings folder can’t be deleted here") }
        let parent = parts.dropLast().joined(separator: "/")
        guard let dir = parent.isEmpty ? root : VaultReader.containedURL(root, parent) else { return .failed("Outside the vault") }
        let url = dir.appendingPathComponent(name)
        let fm = FileManager.default
        guard (try? url.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil else {
            return .failed("“\(name)” no longer exists on disk")
        }
        do {
            switch option {
            case .system:
                var moved: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &moved)
                return .trashed(moved as URL?)
            case .local:
                let trash = root.appendingPathComponent(".trash")
                if parts.first == ".trash" {
                    try fm.removeItem(at: url)   // already in the vault's trash: delete for good
                    return .deleted
                }
                if !fm.fileExists(atPath: trash.path) { try fm.createDirectory(at: trash, withIntermediateDirectories: true) }
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                for n in 0..<1000 {
                    let candidate = n == 0 ? name
                        : isDir.boolValue || ext.isEmpty ? "\(name) \(n)" : "\(base) \(n).\(ext)"
                    let dest = trash.appendingPathComponent(candidate)
                    if fm.fileExists(atPath: dest.path) { continue }
                    try fm.moveItem(at: url, to: dest)
                    return .movedToVaultTrash(".trash/" + candidate)
                }
                return .failed("Too many items named “\(name)” in .trash")
            case .none:
                try fm.removeItem(at: url)
                return .deleted
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Writes `data` as a new file "base.ext", "base 1.ext", "base 2.ext", … (starting at `firstSuffix`, 0 = no
    /// number) — the first name that's free. O_EXCL, so an existing file is never overwritten.
    private static func writeNew(_ data: Data, root: URL, folder: String, base: String, ext: String, firstSuffix: Int) -> CreateOutcome {
        for n in firstSuffix..<(firstSuffix + 1000) {
            let file = (n == 0 ? base : "\(base) \(n)") + (ext.isEmpty ? "" : "." + ext)
            let path = (folder.isEmpty ? "" : folder + "/") + file
            guard let url = VaultReader.containedURL(root, path) else { return .failed("Outside the vault") }
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                return .failed(String(cString: strerror(errno)))
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                return .failed(error.localizedDescription)
            }
            return .created(path)
        }
        return .failed("Too many files named “\(base)”")
    }

    /// Replaces a `.base` file's YAML (the base editor) or a note's text (a property edited in a base's table cell)
    /// when the user has unlocked that base. Same safety as `save`: only if disk still matches `baseline`.
    public static func rewrite(_ text: String, root: URL, path: String, baseline: String) -> Outcome {
        guard (path as NSString).pathExtension.lowercased() == "base" || isEditable(path) else {
            return .failed("Only notes and bases can be changed")
        }
        return write(text, root: root, path: path, baseline: baseline)
    }

    public static func save(_ text: String, root: URL, path: String, baseline: String) -> Outcome {
        guard isEditable(path) else { return .failed("Only Markdown notes can be edited") }
        return write(text, root: root, path: path, baseline: baseline)
    }

    private static func write(_ text: String, root: URL, path: String, baseline: String) -> Outcome {
        guard let url = VaultReader.containedURL(root, path) else { return .failed("Outside the vault") }
        guard FileManager.default.fileExists(atPath: url.path),
              let disk = (try? Data(contentsOf: url)).flatMap({ String(data: $0, encoding: .utf8) }) else {
            return .failed(isEditable(path) ? "The note no longer exists on disk" : "The file no longer exists on disk")
        }
        guard disk == baseline else { return .conflict(disk) }
        if disk == text { return .unchanged }
        let data = Data(text.utf8)
        // Overwrite in place (rather than write-and-rename) so the file keeps its creation date, which
        // Obsidian and Bases use as `file.ctime`.
        do {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            try handle.synchronize()
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
