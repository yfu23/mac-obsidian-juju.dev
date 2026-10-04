import Foundation

/// What the UI needs after each index refresh. Cheap to copy; heavy data stays in the actor.
public struct VaultSnapshot: Sendable {
    public let generation: Int
    /// All files, sorted by path.
    public let files: [VaultFile]
    public let folders: [String]
    /// Tag (first-seen spelling) → number of notes carrying it.
    public let tagCounts: [String: Int]
    /// Note path → aliases, for the quick switcher.
    public let aliases: [String: [String]]
    /// Paths whose content changed in this refresh (empty on the first load).
    public let changed: Set<String>

    public static let empty = VaultSnapshot(generation: 0, files: [], folders: [], tagCounts: [:], aliases: [:], changed: [])
}

public struct Backlink: Sendable, Identifiable, Hashable {
    public var id: String { source }
    public let source: String
    public let matches: [SearchMatch]
}

public struct OutgoingLink: Sendable, Identifiable, Hashable {
    public var id: String { (resolved ?? "?") + "|" + target }
    public let target: String
    public let resolved: String?
    public let isEmbed: Bool
}

/// The vault's file list, parsed note metadata, link resolver and an inverted search index.
/// Refreshes are incremental: only files whose mtime/size changed are re-read.
public actor VaultIndex {
    public nonisolated let root: URL

    private var generation = 0
    private var files: [String: VaultFile] = [:]
    private var folders: [String] = []
    private var records: [String: NoteRecord] = [:]
    private var resolver = LinkResolver(paths: [])

    private var noteIDs: [String: Int32] = [:]
    private var idPaths: [String?] = []
    private var freeIDs: [Int32] = []
    private var postings: [String: Set<Int32>] = [:]

    private var cached: [String: NoteRecord]?
    private var externals = ExternalAttachments.empty

    /// Media in folders outside the vault, for `![](<juju:name>)` images (scanned by the caller).
    public func setExternalAttachments(_ e: ExternalAttachments) { externals = e }

    public init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: Refresh

    /// Rescans the vault and updates the index for anything that changed.
    @discardableResult
    public func refresh() -> VaultSnapshot {
        let firstLoad = generation == 0
        if firstLoad { cached = IndexCache.load(for: root) }
        let scan = VaultReader.scan(root)
        let newFiles = Dictionary(scan.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        let removed = files.keys.filter { newFiles[$0] == nil }
        var toParse: [VaultFile] = []
        var changed = Set<String>()
        for (path, file) in newFiles {
            let old = files[path]
            if old == nil { resolver.insert(path) }
            guard file.isNote else {
                if let old, old.mtime != file.mtime || old.size != file.size { changed.insert(path) }
                continue
            }
            if let old, old.mtime == file.mtime, old.size == file.size, records[path] != nil { continue }
            if old != nil { changed.insert(path) }
            if let hit = cached?[path], hit.mtime == file.mtime, hit.size == file.size {
                install(hit)
            } else {
                toParse.append(file)
            }
        }
        for path in removed {
            resolver.remove(path)
            uninstall(path)
            changed.insert(path)
        }

        let parsed = Self.parseAll(toParse, root: root)
        parsed.forEach(install)

        let structureChanged = !removed.isEmpty || newFiles.count != files.count || folders != scan.folders
        files = newFiles
        folders = scan.folders
        cached = nil
        if firstLoad || !parsed.isEmpty || structureChanged {
            IndexCache.save(Array(records.values), for: root)
        }
        generation += 1
        return snapshot(changed: firstLoad ? [] : changed)
    }

    private func snapshot(changed: Set<String>) -> VaultSnapshot {
        var tagCounts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        var aliases: [String: [String]] = [:]
        for r in records.values {
            for t in r.tags {
                let key = t.lowercased()
                let display = spelling[key] ?? t
                spelling[key] = display
                tagCounts[display, default: 0] += 1
            }
            if !r.aliases.isEmpty { aliases[r.path] = r.aliases }
        }
        return VaultSnapshot(generation: generation, files: files.values.sorted { $0.path < $1.path },
                             folders: folders.sorted(), tagCounts: tagCounts, aliases: aliases, changed: changed)
    }

    private static func parseAll(_ files: [VaultFile], root: URL) -> [NoteRecord] {
        guard !files.isEmpty else { return [] }
        var out = [NoteRecord?](repeating: nil, count: files.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let f = files[i]
            let text = VaultReader.readText(root, f.path) ?? ""
            let note = NoteParser.parse(text)
            let tokens = Set(Tokenizer.tokens(text) + Tokenizer.tokens(f.basename))
            let record = NoteRecord(path: f.path, mtime: f.mtime, size: f.size, tags: note.tags,
                                    aliases: note.aliases, links: note.links, headings: note.headings,
                                    properties: note.properties, tokens: Array(tokens))
            lock.lock(); out[i] = record; lock.unlock()
        }
        return out.compactMap { $0 }
    }

    private func install(_ r: NoteRecord) {
        uninstall(r.path)
        let id: Int32
        if let free = freeIDs.popLast() {
            id = free
            idPaths[Int(id)] = r.path
        } else {
            id = Int32(idPaths.count)
            idPaths.append(r.path)
        }
        noteIDs[r.path] = id
        records[r.path] = r
        for t in r.tokens { postings[t, default: []].insert(id) }
    }

    private func uninstall(_ path: String) {
        guard let id = noteIDs.removeValue(forKey: path) else { return }
        if let old = records.removeValue(forKey: path) {
            for t in old.tokens {
                postings[t]?.remove(id)
                if postings[t]?.isEmpty == true { postings[t] = nil }
            }
        }
        idPaths[Int(id)] = nil
        freeIDs.append(id)
    }

    // MARK: Queries

    public func resolve(_ target: String, from source: String) -> String? {
        resolver.resolve(target, from: source)
    }

    public func headings(of path: String) -> [Heading] { records[path]?.headings ?? [] }

    public func search(_ raw: String, limit: Int = 300) -> SearchResults {
        let query = SearchQuery(raw)
        guard !query.include.isEmpty else { return SearchResults(query: query, hits: [], truncated: false) }

        // 1. Narrow candidates with the token index and metadata.
        var candidates: Set<String>?
        func intersect(_ s: Set<String>) { candidates = candidates.map { $0.intersection(s) } ?? s }
        for term in query.include {
            switch term {
            case .text(let s):
                let toks = Tokenizer.tokens(s)
                guard !toks.isEmpty else { continue } // punctuation-only: verified by substring below
                for tok in toks {
                    var ids = Set<Int32>()
                    for (key, set) in postings where key.contains(tok) { ids.formUnion(set) }
                    intersect(Set(ids.compactMap { idPaths[Int($0)] }))
                }
            case .tag(let t):
                intersect(Set(records.values.filter { r in
                    r.tags.contains { $0.lowercased() == t || $0.lowercased().hasPrefix(t + "/") }
                }.map(\.path)))
            case .path(let p):
                intersect(Set(files.keys.filter { $0.lowercased().contains(p) }))
            case .file(let f):
                intersect(Set(files.keys.filter { ($0 as NSString).lastPathComponent.lowercased().contains(f) }))
            }
        }
        var pool = candidates ?? Set(records.keys)
        // Only notes have searchable content; path:/file: alone may also match attachments.
        let contentTerms = query.include.contains { if case .text = $0 { return true } else { return false } }
            || query.exclude.contains { if case .text = $0 { return true } else { return false } }
        if contentTerms { pool = pool.filter { records[$0] != nil } }

        // 2. Verify against file contents and build snippets, in file-name order (Obsidian's default).
        let ordered = pool.sorted {
            let a = ($0 as NSString).lastPathComponent.lowercased(), b = ($1 as NSString).lastPathComponent.lowercased()
            return a == b ? $0 < $1 : a < b
        }
        var hits: [SearchHit] = []
        let highlight = query.highlightTerms
        for path in ordered {
            if Task.isCancelled { break }
            guard passesExclusions(path, query) else { continue }
            if !contentTerms && query.include.allSatisfy({ if case .tag = $0 { return false } else { return true } }) {
                hits.append(SearchHit(path: path, matches: []))
            } else {
                guard let text = VaultReader.readText(root, path) else { continue }
                let lower = text.lowercased()
                let name = path.lowercased()
                let ok = query.include.allSatisfy { term in
                    if case .text(let s) = term { return lower.contains(s) || name.contains(s) }
                    return true
                } && !query.exclude.contains { term in
                    if case .text(let s) = term { return lower.contains(s) }
                    return false
                }
                guard ok else { continue }
                hits.append(SearchHit(path: path, matches: Snippets.matches(in: text, terms: highlight, maxLines: 8)))
            }
            if hits.count >= limit { return SearchResults(query: query, hits: hits, truncated: true) }
        }
        return SearchResults(query: query, hits: hits, truncated: false)
    }

    private func passesExclusions(_ path: String, _ q: SearchQuery) -> Bool {
        for term in q.exclude {
            switch term {
            case .text: continue // checked against content
            case .tag(let t):
                if records[path]?.tags.contains(where: { $0.lowercased() == t || $0.lowercased().hasPrefix(t + "/") }) == true { return false }
            case .path(let p): if path.lowercased().contains(p) { return false }
            case .file(let f): if (path as NSString).lastPathComponent.lowercased().contains(f) { return false }
            }
        }
        return true
    }

    public func backlinks(to target: String) -> [Backlink] {
        var out: [Backlink] = []
        for r in records.values where r.path != target {
            let lines = Set(r.links.filter { resolver.resolve($0.target, from: r.path) == target }.map(\.line))
            guard !lines.isEmpty else { continue }
            let text = VaultReader.readText(root, r.path) ?? ""
            let all = text.components(separatedBy: "\n")
            let matches = lines.sorted().prefix(6).compactMap { n -> SearchMatch? in
                guard all.indices.contains(n) else { return nil }
                let line = all[n].trimmingCharacters(in: .whitespaces)
                return SearchMatch(line: n, segments: [.init(text: String(line.prefix(240)), highlighted: false)])
            }
            out.append(Backlink(source: r.path, matches: matches))
        }
        return out.sorted { $0.source.lowercased() < $1.source.lowercased() }
    }

    /// Obsidian's "Delete attachments when deleting files": the vault files `source` links to or embeds that aren't
    /// notes, canvases or bases, and that no other note links to. Sorted by path.
    public func unlinkedAttachments(of source: String) -> [String] {
        guard let r = records[source] else { return [] }
        let notLikeAttachments: Set<String> = ["md", "canvas", "base"]
        var candidates = Set(r.links.compactMap { resolver.resolve($0.target, from: source) }.filter {
            $0 != source && files[$0] != nil && !notLikeAttachments.contains(($0 as NSString).pathExtension.lowercased())
        })
        for other in records.values where other.path != source && !candidates.isEmpty {
            for link in other.links {
                if let t = resolver.resolve(link.target, from: other.path) { candidates.remove(t) }
            }
        }
        return candidates.sorted { $0.lowercased() < $1.lowercased() }
    }

    public func outgoing(from source: String) -> [OutgoingLink] {
        guard let r = records[source] else { return [] }
        var seen = Set<String>()
        return r.links.compactMap { link in
            guard !link.target.isEmpty else { return nil }
            let resolved = resolver.resolve(link.target, from: source)
            guard seen.insert(resolved ?? "?" + link.target.lowercased()).inserted else { return nil }
            return OutgoingLink(target: link.target, resolved: resolved, isEmbed: link.isEmbed)
        }
    }

    // MARK: Rendering

    public func renderPayload(for path: String) -> RenderPayload {
        let env = baseEnvironment()
        var builder = RenderPayloadBuilder(root: root, resolver: resolver) { yaml, this, view in
            BaseEngine.evaluate(yaml: yaml, thisPath: this, viewName: view, env: env)
        }
        builder.externals = externals
        return builder.build(path: path)
    }

    // MARK: Bases

    /// Evaluates a base (the YAML of a `.base` file or ```base block). `thisPath` is the file `this` refers to.
    public func evaluateBase(yaml: String, thisPath: String?, viewName: String? = nil) -> BaseResult {
        BaseEngine.evaluate(yaml: yaml, thisPath: thisPath, viewName: viewName, env: baseEnvironment())
    }

    private func baseEnvironment() -> BaseEnvironment {
        BaseEnvironment(files: files, records: records, resolver: resolver, now: Date())
    }
}
