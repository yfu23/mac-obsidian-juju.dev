import Foundation
@testable import ObsidianJujuCore

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got != want { failures += 1; print("FAIL \(name): got \(got), want \(want)") }
}

// MARK: Frontmatter

let fmNote = """
---
title: "Hello: world"
tags: [project, "area/work"]
aliases:
  - Hi
  - Hey
done: true
summary: |
  line one
  line two
---
# Body
"""
let fm = Frontmatter.split(fmNote)
check("fm count", fm.properties.map(\.key), ["title", "tags", "aliases", "done", "summary"])
check("fm quoted", fm.properties[0].value, .text("Hello: world"))
check("fm flow list", fm.properties[1].value, .list(["project", "area/work"]))
check("fm block list", fm.properties[2].value, .list(["Hi", "Hey"]))
check("fm literal", fm.properties[4].value, .text("line one\nline two"))
check("fm body", fm.body, "# Body")
check("fm lines", fm.lineCount, 11)
check("no fm", Frontmatter.split("# x\n---\n").properties.count, 0)
check("unclosed fm", Frontmatter.split("---\na: b\n").body, "---\na: b\n")

// MARK: Parser

let note = NoteParser.parse("""
---
tags: alpha, beta
aliases: Other Name
related: "[[Linked From Props]]"
---
# Title #inheading
Text with #tag1 and #nested/tag and #2024 and a#notag and `#code` %%#hidden%%.
See [[Note A]], [[Folder/Note B#Section|alias]], ![[image.png|300]] and [[#Local]].
Markdown [link](Other%20Note.md#Part) and ![img](pics/a.png) and [web](https://x.com/#frag).
```
#notatag [[NotALink]]
```
%%
[[CommentLink]] #commenttag
%%
$$
#math
$$
## Second ##
""")
check("tags", note.tags, ["alpha", "beta", "inheading", "tag1", "nested/tag"])
check("aliases", note.aliases, ["Other Name"])
check("links targets", note.links.map(\.target),
      ["Linked From Props", "Note A", "Folder/Note B", "image.png", "", "Other Note.md", "pics/a.png"])
