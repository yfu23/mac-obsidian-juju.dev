import Foundation

/// Everything the web renderer needs to display one file, pre-resolved so the page never has to
/// call back into Swift while rendering.
public struct RenderPayload: Encodable, Sendable {
    public struct Embed: Encodable, Sendable {
        public let path: String
        public let title: String
        public let kind: FileKind
        /// Markdown for note embeds (nil when the note or its `#subpath` couldn't be read).
        public let body: String?
        /// Evaluated base for `![[x.base]]` embeds.
        public var base: BaseResult?
    }

    public let path: String
    public let title: String
    public let kind: FileKind
    public let properties: [Property]
    public let body: String
    /// `linkKey(source, target)` → resolved vault path. Unresolved links are absent.
    public let resolve: [String: String]
    /// `embedKey(path, subpath)` → embedded content.
    public let embeds: [String: Embed]
    /// The evaluated base when this file is a `.base`.
    public var base: BaseResult?
    /// ```base code blocks: `baseBlockKey(source, content)` → evaluated base.
    public var bases: [String: BaseResult] = [:]
    /// `![](<juju:name>)` images: `JujuRef.key(name)` → URL (vault first, then outside attachment folders).
    /// Unfound names are absent.
    public var external: [String: String] = [:]

    public static func baseBlockKey(source: String, content: String) -> String {
        source + "\n" + content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func linkKey(source: String, target: String) -> String {
        source + "\n" + target.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func embedKey(path: String, subpath: String?) -> String {
        path + "#" + (subpath ?? "")
    }

    public func json() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension PropertyValue {
    // Encode as a plain string or array so the page can read it directly.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .list(let l): try c.encode(l)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let l = try? c.decode([String].self) { self = .list(l) } else { self = .text(try c.decode(String.self)) }
    }
}

struct RenderPayloadBuilder {
    let root: URL
    let resolver: LinkResolver
    var externals = ExternalAttachments.empty
    /// (yaml, thisPath, viewName) → result
    let evaluateBase: (String, String?, String?) -> BaseResult
    static let maxEmbedDepth = 4

    func build(path: String) -> RenderPayload {
        let kind = FileKind(ext: (path as NSString).pathExtension)
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if kind == .base {
            var payload = RenderPayload(path: path, title: title, kind: kind, properties: [], body: "", resolve: [:], embeds: [:])
            payload.base = evaluateBase(VaultReader.readText(root, path) ?? "", path, nil)
            return payload
        }
        guard kind == .markdown else {
            return RenderPayload(path: path, title: title, kind: kind, properties: [], body: "", resolve: [:], embeds: [:])
        }
        let text = VaultReader.readText(root, path) ?? ""
        let split = Frontmatter.split(text)
        var resolve: [String: String] = [:]
        var embeds: [String: RenderPayload.Embed] = [:]
        var bases: [String: BaseResult] = [:]
        var external: [String: String] = [:]
        collect(source: path, text: text, depth: 0, visiting: [path], resolve: &resolve, embeds: &embeds, bases: &bases,
                external: &external)
        var payload = RenderPayload(path: path, title: title, kind: kind, properties: split.properties,
                                    body: split.body, resolve: resolve, embeds: embeds)
        payload.bases = bases
        payload.external = external
        return payload
    }

    /// Contents of ```base fenced blocks.
    static func baseBlocks(in text: String) -> [String] {
        var out: [String] = []
        var current: [String]?
        var fence: (char: Character, count: Int)?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let f = fence {
                if trimmed.hasPrefix(String(repeating: f.char, count: f.count)), trimmed.allSatisfy({ $0 == f.char }) {
                    if let c = current { out.append(c.joined(separator: "\n")) }
                    fence = nil
                    current = nil
                } else {
                    current?.append(line)
                }
            } else if let f = NoteParser.fenceOpener(trimmed) {
                fence = f
                let info = trimmed.drop(while: { $0 == f.char }).trimmingCharacters(in: .whitespaces).lowercased()
                current = info == "base" ? [] : nil
            }
        }
        return out
    }

    private func collect(source: String, text: String, depth: Int, visiting: Set<String>,
                         resolve: inout [String: String], embeds: inout [String: RenderPayload.Embed],
                         bases: inout [String: BaseResult], external: inout [String: String]) {
        for name in JujuRef.names(in: text) {
            let key = JujuRef.key(name)
            guard external[key] == nil else { continue }
            if let inVault = resolver.resolve(name, from: source) {
                external[key] = (JujuRef.isEncrypted(inVault) ? "juju://jjpx/v/" : "juju://vault/") + JujuRef.encodePath(inVault)
            } else if let hit = externals.resolve(name) {
                external[key] = ExternalAttachments.url(for: hit)
            }
        }
        for block in Self.baseBlocks(in: text) {
            let key = RenderPayload.baseBlockKey(source: source, content: block)
            if bases[key] == nil { bases[key] = evaluateBase(block, source, nil) }
        }
        for link in NoteParser.parse(text).links {
            let key = RenderPayload.linkKey(source: source, target: link.target)
            let target = resolve[key] ?? resolver.resolve(link.target, from: source)
            guard let target else { continue }
            resolve[key] = target
            guard link.isEmbed else { continue }

            let ekey = RenderPayload.embedKey(path: target, subpath: link.subpath)
            guard embeds[ekey] == nil else { continue }
            let kind = FileKind(ext: (target as NSString).pathExtension)
            let name = ((target as NSString).lastPathComponent as NSString).deletingPathExtension
            let title = link.subpath.map { name + " > " + $0.replacingOccurrences(of: "#", with: " > ") } ?? name
            if kind == .base {
                // `this` is the embedding note; `#View name` picks the view.
                var e = RenderPayload.Embed(path: target, title: title, kind: kind, body: nil)
                e.base = evaluateBase(VaultReader.readText(root, target) ?? "", source, link.subpath)
                embeds[ekey] = e
                continue
            }
            guard kind == .markdown else {
                embeds[ekey] = .init(path: target, title: title, kind: kind, body: nil)
                continue
            }
            // Cycles and runaway depth render as a plain link-styled box instead of recursing.
            guard depth < Self.maxEmbedDepth, !visiting.contains(ekey) else {
                embeds[ekey] = .init(path: target, title: title, kind: kind, body: nil)
                continue
            }
            var body = Frontmatter.split(VaultReader.readText(root, target) ?? "").body
            if let sub = link.subpath {
                body = NoteSections.extract(body, subpath: sub) ?? ""
            }
            embeds[ekey] = .init(path: target, title: title, kind: kind, body: body.isEmpty ? nil : body)
            if !body.isEmpty {
                collect(source: target, text: body, depth: depth + 1, visiting: visiting.union([ekey]),
                        resolve: &resolve, embeds: &embeds, bases: &bases, external: &external)
            }
        }
    }
}
