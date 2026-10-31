import JujuPixCore
import ObsidianJujuCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct OutlineItem: Identifiable, Hashable {
    let id: String
    let level: Int
    let text: String
}

/// The renderer page. It is loaded at an https origin (the bundle id, which never resolves) rather than
/// juju://, because YouTube embeds refuse to play (error 153) without an http(s) referrer identifying the
/// embedding app. An https page may not load scripts, styles, fonts or iframes from juju://, so everything
/// the page needs is inlined here; only passive media (images, audio, video) still come from juju://vault.
enum RendererPage {
    static let origin = URL(string: "https://com.example.obsidianjuju/index.html")!

    static let html: String = {
        let web = JujuSchemeHandler.webRoot
        func read(_ path: String) -> String {
            (try? String(contentsOf: web.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        var page = read("index.html")
        // <script src="x"></script> → inline script
        let scriptRegex = try! NSRegularExpression(pattern: #"<script src="([^"]+)"></script>"#)
        for m in scriptRegex.matches(in: page, range: NSRange(page.startIndex..., in: page)).reversed() {
            let src = (page as NSString).substring(with: m.range(at: 1))
            let code = read(src).replacingOccurrences(of: "</script", with: "<\\/script")
            page = (page as NSString).replacingCharacters(in: m.range, with: "<script>\n\(code)\n</script>")
        }
        // <link rel="stylesheet" href="x" [media="…"]> → inline style
        let linkRegex = try! NSRegularExpression(pattern: #"<link rel="stylesheet" href="([^"]+)"(?: media="([^"]+)")?>"#)
        for m in linkRegex.matches(in: page, range: NSRange(page.startIndex..., in: page)).reversed() {
            let href = (page as NSString).substring(with: m.range(at: 1))
            let media = m.range(at: 2).location == NSNotFound ? "" : " media=\"\((page as NSString).substring(with: m.range(at: 2)))\""
            var css = read(href)
            if href.hasSuffix("katex.min.css") { css = inlineKaTeXFonts(css, folder: web.appendingPathComponent("vendor/katex")) }
            page = (page as NSString).replacingCharacters(in: m.range, with: "<style\(media)>\n\(css)\n</style>")
        }
        return page
    }()

    static let mermaidSource: String = {
        (try? String(contentsOf: JujuSchemeHandler.webRoot.appendingPathComponent("vendor/mermaid.min.js"), encoding: .utf8)) ?? ""
    }()

    /// KaTeX's CSS lists woff2, woff and ttf fonts by relative URL; keep only woff2, as data URIs.
    private static func inlineKaTeXFonts(_ css: String, folder: URL) -> String {
        var out = css.replacingOccurrences(of: #",url\(fonts/[^)]+\.(woff|ttf)\) format\("[a-z]+"\)"#, with: "",
                                           options: .regularExpression)
        let fontRegex = try! NSRegularExpression(pattern: #"url\((fonts/[^)]+\.woff2)\)"#)
        for m in fontRegex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            let file = (out as NSString).substring(with: m.range(at: 1))
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: "url(data:font/woff2;base64,\(data.base64EncodedString()))")
        }
        return out
    }
}

/// Serves vault attachments (juju://vault/…) read-only, plus the renderer's own files (juju://app/…).
final class JujuSchemeHandler: NSObject, WKURLSchemeHandler {
    var vaultRoot: URL?
    /// Attachment folders outside the vault, served read-only as juju://ext/<index>/<path>.
    var externalFolders: [URL] = []
    /// JujuPix `.jjpx` photos are served decrypted (in memory only) as juju://jjpx/<index or "v">/<path>,
    /// or as a lock placeholder while locked.
    var jujuPixKeys: JujuPixKeys?
    private var stopped = Set<ObjectIdentifier>()

    static let webRoot: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Web"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        // `swift run` during development: use the source tree.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Web")
    }()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = String(url.path.drop(while: { $0 == "/" }))
        var data: Data?
        switch url.host {
        case "app":
            if let file = VaultReader.containedURL(Self.webRoot, path) { data = try? Data(contentsOf: file) }
        case "vault":
            if let root = vaultRoot { data = VaultReader.readData(root, path) }
        case "ext":
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let i = Int(parts[0]), externalFolders.indices.contains(i) {
                data = VaultReader.readData(externalFolders[i], parts[1])
            }
        case "jjpx":
            serveEncrypted(task, url: url, path: path)
            return
        default:
            break
        }
        guard let data else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
            return
        }
        let ext = (path as NSString).pathExtension
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-cache",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }

    /// Reads and decrypts off the main thread (Argon2id can take a moment when a photo comes from another library).
    private func serveEncrypted(_ task: WKURLSchemeTask, url: URL, path: String) {
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        var file: URL?
        if parts.count == 2 {
            if parts[0] == "v", let root = vaultRoot {
                file = VaultReader.containedURL(root, parts[1])
            } else if let i = Int(parts[0]), externalFolders.indices.contains(i) {
                file = VaultReader.containedURL(externalFolders[i], parts[1])
            }
        }
        let keys = jujuPixKeys
        let id = ObjectIdentifier(task)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bytes = file.flatMap { try? Data(contentsOf: $0) }
            let result: (Data, String)? = bytes.flatMap { bytes in
                switch keys?.open(bytes) {
                case .image(let data, let mime): return (data, mime)
                case .locked(let header): return (Self.placeholder(header, locked: true), "image/svg+xml")
                case .failed(let message): return (Self.placeholder(nil, locked: false, message: message), "image/svg+xml")
                case nil: return nil
                }
            }
            DispatchQueue.main.async {
                guard let self, self.stopped.remove(id) == nil else { return }
                guard let (data, mime) = result else {
                    task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
                    return
                }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store",
                ])!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    /// A photo-sized box with a lock, shown instead of a locked (or unreadable) `.jjpx` photo.
    static func placeholder(_ header: JjpxHeader?, locked: Bool, message: String = "") -> Data {
        var w = Double(header?.width ?? 0), h = Double(header?.height ?? 0)
        if w <= 0 || h <= 0 { (w, h) = (640, 400) }
        // Keep the photo's shape at a size that suits text.
        let scale = 640 / max(w, 1)
        w = 640; h = min(max(h * scale, 160), 900)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let title = esc(header?.title ?? header?.originalName ?? "")
        let line1 = locked ? "Encrypted JujuPix photo" : "Can’t show this JujuPix photo"
        let line2 = locked ? "Click to unlock" : esc(message)
        let cx = w / 2, cy = h / 2
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(w))" height="\(Int(h))" viewBox="0 0 \(Int(w)) \(Int(h))">
        <rect x="1" y="1" width="\(Int(w) - 2)" height="\(Int(h) - 2)" rx="8" fill="#8881" stroke="#8886" stroke-width="2" stroke-dasharray="8 6"/>
        <g transform="translate(\(cx - 14) \(cy - 62))" fill="none" stroke="#888" stroke-width="3">
        <rect x="2" y="16" width="24" height="20" rx="3"/><path d="M7 16v-5a7 7 0 0 1 14 0v5"/></g>
        <g font-family="-apple-system, sans-serif" text-anchor="middle" fill="#888">
        <text x="\(cx)" y="\(cy + 10)" font-size="20" font-weight="600">\(line1)</text>
        <text x="\(cx)" y="\(cy + 36)" font-size="15">\(line2)</text>
        <text x="\(cx)" y="\(cy + 60)" font-size="13" opacity="0.8">\(title)</text></g></svg>
        """
        return Data(svg.utf8)
    }
}

/// The reading view's web view: right-clicking a vault link offers "Open link" and "Open in new tab" instead of
/// WebKit's link items (which would try to load the link as a web page).
final class ReadingWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard let controller = navigationDelegate as? NoteWebController, let link = controller.contextLink else { return }
        let webKitLinkItems: Set<String> = ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
                                            "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink"]
        var items = menu.items.filter { !webKitLinkItems.contains($0.identifier?.rawValue ?? "") }
        while items.first?.isSeparatorItem == true { items.removeFirst() }
        menu.items = items
        let open = NSMenuItem(title: "Open link", action: #selector(openContextLink(_:)), keyEquivalent: "")
        let newTab = NSMenuItem(title: "Open in new tab", action: #selector(openContextLink(_:)), keyEquivalent: "")
        newTab.tag = 1
        for item in [open, newTab] { item.target = self; item.representedObject = link }
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(newTab, at: 0)
        menu.insertItem(open, at: 0)
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        (navigationDelegate as? NoteWebController)?.contextLink = nil
    }

    @MainActor @objc private func openContextLink(_ sender: NSMenuItem) {
        guard let controller = navigationDelegate as? NoteWebController, let link = sender.representedObject as? [String: Any] else { return }
        controller.model?.followLink(from: controller.tabID, path: link["path"] as? String, target: link["target"] as? String ?? "",
                                     subpath: link["subpath"] as? String, newTab: sender.tag == 1)
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

/// One reading view (one per tab), owning a WKWebView with the renderer page loaded.
@MainActor
final class NoteWebController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let tabID: UUID
    let webView: WKWebView
    weak var model: VaultModel?
    private(set) var outline: [OutlineItem] = []
    /// The vault link under the last right-click (from the page), for the context menu.
    var contextLink: [String: Any]?
    /// The rendered file shows Bases results, which depend on every note, so any vault change re-renders it.
    var showsBases = false
    /// The rendered file has `![](<juju:…>)` images, so attachment-folder changes re-render it.
    var usesExternal = false
    private var ready = false
    private var pending: (() -> Void)?

    init(tabID: UUID, model: VaultModel, schemeHandler: JujuSchemeHandler) {
        self.tabID = tabID
        self.model = model
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "juju")
        config.preferences.isElementFullscreenEnabled = true
        webView = ReadingWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "juju")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.isInspectable = true
        webView.allowsMagnification = true
        webView.pageZoom = UserDefaults.standard.object(forKey: SettingsKey.zoom) as? Double ?? 1
        loadPage()
    }

    private func loadPage() {
        webView.loadSimulatedRequest(URLRequest(url: RendererPage.origin), responseHTML: RendererPage.html)
    }

    func render(_ json: String, scrollY: Double, subpath: String?, highlight: [String]) {
        let run = { [weak self] in
            guard let self else { return }
            self.applyOptions()
            var opts: [String: Any] = ["scrollY": scrollY, "highlight": highlight]
            if let subpath { opts["subpath"] = subpath }
            self.webView.callAsyncJavaScript("window.juju.render(json, opts)", arguments: ["json": json, "opts": opts],
                                             in: nil, in: .page) { _ in }
        }
        if ready { run() } else { pending = run }
    }

    func applyOptions() {
        let d = UserDefaults.standard
        let size = d.object(forKey: SettingsKey.fontSize) as? Double ?? SettingsKey.defaultFontSize
        let readable = d.object(forKey: SettingsKey.readableLineWidth) as? Bool ?? true
        webView.callAsyncJavaScript("window.juju.setOptions(o)", arguments: ["o": ["fontSize": size, "readableLineWidth": readable]],
                                    in: nil, in: .page) { _ in }
        webView.pageZoom = d.object(forKey: SettingsKey.zoom) as? Double ?? 1
    }

    func scrollToHeading(id: String) {
        webView.callAsyncJavaScript("window.juju.scrollToHeadingId(id)", arguments: ["id": id], in: nil, in: .page) { _ in }
    }

    func find(_ text: String, backwards: Bool, completion: @escaping (Bool) -> Void) {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        webView.find(text, configuration: config) { result in completion(result.matchFound) }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            pending?()
            pending = nil
        case "outline":
            let items = (body["headings"] as? [[String: Any]] ?? []).compactMap { h -> OutlineItem? in
                guard let id = h["id"] as? String, let text = h["text"] as? String else { return nil }
                return OutlineItem(id: id, level: (h["level"] as? Int) ?? 1, text: text)
            }
            outline = items
            model?.outlineDidChange(for: tabID, items)
        case "scroll":
            model?.recordScroll(tabID: tabID, y: (body["y"] as? Double) ?? 0)
        case "open":
            let mods = body["mods"] as? [String: Bool] ?? [:]
            let cc = HotkeyModifier.current == .command ? mods["meta"] == true : mods["ctrl"] == true
            model?.followLink(from: tabID, path: body["path"] as? String, target: body["target"] as? String ?? "",
                              subpath: body["subpath"] as? String, newTab: cc)
        case "tag":
            if let tag = body["tag"] as? String { model?.searchTag(tag) }
        case "external":
            if let s = body["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body["text"] as? String ?? "", forType: .string)
        case "baseSave":
            if let path = body["path"] as? String, let yaml = body["yaml"] as? String {
                model?.saveBase(tabID: tabID, path: path, yaml: yaml)
            }
        case "baseSort":
            guard let path = body["path"] as? String, let view = body["view"] as? String else { break }
            let sort = (body["property"] as? String).map {
                BaseSortKey(property: $0, ascending: (body["direction"] as? String)?.uppercased() != "DESC")
            }
            model?.setBaseSort(tabID: tabID, path: path, view: view, sort: sort)
        case "baseCell":
            guard let note = body["path"] as? String, let property = body["property"] as? String else { break }
            let value: PropertyValue = (body["list"] as? [String]).map { .list($0) } ?? .text(body["text"] as? String ?? "")
            model?.setBaseCell(tabID: tabID, notePath: note, property: property, value: value)
        case "copyImageFile":
            model?.copyImageFile(src: body["src"] as? String ?? "", path: body["what"] as? String == "path")
        case "openInObsidian":
            model?.openInObsidian()
        case "openDefaultApp":
            model?.openInDefaultApp()
        case "loadMermaid":
            webView.evaluateJavaScript(RendererPage.mermaidSource) { [weak self] _, _ in
                self?.webView.evaluateJavaScript("window.juju.mermaidLoaded()")
            }
        case "rerender":
            model?.rerender(tabID: tabID)
        case "jjpx":
            // The clicked photo, so a library that's still locked is asked for even when others are unlocked.
            let src = body["src"] as? String ?? ""
            model?.requestJujuPixUnlock(photo: model?.jujuPixFile(src: src)) { [weak self] in
                // Unlocked: zoom it like any other image.
                guard let json = try? JSONSerialization.data(withJSONObject: [src]),
                      let arg = String(data: json, encoding: .utf8) else { return }
                self?.webView.evaluateJavaScript("window.juju.zoomImage(\(arg)[0])")
            }
        case "context":
            contextLink = body["link"] as? [String: Any]
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // Only the renderer page itself may load in the main frame; iframes (PDFs, video embeds) may load.
        if url == RendererPage.origin || url.scheme == "juju" || action.targetFrame?.isMainFrame == false || url.scheme == "about" {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        loadPage()
        model?.rerender(tabID: tabID)
    }
}

struct NoteWebView: NSViewRepresentable {
    let controller: NoteWebController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if controller.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let web = controller.webView
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Native, read-only PDF viewer for PDF tabs (PDFKit only saves when asked to; we never ask).
struct PDFFileView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