check("link subpath", note.links[2].subpath, "Section")
check("link alias", note.links[2].alias, "alias")
check("embed", note.links[3].isEmbed, true)
check("md subpath", note.links[5].subpath, "Part")
check("md line", note.links[5].line, 8)
check("headings", note.headings.map(\.text), ["Title #inheading", "Second"])
check("heading levels", note.headings.map(\.level), [1, 2])
check("table escape", NoteParser.parseWikiInner(#"Note\|Alias"#).target, "Note")
check("table escape alias", NoteParser.parseWikiInner(#"Note\|Alias"#).alias, "Alias")
check("block ref", NoteParser.parseWikiInner("Note#^abc").subpath, "^abc")

// MARK: Resolver

let resolver = LinkResolver(paths: [
    "Home.md", "Projects/Plan.md", "Archive/Plan.md", "Archive/Old/Plan.md",
    "Daily/2024-01-01.md", "attachments/image.png", "Notes/v1.2.md", "Notes/Readme.md",
])
check("exact", resolver.resolve("Projects/Plan", from: "Home.md"), "Projects/Plan.md")
check("case", resolver.resolve("home", from: "Projects/Plan.md"), "Home.md")
check("same folder wins", resolver.resolve("Plan", from: "Archive/x.md"), "Archive/Plan.md")
check("shortest wins", resolver.resolve("Plan", from: "Home.md"), "Archive/Plan.md")
check("suffix", resolver.resolve("Old/Plan", from: "Home.md"), "Archive/Old/Plan.md")
check("attachment", resolver.resolve("image.png", from: "Home.md"), "attachments/image.png")
check("dotted name", resolver.resolve("v1.2", from: "Home.md"), "Notes/v1.2.md")
check("relative", resolver.resolve("../Home.md", from: "Projects/Plan.md"), "Home.md")
check("relative sibling", resolver.resolve("./Readme.md", from: "Notes/v1.2.md"), "Notes/Readme.md")
check("missing", resolver.resolve("Nope", from: "Home.md"), nil)
check("self", resolver.resolve("", from: "Home.md"), "Home.md")
check("escape root", LinkResolver.normalize("../../x"), nil)

// MARK: Sections

let doc = """
# A
intro
## B
b text
```
# not a heading
```
### C
c text
## D
d text ^blk1

- item one ^li
- item two

| t |
|---|
^tbl
"""
check("section B", NoteSections.extract(doc, subpath: "B"), "## B\nb text\n```\n# not a heading\n```\n### C\nc text")
check("section nested", NoteSections.extract(doc, subpath: "A#C"), "### C\nc text")
check("section missing", NoteSections.extract(doc, subpath: "Z"), nil)
check("block para", NoteSections.extract(doc, subpath: "^blk1"), "d text")
check("block list", NoteSections.extract(doc, subpath: "^li"), "- item one")
check("block standalone", NoteSections.extract(doc, subpath: "^tbl"), "| t |\n|---|")

// MARK: Tokenizer, fuzzy, query

check("tokens", Tokenizer.tokens("Hello, Wörld foo_bar 42"), ["hello", "wörld", "foo_bar", "42"])
check("cjk tokens", Tokenizer.tokens("中文abc"), ["中", "文", "abc"])
check("fuzzy match", Fuzzy.score("pln", in: "Plan") != nil, true)
check("fuzzy miss", Fuzzy.score("xyz", in: "Plan"), nil)
check("fuzzy prefers contiguous", Fuzzy.score("plan", in: "Plan")! < Fuzzy.score("plan", in: "P-l-a-n")!, true)
let q = SearchQuery(#"foo "exact phrase" -bar tag:#work path:"Projects/A" file:plan"#)
check("query include", q.include, [.text("foo"), .text("exact phrase"), .tag("work"), .path("projects/a"), .file("plan")])
check("query exclude", q.exclude, [.text("bar")])
let snip = Snippets.mark("Some Foo text foo", terms: ["foo"])!
check("snippet", snip.filter(\.highlighted).map(\.text), ["Foo", "foo"])


// MARK: Bases — YAML

let baseYAML = """
filters:
  and:
    - file.hasTag("bike")
    - 'file.ext == "md"'
formulas:
  total: 'front + rear'
  label: "if(front > 60, \\"high\\", \\"low\\")"
properties:
  formula.total:
    displayName: Total PSI
views:
  - type: table
    name: Table
    order:
      - file.name
      - front
      - formula.total
    sort:
      - property: front
        direction: DESC
    summaries:
      front: Average
  - type: cards
    name: By label
    groupBy:
      property: formula.label
      direction: ASC
    limit: 10
"""
let y = YAMLLite.parse(baseYAML)
check("yaml views count", y["views"]?.items.count, 2)
check("yaml view name", y["views"]?.items[1]["name"]?.string, "By label")
check("yaml nested filter", y["filters"]?["and"]?.items.count, 2)
check("yaml quoted statement", y["filters"]?["and"]?.items[1].string, #"file.ext == "md""#)
check("yaml formula escapes", y["formulas"]?["label"]?.string, #"if(front > 60, "high", "low")"#)
check("yaml sort", y["views"]?.items[0]["sort"]?.items[0]["direction"]?.string, "DESC")
check("yaml flow", YAMLLite.parse("a: [x, 'y z', {k: v}]")["a"]?.items.count, 3)
check("yaml seq at key indent", YAMLLite.parse("order:\n- a\n- b\nnext: 1")["order"]?.items.count, 2)
check("yaml block scalar", YAMLLite.parse("f: |\n  line1\n  line2\nz: 1")["f"]?.string, "line1\nline2")

// MARK: Bases — expressions

let ctxFile = VaultFile(path: "Bikes/Road.md", mtime: 0, size: 10)
let ctxRecord = NoteRecord(path: "Bikes/Road.md", mtime: 0, size: 10, tags: ["bike", "gear/road"], aliases: [],
    links: [LinkRef(target: "Home", subpath: nil, alias: nil, isEmbed: false, style: .wiki, line: 3)], headings: [],
    properties: [Property(key: "front", value: .text("90")), Property(key: "rear", value: .text("85")),
                 Property(key: "bought", value: .text("2024-05-01")), Property(key: "tags", value: .list(["bike"])),
                 Property(key: "front tire pressure (PSI)", value: .text("50~60"))],
    tokens: [])
let env = BaseEnvironment(files: ["Bikes/Road.md": ctxFile, "Home.md": VaultFile(path: "Home.md", mtime: 0, size: 1)],
                          records: ["Bikes/Road.md": ctxRecord], resolver: LinkResolver(paths: ["Bikes/Road.md", "Home.md"]),
                          now: BaseDates.parse("2026-01-01")!.0)
func ev(_ s: String) -> String {
    let e = BaseEvaluator(env: env, formulas: ["double": .success(try! BaseParser.parse("front * 2"))],
                          row: BaseFileInfo(file: ctxFile, record: ctxRecord), this: nil)
    do { return try e.eval(BaseParser.parse(s)).text } catch { return "ERR \(error)" }
}
check("expr arithmetic", ev("1 + 2 * 3"), "7")
check("expr parens", ev("(1 + 2) * 3"), "9")
check("expr property", ev("front"), "90")
check("expr note ns", ev("note.rear"), "85")
check("expr spaced key", ev(#"note["front tire pressure (PSI)"]"#), "50~60")
check("expr compare", ev("front > rear"), "true")
check("expr and/or", ev("front > 100 || rear < 90 && true"), "true")
check("expr not", ev("!file.hasTag(\"car\")"), "true")
check("expr hasTag", ev(#"file.hasTag("bike")"#), "true")
check("expr hasTag nested", ev(#"file.hasTag("gear")"#), "true")
check("expr hasTag hash", ev(##"file.hasTag("#bike")"##), "true")
check("expr inFolder", ev(#"file.inFolder("Bikes")"#), "true")
check("expr inFolder no", ev(#"file.inFolder("Cars")"#), "false")
check("expr hasLink", ev(#"file.hasLink("Home")"#), "true")
check("expr hasProperty", ev(#"file.hasProperty("rear")"#), "true")
check("expr file fields", ev("file.name + \"|\" + file.basename + \"|\" + file.folder + \"|\" + file.ext"), "Road.md|Road|Bikes|md")
check("expr formula", ev("formula.double"), "180")
check("expr if", ev(#"if(front > 60, "high", "low")"#), "high")
check("expr ternary", ev(#"front > 100 ? "a" : "b""#), "b")
check("expr string methods", ev(#""Hello World".lower().contains("world")"#), "true")
check("expr string length", ev(#""abc".length"#), "3")
check("expr toFixed", ev("(10 / 3).toFixed(2)"), "3.33")
check("expr round", ev("(10 / 3).round(1)"), "3.3")
check("expr date compare", ev(#"bought < date("2025-01-01")"#), "true")
check("expr date add", ev(#"(date("2024-01-31") + "1d").format("YYYY-MM-DD")"#), "2024-02-01")
check("expr date month", ev(#"date("2024-05-01").month"#), "5")
check("expr date format", ev(#"bought.format("DD/MM/YYYY")"#), "01/05/2024")
check("expr today", ev("today().year"), "2026")
check("expr list", ev("[1, 2, 3].map(value * 2).join(\",\")"), "2,4,6")
check("expr filter", ev("[1, 2, 3, 4].filter(value > 2).length"), "2")
check("expr reduce", ev("[1, 2, 3].reduce(acc + value, 0)"), "6")
check("expr list contains", ev(#"note.tags.contains("bike")"#), "true")
check("expr file.tags", ev("file.tags.join(\" \")"), "#bike #gear/road")
check("expr string concat", ev(#""PSI: " + front"#), "PSI: 90")
check("expr null prop", ev("missing.isEmpty()"), "true")
check("expr unknown fn", ev("nope()").hasPrefix("ERR"), true)
check("expr syntax error", ev("front >").hasPrefix("ERR"), true)
check("duration parse", BaseDuration.parse("1M 2d")?.months, 1)
check("moment format", BaseDates.format(BaseDates.parse("2024-03-05 14:07")!.0, pattern: "ddd, MMM D YYYY h:mm A"), "Tue, Mar 5 2024 2:07 PM")

// MARK: Index over a temp vault

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("juju-check-\(UUID().uuidString)")
func put(_ path: String, _ text: String) {
    let url = tmp.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}
put("Home.md", "Welcome to the vault. See [[Projects/Plan]] and #home.\n![[Plan#Goals]]")
put("Projects/Plan.md", "---\ntags: [work]\n---\n# Goals\nShip the viewer.\n## Sub\nnested\n# Later\nmore [[Home]]")
put("Journal/中文.md", "今天天气很好 searchable")
put(".obsidian/app.json", "{}")
put("pic.png", "not really a png")

let index = VaultIndex(root: tmp)
let semaphore = DispatchSemaphore(value: 0)
Task {
    let snap = await index.refresh()
    check("files", snap.files.map(\.path), ["Home.md", "Journal/中文.md", "Projects/Plan.md", "pic.png"])
    check("tag counts", snap.tagCounts, ["home": 1, "work": 1])

    let r1 = await index.search("viewer")
    check("search word", r1.hits.map(\.path), ["Projects/Plan.md"])
    check("search snippet", r1.hits.first?.matches.first?.segments.contains { $0.highlighted && $0.text == "viewer" }, true)
    check("search substring", await index.search("iewe").hits.count, 1)
    check("search and", await index.search("ship nested").hits.count, 1)
    check("search and miss", await index.search("ship welcome").hits.count, 0)
    check("search exclude", await index.search("vault -welcome").hits.count, 0)
    check("search phrase", await index.search(#""the vault""#).hits.map(\.path), ["Home.md"])
    check("search tag", await index.search("tag:work").hits.map(\.path), ["Projects/Plan.md"])
    check("search path", await index.search("path:projects").hits.map(\.path), ["Projects/Plan.md"])
    check("search file", await index.search("file:pic").hits.map(\.path), ["pic.png"])
    check("search cjk", await index.search("天气").hits.map(\.path), ["Journal/中文.md"])
    check("search name", await index.search("plan").hits.map(\.path).contains("Projects/Plan.md"), true)

    check("backlinks", await index.backlinks(to: "Projects/Plan.md").map(\.source), ["Home.md"])
    check("outgoing", await index.outgoing(from: "Home.md").map(\.resolved), ["Projects/Plan.md"])

    let payload = await index.renderPayload(for: "Home.md")
    check("payload resolve", payload.resolve[RenderPayload.linkKey(source: "Home.md", target: "projects/plan")], "Projects/Plan.md")
    let embed = payload.embeds[RenderPayload.embedKey(path: "Projects/Plan.md", subpath: "Goals")]
    check("payload embed section", embed?.body, "# Goals\nShip the viewer.\n## Sub\nnested")
    check("payload embed nested resolve", payload.resolve.isEmpty, false)
    check("payload json", payload.json().contains("\"kind\":\"markdown\""), true)

    let planPayload = await index.renderPayload(for: "Projects/Plan.md")
    check("payload props", planPayload.json().contains(#""value":["work"]"#), true)

    // Bases over the temp vault: add bike notes.
    put("Bikes/Road.md", "---\nfront: 90\nrear: 85\nbought: 2024-05-01\n---\n#bike road")
    put("Bikes/Gravel.md", "---\nfront: 40\nrear: 45\n---\n#bike gravel [[Home]]")
    put("Bikes/Old.md", "---\nfront: 70\n---\n#bike")
    await index.refresh()
    let base = await index.evaluateBase(yaml: baseYAML, thisPath: nil)
    check("base views", base.views.map(\.name), ["Table", "By label"])
    let table = base.views[0]
    check("base columns", table.columns.map(\.name), ["file name", "front", "Total PSI"])
    check("base rows sorted desc", table.groups[0].rows.map { $0.cells[0].text }, ["Road", "Old", "Gravel"])
    check("base name is link", table.groups[0].rows[0].cells[0].path, "Bikes/Road.md")
    check("base formula cell", table.groups[0].rows[0].cells[2].text, "175")
    check("base formula null", table.groups[0].rows[1].cells[2].t, "null")
    check("base summary", table.summaries, ["", "66.667", ""])
    check("base total", table.total, 3)
    // View-only header sort (read-only .base tabs): replaces the primary sort, applies before `limit`.
    let asc = await index.evaluateBase(yaml: baseYAML, thisPath: nil,
                                       sortOverrides: ["Table": BaseSortKey(property: "front", ascending: true)])
    check("view sort asc", asc.views[0].groups[0].rows.map { $0.cells[0].text }, ["Gravel", "Old", "Road"])
    check("view sort echoed", asc.views[0].viewSort, BaseSortKey(property: "note.front", ascending: true))
    check("view sort other view untouched", asc.views[1].viewSort == nil, true)
    check("no view sort by default", table.viewSort == nil, true)
    let limited = await index.evaluateBase(
        yaml: "views:\n  - type: table\n    name: T\n    filters:\n      and:\n        - file.hasTag(\"bike\")\n    sort:\n      - property: front\n        direction: DESC\n    limit: 1\n",
        thisPath: nil, sortOverrides: ["T": BaseSortKey(property: "front", ascending: true)])
    check("view sort before limit", limited.views[0].groups[0].rows.map { $0.cells[0].text }, ["Gravel"])
    put("Sorted.base", baseYAML)
    await index.refresh()
    let sortedPayload = await index.renderPayload(for: "Sorted.base",
                                                  baseSort: ["Table": BaseSortKey(property: "front", ascending: true)])
    check("payload view sort", sortedPayload.base?.views[0].groups[0].rows.first?.cells[0].text, "Gravel")
    check("payload view sort leaves file", try? String(contentsOf: tmp.appendingPathComponent("Sorted.base"), encoding: .utf8), baseYAML)
    try? FileManager.default.removeItem(at: tmp.appendingPathComponent("Sorted.base"))
    await index.refresh()
    let cards = base.views[1]
    check("base groups", cards.groups.map { $0.key?.text ?? "" }, ["high", "low"])
    check("base group sizes", cards.groups.map(\.rows.count), [2, 1])
    let bike = await index.evaluateBase(yaml: "views:\n  - type: table\n    filters:\n      and:\n        - file.hasTag(\"bike\")\n    order:\n      - file.name\n      - front tire pressure (PSI)\n", thisPath: nil)
    check("user-style base", bike.views[0].groups[0].rows.count, 3)
    check("user-style column", bike.views[0].columns.map(\.name), ["file name", "front tire pressure (PSI)"])
    let thisBase = await index.evaluateBase(yaml: "filters:\n  and:\n    - file.hasLink(this.file)\n", thisPath: "Home.md")
    check("base this", thisBase.views[0].groups[0].rows.map(\.path), ["Bikes/Gravel.md", "Projects/Plan.md"])
    let bad = await index.evaluateBase(yaml: "filters:\n  and:\n    - 'front >'\n", thisPath: nil)
    check("base error reported", bad.views[0].error != nil, true)
    put("Bikes/Garage.md", "Bikes:\n```base\nfilters:\n  and:\n    - file.inFolder(\"Bikes\")\n    - file.hasTag(\"bike\")\n```\n![[Fleet.base#Cards]]")
    put("Fleet.base", "views:\n  - type: table\n    name: Table\n  - type: cards\n    name: Cards\n    filters:\n      and:\n        - file.hasTag(\"bike\")\n")
    await index.refresh()
    let garage = await index.renderPayload(for: "Bikes/Garage.md")
    check("payload base block", garage.bases.values.first?.views[0].total, 3)
    check("payload base embed view", garage.embeds[RenderPayload.embedKey(path: "Fleet.base", subpath: "Cards")]?.base?.selected, 1)
    let fleet = await index.renderPayload(for: "Fleet.base")
    check("payload base file", fleet.base?.views.count, 2)
    check("payload base json", fleet.json().contains("\"views\""), true)
    for p in ["Bikes/Road.md", "Bikes/Gravel.md", "Bikes/Old.md", "Bikes/Garage.md", "Fleet.base"] {
        try? FileManager.default.removeItem(at: tmp.appendingPathComponent(p))
    }
    try? FileManager.default.removeItem(at: tmp.appendingPathComponent("Bikes"))
    await index.refresh()

    // Incremental update: edit, add, delete.
    try? await Task.sleep(nanoseconds: 1_100_000_000) // mtime granularity
    put("Home.md", "Now mentions zebra")
    put("New.md", "brand new #fresh")
    try? FileManager.default.removeItem(at: tmp.appendingPathComponent("pic.png"))
    let snap2 = await index.refresh()
    check("changed", snap2.changed, ["Home.md", "pic.png"])
    check("search updated", await index.search("zebra").hits.map(\.path), ["Home.md"])
    check("search old gone", await index.search("welcome").hits.count, 0)
    check("new tag", snap2.tagCounts["fresh"], 1)
    check("backlinks updated", await index.backlinks(to: "Projects/Plan.md").count, 0)

    // A second index over the same vault reuses the cache.
    let again = VaultIndex(root: tmp)
    let snap3 = await again.refresh()
    check("cache reload", snap3.files.count, snap2.files.count)
    check("cache search", await again.search("zebra").hits.count, 1)

    try? FileManager.default.removeItem(at: tmp)
    try? FileManager.default.removeItem(at: IndexCache.cacheURL(for: tmp.resolvingSymlinksInPath()))
    semaphore.signal()
}
semaphore.wait()

// NoteWriter: the only vault writer (edit mode).
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("juju-writer-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let note = dir.appendingPathComponent("Note.md")
    try? "old text that is long".write(to: note, atomically: false, encoding: .utf8)
    let created = (try? FileManager.default.attributesOfItem(atPath: note.path)[.creationDate]) as? Date
    check("writer load", NoteWriter.load(root: dir, path: "Note.md"), "old text that is long")
    check("writer save", NoteWriter.save("new", root: dir, path: "Note.md", baseline: "old text that is long"), .saved)
    check("writer truncates", NoteWriter.load(root: dir, path: "Note.md"), "new")
    check("writer keeps ctime", (try? FileManager.default.attributesOfItem(atPath: note.path)[.creationDate]) as? Date, created)
    check("writer unchanged", NoteWriter.save("new", root: dir, path: "Note.md", baseline: "new"), .unchanged)
    check("writer conflict", NoteWriter.save("mine", root: dir, path: "Note.md", baseline: "stale"), .conflict("new"))
    check("writer kept disk on conflict", NoteWriter.load(root: dir, path: "Note.md"), "new")
    check("writer no create", NoteWriter.save("x", root: dir, path: "Missing.md", baseline: ""),
          .failed("The note no longer exists on disk"))
    check("writer md only", NoteWriter.save("x", root: dir, path: "a.base", baseline: ""), .failed("Only Markdown notes can be edited"))
    check("writer contained", NoteWriter.save("x", root: dir, path: "../escape.md", baseline: ""), .failed("Outside the vault"))
    try? FileManager.default.removeItem(at: dir)
}

// Attachment folders outside the vault: ![](<juju:name>).
// JujuPix .jjpx photos: JujuPixCore's conformance vector (small Argon2 parameters, so this is fast).
let jjpxVector: [String: Any] = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("JujuPixCore/spec/conformance/jjpx/basic-png.json")
    return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
}()
let jjpxFile = Data(base64Encoded: jjpxVector["jjpxBase64"] as? String ?? "") ?? Data()
let jjpxOriginal = Data(base64Encoded: jjpxVector["originalBase64"] as? String ?? "") ?? Data()
do {
    check("jjpx vector loaded", jjpxFile.isEmpty, false)
    let keys = JujuPixKeys()
    func opened(_ k: JujuPixKeys) -> String {
        switch k.open(jjpxFile) {
        case .image(let d, let mime): return d == jjpxOriginal ? "image " + mime : "wrong bytes"
        case .locked(let h): return "locked \(h.width ?? 0)x\(h.height ?? 0)"
        case .failed(let m): return "failed " + m
        }
    }
    check("jjpx locked", opened(keys), "locked 40x30")
    check("jjpx wrong password", Result { try keys.unlock(password: "nope", sample: jjpxFile) }.isSuccess, false)
    check("jjpx still locked", keys.isUnlocked, false)
    try? keys.unlock(password: jjpxVector["password"] as? String ?? "", sample: jjpxFile)
    check("jjpx unlocked", keys.isUnlocked, true)
    check("jjpx decrypts", opened(keys), "image image/png")
    let saved = keys.exported()
    check("jjpx export has no password", saved.map { String(decoding: $0, as: UTF8.self).contains("horse") }, false)
    keys.lock()
    check("jjpx lock", opened(keys), "locked 40x30")
    let restored = JujuPixKeys()
    check("jjpx restore", saved.map { restored.restore($0) }, true)
    check("jjpx restored decrypts", opened(restored), "image image/png")
    let viaRecovery = JujuPixKeys()
    try? viaRecovery.unlock(recoveryKey: (jjpxVector["recoveryKey"] as? String ?? "").lowercased(), sample: jjpxFile)
    check("jjpx recovery key", opened(viaRecovery), "image image/png")
    let multi = JujuPixKeys()
    let pw = jjpxVector["password"] as? String ?? ""
    check("jjpx samples skip unreadable", try? multi.unlock(password: pw, samples: [Data("junk".utf8), jjpxFile]), 1)
    check("jjpx has key", JujuPixKeys.header(jjpxFile).map { multi.hasKey(for: $0) }, true)
    check("jjpx already unlocked", (try? multi.unlock(password: pw, samples: [jjpxFile])) == nil, true)
    check("jjpx no readable samples", (try? JujuPixKeys().unlock(password: pw, samples: [Data("junk".utf8)])) == nil, true)
    check("jjpx not a jjpx", { if case .failed = keys.open(Data("png".utf8)) { return true }; return false }(), true)
}
extension Result where Failure == Error {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}

let extDone = DispatchSemaphore(value: 0)
Task {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("juju-ext-\(UUID().uuidString)")
    let vault = base.appendingPathComponent("Vault"), drive = base.appendingPathComponent("Drive"),
        second = base.appendingPathComponent("Second")
    for d in [vault, drive.appendingPathComponent("2026/Oct"), second] {
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    }
    func put(_ url: URL, _ s: String) { try? s.write(to: url, atomically: false, encoding: .utf8) }
    put(drive.appendingPathComponent("2026/Oct/Pasted image 20261003201825.png"), "png")
    put(drive.appendingPathComponent("clip.mp4"), "mp4")
    put(drive.appendingPathComponent("notes.txt"), "not media")
    put(second.appendingPathComponent("clip.mp4"), "second")
    put(second.appendingPathComponent("only here.jpg"), "jpg")
    try? jjpxFile.write(to: drive.appendingPathComponent("2026/Oct/passport.png.jjpx"))
    put(vault.appendingPathComponent("inside.png"), "png")
    put(vault.appendingPathComponent("Note.md"), """
    ![](<juju:Pasted image 20261003201825.png>)
    ![|300](<JUJU:only here.jpg>) and ![](juju:clip.mp4) ![](<juju:inside.png>) ![](<juju:nope.png>)
    ![](<juju:Oct/Pasted image 20261003201825.png>) ![](<juju:passport.png.jjpx>)
    """)

    check("juju names", JujuRef.names(in: "a ![x](<juju:My pic.png>) b ![](juju:a%20b.png) ![](https://x/y.png) [l](<juju:no.png>)"),
          ["My pic.png", "a b.png"])
    let ext = ExternalAttachments.scan([drive, second])
    check("ext by name in subfolder", ext.resolve("Pasted image 20261003201825.png"),
          .init(folder: 0, path: "2026/Oct/Pasted image 20261003201825.png"))
    check("ext case-insensitive", ext.resolve("PASTED IMAGE 20261003201825.PNG")?.folder, 0)
    check("ext folder order", ext.resolve("clip.mp4"), .init(folder: 0, path: "clip.mp4"))
    check("ext second folder", ext.resolve("only here.jpg"), .init(folder: 1, path: "only here.jpg"))
    check("ext path suffix", ext.resolve("Oct/Pasted image 20261003201825.png")?.folder, 0)
    check("ext wrong path", ext.resolve("Nov/Pasted image 20261003201825.png"), nil)
    check("ext media only", ext.resolve("notes.txt"), nil)
    check("ext reference by name", ext.reference(for: .init(folder: 1, path: "only here.jpg")), "only here.jpg")
    check("ext reference shadowed", ext.reference(for: .init(folder: 1, path: "clip.mp4")), nil)
    check("ext entries (with .jjpx)", ext.entries.count, 5)
    check("juju markdown", JujuRef.markdown("a b.png"), "![](<juju:a b.png>)")
    check("clean name", ["  Pasted image 1.png\n", "\"a.png\"", "/Users/me/Drive/Sub/a b.png", "file:///Users/me/a%20b.png",
                         "Sub/a.png", "juju:x.png", "<juju:y.png>", "~/Pics/z.jpg"].map(JujuRef.cleanName),
          ["Pasted image 1.png", "a.png", "a b.png", "a b.png", "Sub/a.png", "x.png", "y.png", "z.jpg"])
    check("jjpx url", ExternalAttachments.url(for: .init(folder: 1, path: "Trip/a.jpg.jjpx")), "juju://jjpx/1/Trip/a.jpg.jjpx")
    check("ext url", ExternalAttachments.url(for: .init(folder: 0, path: "2026/Oct/Pasted image #1?.png")),
          "juju://ext/0/2026/Oct/Pasted%20image%20%231%3F.png")

    let idx = VaultIndex(root: vault)
    await idx.refresh()
    await idx.setExternalAttachments(ext)
    let payload = await idx.renderPayload(for: "Note.md")
    check("payload external", payload.external, [
        "pasted image 20261003201825.png": "juju://ext/0/2026/Oct/Pasted%20image%2020261003201825.png",
        "only here.jpg": "juju://ext/1/only%20here.jpg",
        "clip.mp4": "juju://ext/0/clip.mp4",
        "inside.png": "juju://vault/inside.png",
        "oct/pasted image 20261003201825.png": "juju://ext/0/2026/Oct/Pasted%20image%2020261003201825.png",
        "passport.png.jjpx": "juju://jjpx/0/2026/Oct/passport.png.jjpx",
    ])
    check("juju not a note link", await idx.outgoing(from: "Note.md").count, 0)
    try? fm.removeItem(at: base)
    try? fm.removeItem(at: IndexCache.cacheURL(for: vault.resolvingSymlinksInPath()))
    extDone.signal()
}
extDone.wait()

// Vim engine (tests ported from Notepad+++).
func vimRun(_ text: String, _ keys: [String], cursor: Int = 0) -> VimEngine {
    let e = VimEngine(text: text, cursor: cursor)
    keys.forEach { e.handle($0) }
    return e
}
func vk(_ s: String) -> [String] { s.map(String.init) }
let vesc = ["Escape"]
check("vim dw", vimRun("foo bar baz", vk("dw")).string, "bar baz")
check("vim dd", vimRun("a\nb\nc\n", vk("jdd")).string, "a\nc\n")
check("vim 2dd", vimRun("a\nb\nc\nd\n", vk("2dd")).string, "c\nd\n")
check("vim ciw", vimRun("foo bar", vk("wciwXY") + vesc).string, "foo XY")
check("vim yyjp", vimRun("ab\ncd\n", vk("yyjp")).string, "ab\ncd\nab\n")
check("vim undo", vimRun("hello", vk("xxu")).string, "ello")
check("vim insert", vimRun("bc", vk("ia") + vesc).string, "abc")
check("vim insert mode", vimRun("bc", vk("ia") + vesc).mode, .normal)
check("vim A", vimRun("ab", vk("AX") + vesc).string, "abX")
check("vim o", vimRun("a\nb", vk("oX") + vesc).string, "a\nX\nb")
check("vim di(", vimRun("f(a, b)", vk("fadi(")).string, "f()")
check("vim D", vimRun("hello world", vk("wD")).string, "hello ")
check("vim v d", vimRun("abcdef", vk("vlld")).string, "def")
check("vim f,x", vimRun("a,b,c", vk("f,x")).string, "ab,c")
check("vim gg", vimRun("a\nb\nc", vk("Ggg")).cursor, 0)
check("vim G", vimRun("a\nb\nc", vk("G")).cursor, 4)
check("vim dG", vimRun("a\nb\nc", vk("jdG")).string, "a\n")
check("vim cc", vimRun("a\nb\n", vk("ccX") + vesc).string, "X\nb\n")
check("vim d$", vimRun("hello world", vk("wd$")).string, "hello ")
check("vim dap", vimRun("a\nb\n\nc\n", vk("dap")).string, "c\n")
check("vim gUiw", vimRun("foo bar", vk("gUiw")).string, "FOO bar")
check("vim >>", vimRun("a\n", vk(">>")).string, "\ta\n")
check("vim J", vimRun("a\nb", vk("J")).string, "a b")
check("vim r", vimRun("abc", vk("rx")).string, "xbc")

check("vim Vjx", vimRun("a\nb\nc\nd\n", vk("Vjx")).string, "c\nd\n")
check("vim Vjjx", vimRun("a\nb\nc\nd\n", vk("jVjx")).string, "a\nd\n")
check("vim Vjd", vimRun("a\nb\nc\n", vk("Vjd")).string, "c\n")
check("vim Vkx up", vimRun("a\nb\nc\n", vk("jjVkx")).string, "a\n")
check("vim V last line no NL", vimRun("a\nb", vk("jVx")).string, "a\n")
check("vim Vjy p", vimRun("a\nb\nc\n", vk("VjyGp")).string, "a\nb\nc\na\nb\n")
check("vim vlx", vimRun("abcdef", vk("vlx")).string, "cdef")
check("vim VjX", vimRun("a\nb\nc\n", vk("vjX")).string, "c\n")
check("vim Vjx undo", vimRun("a\nb\nc\n", vk("Vjxu")).string, "a\nb\nc\n")
check("vim $ normal", vimRun("hello\nworld", vk("$")).cursor, 4)
check("vim $ second line", vimRun("hello\nworld", vk("j$")).cursor, 10)
check("vim $ empty line", vimRun("a\n\nb", vk("j$")).cursor, 2)
check("vim $ then i", vimRun("hello\n", vk("$i")).cursor, 4)
check("vim A end", vimRun("hello\nx", vk("A")).cursor, 5)
let vex = VimEngine(text: "x"); ":wq".forEach { vex.handle(String($0)) }
check("vim ex", vex.handle("Enter"), .ex("wq"))
let vse = VimEngine(text: "x"); "/ab".forEach { vse.handle(String($0)) }
check("vim search", vse.handle("Enter"), .search("ab", forward: true))

let reset = VimEngine(text: "ab"); reset.handle("x"); reset.resetHistory(); reset.handle("u")
check("vim resetHistory", reset.string, "b")

// MARK: Markdown styles (editor live preview, formatting toggles)

func styled(_ t: String) -> [String] {
    let ns = t as NSString
    return MarkdownStyle.spans(in: t).map { sp in
        let kind: String
        switch sp.kind {
        case .heading(let n): kind = "h\(n)"
        case .embed(let target, let w): kind = "embed(\(target)\(w.map { "|\($0)" } ?? ""))"
        case .callout(let type, let title, let fold): kind = "callout(\(type)\(fold) \(ns.substring(with: title)))"
        case .iframe(let src, let w, let h): kind = "iframe(\(src) \(w ?? 0)x\(h ?? 0))"
        default: kind = "\(sp.kind)"
        }
        return kind + ":" + ns.substring(with: sp.range)
    }.sorted()
}
check("style bold", styled("a **b** c"), ["bold:**b**"])
check("style italic", styled("*i* and _j_"), ["italic:*i*", "italic:_j_"])
check("style strike/highlight", styled("~~s~~ ==h=="), ["highlight:==h==", "strikethrough:~~s~~"])
check("style bold nested italic", styled("**Bold _nested_ text**"), ["bold:**Bold _nested_ text**", "italic:_nested_"])
check("style bold italic", styled("***both*** ___also___"), ["boldItalic:***both***", "boldItalic:___also___"])
check("style intraword underscore", styled("snake_case_name"), [])
check("style list bullet", styled("* item\n- x"), [])
check("style heading", styled("## Title **b**"), ["bold:**b**", "h2:## Title **b**"])
check("style code wins", styled("`**not bold**`"), ["code:`**not bold**`"])
check("style fence", styled("```\n**x**\n```\n**y**"), ["bold:**y**", "codeBlock:```\n**x**\n```"])
check("style frontmatter", styled("---\na: 1\n---\n*x*"), ["frontmatter:---\na: 1\n---", "italic:*x*"])
check("style links", styled("[[Note|Alias]] [t](u)"), ["link:[[Note|Alias]]", "link:[t](u)"])
check("style embeds", styled("![[a.png|300]] ![|200](<juju:b c.png>) ![](x.png)"),
      ["embed(a.png|300):![[a.png|300]]", "embed(juju:b c.png|200):![|200](<juju:b c.png>)", "embed(x.png):![](x.png)"])
check("style alias markers", MarkdownStyle.spans(in: "[[Note|Alias]]").first?.markers,
      [NSRange(location: 0, length: 7), NSRange(location: 12, length: 2)])

check("style callout", styled("> [!Info] Description\n> line **b**\n>\nafter"),
      ["bold:**b**", "callout(info Description):> [!Info] Description\n> line **b**\n>",
       "quote:>", "quote:> [!Info] Description", "quote:> line **b**"])
check("style callout markers", MarkdownStyle.spans(in: "> [!note]- \n> x").first { if case .callout = $0.kind { true } else { false } }?.markers,
      [NSRange(location: 0, length: 11), NSRange(location: 12, length: 2)])
check("style callout folded no title", styled("> [!tip]-\n> x").first, "callout(tip- ):> [!tip]-\n> x")
check("style plain quote", styled("> just a quote"), ["quote:> just a quote"])
check("style callout ends at fence", styled("> [!x] T\n```\n> y\n```").first, "callout(x T):> [!x] T")
check("style iframe", styled("<iframe width=\"560\" height=\"315\" src=\"https://www.youtube.com/embed/abc\" title=\"*x*\"></iframe>"),
      ["iframe(https://www.youtube.com/embed/abc 560x315):<iframe width=\"560\" height=\"315\" src=\"https://www.youtube.com/embed/abc\" title=\"*x*\"></iframe>"])

// Bases: settings as ordered JSON for the page's editor, and view layout options.
check("yaml json keeps order and types", YAMLLite.parse("b: 1\na: [x, \"2\"]\nc: true\nd: hi there\ne:\n  z: 0.5\n  y: ~\n").json,
      #"{"b":1,"a":["x",2],"c":true,"d":"hi there","e":{"z":0.5,"y":null}}"#)
check("yaml json escapes", YAMLLite.parse("f: 'say \"hi\"'\n").json, #"{"f":"say \"hi\""}"#)
let viewDef = BaseDefinition(yaml: "views:\n  - type: cards\n    name: C\n    cardSize: 300\n    imageFit: contain\n    columnSize:\n      note.a: 120\n      file.name: 80\n")
check("view options", viewDef.views.first?.options, ["cardSize": "300", "imageFit": "contain"])
check("view column sizes", viewDef.views.first?.columnSize, ["note.a": 120, "file.name": 80])

let linkDoc = "See [[Plan#Goals|the plan]] and [site](https://x.y) and [n](Notes/My%20Note.md) ![[pic.png|200]]"
check("link target wiki", MarkdownStyle.linkTarget(in: linkDoc, at: 8), "Plan#Goals")
check("link target url", MarkdownStyle.linkTarget(in: linkDoc, at: 38), "https://x.y")
check("link target md", MarkdownStyle.linkTarget(in: linkDoc, at: 58), "Notes/My Note.md")
check("link target embed", MarkdownStyle.linkTarget(in: linkDoc, at: (linkDoc as NSString).length - 3), "pic.png")
check("link target none", MarkdownStyle.linkTarget(in: linkDoc, at: 1), nil)

func toggled(_ f: MarkdownStyle.Format, _ t: String, _ sel: NSRange) -> String {
    let e = MarkdownStyle.toggle(f, in: t, selection: sel)
    var out = (t as NSString).replacingCharacters(in: e.range, with: e.replacement)
    let s = e.selection
    out = (out as NSString).replacingCharacters(in: NSRange(location: NSMaxRange(s), length: 0), with: "]")
    return (out as NSString).replacingCharacters(in: NSRange(location: s.location, length: 0), with: "[")
}
check("toggle bold sel", toggled(.bold, "a word b", NSRange(location: 2, length: 4)), "a **[word]** b")
check("toggle bold off", toggled(.bold, "a **word** b", NSRange(location: 4, length: 4)), "a [word] b")
check("toggle bold off incl markers", toggled(.bold, "a **word** b", NSRange(location: 2, length: 8)), "a [word] b")
check("toggle bold caret word", toggled(.bold, "a word b", NSRange(location: 4, length: 0)), "a **wo[]rd** b")
check("toggle bold empty", toggled(.bold, "a  b", NSRange(location: 2, length: 0)), "a **[]** b")
check("toggle italic", toggled(.italic, "x y", NSRange(location: 2, length: 1)), "x *[y]*")
check("toggle italic not bold", toggled(.italic, "**y**", NSRange(location: 2, length: 1)), "**_[y]_**")
check("toggle italic nested", toggled(.italic, "**Bold nested text**", NSRange(location: 7, length: 6)),
      "**Bold _[nested]_ text**")
check("toggle italic off in bold-italic", toggled(.italic, "***y***", NSRange(location: 3, length: 1)), "**[y]**")
check("toggle bold-italic", toggled(.boldItalic, "y", NSRange(location: 0, length: 1)), "***[y]***")
check("toggle strike", toggled(.strikethrough, "y z", NSRange(location: 0, length: 3)), "~~[y z]~~")
check("toggle highlight off", toggled(.highlight, "==y==", NSRange(location: 2, length: 1)), "[y]")
check("toggle trims spaces", toggled(.bold, "a word b", NSRange(location: 1, length: 6)), "a **[word]** b")

// MARK: Frontmatter editing (Properties panel)

let fmDoc = "---\ntitle: Old\ntags:\n  - a\n  - b\ndone: false\n# comment\nrelated: \"[[X]]\"\n---\nBody\n"
check("fm set text", Frontmatter.apply(.set(key: "title", value: .text("New title")), to: fmDoc),
      fmDoc.replacingOccurrences(of: "title: Old", with: "title: New title"))
check("fm set list", Frontmatter.apply(.set(key: "tags", value: .list(["a", "c d"])), to: fmDoc),
      fmDoc.replacingOccurrences(of: "  - b\n", with: "  - c d\n"))
check("fm checkbox", Frontmatter.apply(.set(key: "done", value: .text("true")), to: fmDoc),
      fmDoc.replacingOccurrences(of: "done: false", with: "done: true"))
check("fm add", Frontmatter.apply(.set(key: "status", value: .text("")), to: fmDoc),
      fmDoc.replacingOccurrences(of: "\n---\nBody", with: "\nstatus:\n---\nBody"))
check("fm remove list", Frontmatter.apply(.remove(key: "tags"), to: fmDoc),
      fmDoc.replacingOccurrences(of: "tags:\n  - a\n  - b\n", with: ""))
check("fm rename", Frontmatter.apply(.rename(from: "title", to: "name"), to: fmDoc),
      fmDoc.replacingOccurrences(of: "title: Old", with: "name: Old"))
check("fm rename onto existing", Frontmatter.apply(.rename(from: "title", to: "done"), to: fmDoc), nil)
check("fm unchanged", Frontmatter.apply(.set(key: "title", value: .text("Old")), to: fmDoc), nil)
check("fm link quoted", Frontmatter.apply(.set(key: "related", value: .text("[[Y|Why]]")), to: fmDoc),
      fmDoc.replacingOccurrences(of: "\"[[X]]\"", with: "\"[[Y|Why]]\""))
check("fm create", Frontmatter.apply(.set(key: "tags", value: .list(["x"])), to: "Body"), "---\ntags:\n  - x\n---\nBody")
check("fm quoting", ["plain", "a: b", "#tag", "-5", "2026-10-04", "say \"hi\"", "- x", "x #y"].map(Frontmatter.quoteValue),
      ["plain", "\"a: b\"", "\"#tag\"", "-5", "2026-10-04", "say \"hi\"", "\"- x\"", "\"x #y\""])
for v in ["a: b", "#tag", "say \"hi\"", "back\\slash", "[[Note|Alias]]", "x #y"] {
    let doc = Frontmatter.apply(.set(key: "k", value: .text(v)), to: "x")!
    check("fm round trip \(v)", Frontmatter.split(doc).properties.first?.value, .text(v))
}

// MARK: New notes

do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("juju-new-\(UUID().uuidString)")
    try? fm.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
    check("create note", NoteWriter.create(root: root, folder: "Inbox", name: "Idea"), .created("Inbox/Idea.md"))
    check("create note empty", (try? String(contentsOf: root.appendingPathComponent("Inbox/Idea.md"), encoding: .utf8)), "")
    check("create never overwrites", NoteWriter.create(root: root, folder: "Inbox", name: "idea.md"), .failed("“idea” already exists"))
    check("create bad name", NoteWriter.create(root: root, folder: "", name: "a/b"),
          .failed("Names can’t contain any of  \\ / : * ? \" < > | # ^ [ ]"))
    check("create missing folder", NoteWriter.create(root: root, folder: "Nope", name: "x"), .failed("The folder “Nope” doesn’t exist"))
    check("create outside", NoteWriter.create(root: root, folder: "..", name: "x"), .failed("Outside the vault"))
    check("available name", NoteWriter.availableName("Untitled", folder: "", existing: ["Untitled.md", "untitled 1.md"]), "Untitled 2")
    check("new note location default", NewNoteLocation.folder(vault: root, currentPath: "A/b.md", existingFolders: []), "")
    try? fm.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    try? #"{"newFileLocation":"current"}"#.write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: false, encoding: .utf8)
    check("new note location current", NewNoteLocation.folder(vault: root, currentPath: "A/b.md", existingFolders: []), "A")
    try? #"{"newFileLocation":"folder","newFileFolderPath":"Inbox/"}"#.write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: false, encoding: .utf8)
    check("new note location folder", NewNoteLocation.folder(vault: root, currentPath: nil, existingFolders: ["Inbox"]), "Inbox")
    // Pasted images: Obsidian's attachment location, name and link.
    func attach(_ setting: String?) -> String {
        let json = setting.map { #"{"attachmentFolderPath":"\#($0)"}"# } ?? "{}"
        try? json.write(to: root.appendingPathComponent(".obsidian/app.json"), atomically: false, encoding: .utf8)
        return NewNoteLocation.attachmentFolder(vault: root, notePath: "Notes/Day.md")
    }
    check("attach default root", attach(nil), "")
    check("attach root", attach("/"), "")
    check("attach same folder", attach("./"), "Notes")
    check("attach subfolder", attach("./assets"), "Notes/assets")
    check("attach fixed folder", attach("Attachments"), "Attachments")
    var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 3; comps.hour = 20; comps.minute = 18; comps.second = 25
    check("pasted image name", NewNoteLocation.pastedImageName(date: Calendar.current.date(from: comps)!), "Pasted image 20261003201825.png")
    check("embed wikilink", NewNoteLocation.embed(path: "A/Pasted image 1.png", markdown: false, nameIsUnique: true), "![[Pasted image 1.png]]")
    check("embed wikilink dup", NewNoteLocation.embed(path: "A/x.png", markdown: false, nameIsUnique: false), "![[A/x.png]]")
    check("embed markdown", NewNoteLocation.embed(path: "A/Pasted image 1.png", markdown: true, nameIsUnique: true), "![](A/Pasted%20image%201.png)")
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    check("save attachment creates folder", NoteWriter.saveAttachment(png, root: root, folder: "Notes/assets", name: "Pasted image 1.png"),
          .created("Notes/assets/Pasted image 1.png"))
    check("save attachment no overwrite", NoteWriter.saveAttachment(Data([1]), root: root, folder: "Notes/assets", name: "Pasted image 1.png"),
          .created("Notes/assets/Pasted image 1 1.png"))
    check("save attachment kept original", try? Data(contentsOf: root.appendingPathComponent("Notes/assets/Pasted image 1.png")), png)
    check("save attachment in vault root", NoteWriter.saveAttachment(png, root: root, folder: "", name: "Pasted image 2.png"),
          .created("Pasted image 2.png"))
    try? "---\ntags: [a]\n---\nBody ✓".write(to: root.appendingPathComponent("Notes/Day.md"), atomically: false, encoding: .utf8)
    check("clone note", NoteWriter.copyNote(root: root, path: "Notes/Day.md"), .created("Notes/Day 1.md"))
    check("clone exact copy", try? String(contentsOf: root.appendingPathComponent("Notes/Day 1.md"), encoding: .utf8), "---\ntags: [a]\n---\nBody ✓")
    check("clone next number", NoteWriter.copyNote(root: root, path: "Notes/Day.md"), .created("Notes/Day 2.md"))
    check("clone missing", NoteWriter.copyNote(root: root, path: "Notes/Nope.md"), .failed("The note no longer exists on disk"))
    check("clone non-note", NoteWriter.copyNote(root: root, path: "Notes/assets/Pasted image 1.png"), .failed("Only Markdown notes can be duplicated"))
    // Editing an unlocked base: the whole .base rewritten; a note property set from a table cell.
    try? "views:\n  - type: table\n".write(to: root.appendingPathComponent("B.base"), atomically: false, encoding: .utf8)
    check("rewrite base", NoteWriter.rewrite("views: []\n", root: root, path: "B.base", baseline: "views:\n  - type: table\n"), .saved)
    check("rewrite conflict", NoteWriter.rewrite("x: 1\n", root: root, path: "B.base", baseline: "stale"), .conflict("views: []\n"))
    check("rewrite refuses other files", NoteWriter.rewrite("x", root: root, path: "a.txt", baseline: ""), .failed("Only notes and bases can be changed"))
    // Deleting (Obsidian's "Deleted files" setting): the vault's .trash folder or permanently; never outside.
    let fmD = FileManager.default
    try? fmD.createDirectory(at: root.appendingPathComponent("Del/Sub"), withIntermediateDirectories: true)
    try? Data("x".utf8).write(to: root.appendingPathComponent("Del/Sub/a.md"))
    try? Data("y".utf8).write(to: root.appendingPathComponent("Del/b.md"))
    try? Data("z".utf8).write(to: root.appendingPathComponent("Del/c.md"))
    check("delete to .trash", NoteWriter.delete(root: root, path: "Del/b.md", option: .local), .movedToVaultTrash(".trash/b.md"))
    check("delete gone", fmD.fileExists(atPath: root.appendingPathComponent("Del/b.md").path), false)
    try? Data("y2".utf8).write(to: root.appendingPathComponent("Del/b.md"))
    check("delete to .trash numbered", NoteWriter.delete(root: root, path: "Del/b.md", option: .local), .movedToVaultTrash(".trash/b 1.md"))
    check("delete folder to .trash", NoteWriter.delete(root: root, path: "Del/Sub", option: .local), .movedToVaultTrash(".trash/Sub"))
    check("trashed folder kept its file", fmD.fileExists(atPath: root.appendingPathComponent(".trash/Sub/a.md").path), true)
    check("delete from .trash is permanent", NoteWriter.delete(root: root, path: ".trash/b 1.md", option: .local), .deleted)
    check("delete permanently", NoteWriter.delete(root: root, path: "Del/c.md", option: .none), .deleted)
    check("delete missing", NoteWriter.delete(root: root, path: "Del/c.md", option: .none), .failed("“c.md” no longer exists on disk"))
    check("delete vault root", NoteWriter.delete(root: root, path: "", option: .none), .failed("Nothing to delete"))
    check("delete outside", NoteWriter.delete(root: root, path: "../x.md", option: .none), .failed("Nothing to delete"))
    check("delete .obsidian", NoteWriter.delete(root: root, path: ".obsidian/app.json", option: .none),
          .failed("Obsidian’s settings folder can’t be deleted here"))
    let outsideTarget = fmD.temporaryDirectory.appendingPathComponent("juju-keep-\(UUID().uuidString).md")
    try? Data("keep".utf8).write(to: outsideTarget)
    try? fmD.createSymbolicLink(at: root.appendingPathComponent("Del/link.md"), withDestinationURL: outsideTarget)
    check("delete symlink", NoteWriter.delete(root: root, path: "Del/link.md", option: .none), .deleted)
    check("symlink target untouched", fmD.fileExists(atPath: outsideTarget.path), true)
    try? fmD.removeItem(at: outsideTarget)
    check("save attachment outside", NoteWriter.saveAttachment(png, root: root, folder: "../x", name: "a.png"), .failed("Outside the vault"))
    try? fm.removeItem(at: root)
}

if failures == 0 { print("All core checks passed") } else { print("\(failures) failure(s)"); exit(1) }
