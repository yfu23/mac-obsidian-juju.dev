import Foundation

/// A file inside a vault. `path` is vault-relative, using "/" separators (e.g. "Projects/Plan.md").
public struct VaultFile: Codable, Hashable, Sendable {
    public let path: String
    public let mtime: Double
    public let size: Int
    /// Creation time (seconds since 1970); 0 when unknown.
    public var ctime: Double = 0

    public init(path: String, mtime: Double, size: Int, ctime: Double = 0) {
        self.path = path
        self.mtime = mtime
        self.size = size
        self.ctime = ctime
    }

    /// File name with extension ("Plan.md").
    public var name: String { (path as NSString).lastPathComponent }
    /// Lowercased extension without the dot ("md").
    public var ext: String { (path as NSString).pathExtension.lowercased() }
    /// File name without extension ("Plan"). This is what Obsidian displays for notes.
    public var basename: String { (name as NSString).deletingPathExtension }
    /// Vault-relative parent folder ("" for the vault root).
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var isNote: Bool { ext == "md" }
    public var kind: FileKind { FileKind(ext: ext) }
}

public enum FileKind: String, Codable, Sendable {
    case markdown, image, audio, video, pdf, canvas, base, other

    public init(ext: String) {
        switch ext.lowercased() {
        case "md": self = .markdown
        case "png", "jpg", "jpeg", "gif", "bmp", "svg", "webp", "avif", "heic", "tif", "tiff": self = .image
        case "mp3", "wav", "m4a", "ogg", "flac", "3gp", "webm-audio": self = .audio
        case "mp4", "webm", "mov", "ogv", "mkv": self = .video
        case "pdf": self = .pdf
        case "canvas": self = .canvas
        case "base": self = .base
        default: self = .other
        }
    }
}

/// One `[[wikilink]]`, `![[embed]]`, `[text](link.md)` or `![](image.png)` found in a note.
public struct LinkRef: Codable, Hashable, Sendable {
    public enum Style: String, Codable, Sendable { case wiki, markdown }

    /// The path part as written, without `#subpath` or `|alias` (may be empty for same-note links).
    public let target: String
    /// Heading path ("Heading" or "H1#H2") or block reference ("^abc123"), without the leading `#`.
    public let subpath: String?
    public let alias: String?
    public let isEmbed: Bool
    public let style: Style
    /// 0-based line number in the full file text (frontmatter included).
    public let line: Int

    public init(target: String, subpath: String?, alias: String?, isEmbed: Bool, style: Style, line: Int) {
        self.target = target
        self.subpath = subpath
        self.alias = alias
        self.isEmbed = isEmbed
        self.style = style
        self.line = line
    }
}

public struct Heading: Codable, Hashable, Sendable {
    public let level: Int
    public let text: String
    public let line: Int

    public init(level: Int, text: String, line: Int) {
        self.level = level
        self.text = text
        self.line = line
    }
}

/// A frontmatter property value. Obsidian's richer types (number, checkbox, date) are left as text;
/// the renderer infers them for display.
public enum PropertyValue: Codable, Hashable, Sendable {
    case text(String)
    case list([String])

    public var items: [String] {
        switch self {
        case .text(let s): return s.isEmpty ? [] : [s]
        case .list(let l): return l
        }
    }
}

public struct Property: Codable, Hashable, Sendable {
    public let key: String
    public let value: PropertyValue

    public init(key: String, value: PropertyValue) {
        self.key = key
        self.value = value
    }
}
