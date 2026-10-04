# ObsidianJuju — notes for Claude

- Swift Package (no Xcode project). Targets: `ObsidianJujuCore` (vault scan, parsing, link resolution, search index;
  no UI), `ObsidianJuju` (SwiftUI app), `CoreChecks` (test executable: `swift run CoreChecks`; XCTest needs full Xcode).
- Build the app with `./build_app.sh`; run `./test.sh` after changes.
  `build_app.sh` also runs `scripts/release_smoke.swift` on the optimized core (an optimizer bug once broke the
  name check only in release); harnesses and CoreChecks are debug builds.
- **Notes are read-only unless the user unlocks one.** Disk writes live only in `IndexCache.swift` (Caches) and
  `NoteWriter.swift` (overwrites an existing .md in place, refuses if disk ≠ baseline; `create` makes a new empty
  note with O_EXCL; `saveAttachment` saves a pasted image, O_EXCL with " 1" suffixes; `delete` per Obsidian's `trashOption`, after
  `DeleteConfirmView` unless "Don't ask again"; then the note's unused attachments per Obsidian's
  `deleteUnlinkedAttachments` via `VaultIndex.unlinkedAttachments` / `DeleteAttachmentsView`), and only `EditSession` in `Editor.swift` may call `NoteWriter.save`,
  only `VaultModel` may call `create` / `copyNote` / `saveAttachment` / `delete`. `scripts/check_readonly.sh` enforces this; don't loosen it casually.
- Edit mode is per note, no global switch (user's requirement): `VaultModel.editSessions[tabID]`. Unlock via
  header lock / CC+E / palette; it re-locks (flushing edits) on navigating to another path, back/forward, tab
  switch, tab close, vault change. Autosave ~1s after typing (no Cmd+S). Editor is a native TextKit 1 NSTextView
  (`NoteEditorView`); CC+E toggles editor ⇄ rendered preview while unlocked.
- Live preview (`LivePreview.swift`): `MarkdownStyle.spans` (core) → display attributes only; syntax marked
  `.jujuHidden` becomes null glyphs (NSLayoutManager delegate) except on the caret's paragraph; images are
  overlay NSImageViews under their line, room made with paragraphSpacing. Frontmatter is always collapsed
  (hidden glyphs, 0.01pt lines; its closing line is as tall as the panel) and the editable `PropertiesPanel`
  (SwiftUI, NSHostingView) is drawn over it; the caret is clamped out of it. Panel edits → `Frontmatter.apply`
  (core; rewrites only that property's lines) → minimal text replacement with undo. Callouts the caret isn't in get
  `.jujuCallout` (box drawn by `JujuLayoutManager.drawBackground`, indents via paragraph style); entering/leaving
  one restyles. One-line `<iframe>` → thumbnail overlay (YouTube `hqdefault.jpg`) like images. Never hide line-break glyphs
  (lines merge); TextKit ignores paragraphSpacingBefore oddly here, so room comes from line heights. Never change the text for display.
  Formatting toggles: `MarkdownStyle.toggle` (CC+B/CC+I, palette, Format menu). New notes: CC+N →
  `Overlay.newNote` → `VaultModel.createNote`; folder from `.obsidian/app.json` (`NewNoteLocation`).
  Image paste: `VimTextView.paste` → `VaultModel.pasteImage` (attachment folder/name/link per Obsidian settings).
  Home/End = line, CC+↑/↓ = note (`VimTextView.handleNavigation`; reading view via `Hotkeys`).
- Hotkeys go through `Hotkeys` in `Commands.swift` (one local key monitor). They use the CC modifier
  (Cmd or Ctrl, `HotkeyModifier`, storage key `hotkeyModifier`), shared with BetterFileExplorer and PSY.
  Menu items only display the shortcuts.
- Rendering: Swift builds a `RenderPayload` (body, frontmatter, pre-resolved links, embed contents) and the page
  `Resources/Web/juju.js` renders it with markdown-it plus Obsidian-syntax plugins. Styles in `obsidian.css` follow
  Obsidian's default-theme variable names.
- The page is loaded with `loadSimulatedRequest` at `https://com.example.obsidianjuju/` (see `RendererPage`), because
  YouTube embeds fail with error 153 without an http(s) referrer. An https page can't load scripts, styles, fonts or
  iframes from `juju://`, so `RendererPage.html` inlines every script/style from `Resources/Web` (KaTeX fonts as
  data URIs) and Mermaid is injected on demand. Only passive media (img/audio/video) use `juju://vault/…`.
  PDFs therefore open in a native PDFKit tab (`PDFFileView`) and PDF embeds render as cards.
- Image zoom: `zoomImage` in `juju.js` (overlay `.juju-zoom`, CSS in `obsidian.css`); `.jjpx` clicks go to Swift first
  (`requestJujuPixUnlock(photo:whenUnlocked:)`), which calls `window.juju.zoomImage` when the photo's library is unlocked.
- Image hover toolbar (`.juju-image-bar` in `juju.js`) posts `copyImageFile`; `VaultModel.imageLocation(src:)` maps
  `juju://vault|ext|jjpx` addresses to files; copies go to `copyPasteboard` (tests swap in a private one).
- Vendored JS (markdown-it, footnote, mark, KaTeX, highlight.js, Mermaid, Lucide icons) is in `Resources/Web/vendor`.
- Vim mode: `ObsidianJujuCore/VimEngine.swift` is a copy of ../Notepad+++'s `NotepadCore/VimEngine.swift` (plus
  `resetHistory()`, `recordUndoPoint()`); keep them in sync. `VimTextView` ports Notepad+++'s `EditorTextView` (key handling, block
  cursor, escape chord, `:s` / search); app-level ex commands go to `VaultModel.runVimEx`. Settings keys
  `vimEnabled`, `escapeChord` (same names as Notepad+++). The `Hotkeys` monitor lets Vim's Ctrl-r/d/u/f/b through.
- Outside-vault attachments: `![](<juju:name>)` (ObsidianJuju-only syntax chosen by the user). Per-vault folder
  list in UserDefaults `attachmentFolders:<vault path>` (`VaultModel.attachmentFolders`, Settings UI).
  `ExternalAttachments.scan` (media only) → `VaultIndex.setExternalAttachments`; `RenderPayload.external` maps
  `JujuRef.key(name)` → `juju://vault/…` (vault wins) or `juju://ext/<folder index>/<path>`, served read-only by
  `JujuSchemeHandler`. FSEvents watchers per folder rescan and re-render tabs with `usesExternal`.
- JujuPix `.jjpx` photos: `ObsidianJujuCore` depends on `../JujuPixCore/bindings/swift` (Rust core via UniFFI; build with
  `../JujuPixCore/scripts/build-apple.sh`, which `build_app.sh` runs). Its `jjpx_*` single-file functions were added for
  this app. `JujuPixKeys` holds derived keys in memory; `JujuSchemeHandler` serves `juju://jjpx/<folder|v>/<path>`
  decrypted in memory (never to disk) or an SVG lock placeholder; `rerender` appends `?g=<jujuPixGeneration>` so
  lock/unlock reloads. Unlock UI, Keychain (derived keys only, gated by LAContext) and idle auto-lock live in
  `JujuPix.swift` (several libraries/passwords: keys per `passwordKeyId`/`recoveryKeyId`; a click on a locked photo passes its
`src` so its library is asked for; `jujuPixSamples` = one photo per library); settings `jujuPixAutoLockMinutes` (default 15, 0 = only on quit), `jujuPixRememberInKeychain`.
- Bases: `YAMLLite.swift` (YAML subset), `BaseExpr.swift` (values, durations, Moment-style date formatting, expression
  parser), `Bases.swift` (evaluator + view engine → `BaseResult` JSON). `RenderPayload` carries `base` (for .base files),
  `bases` (```base blocks keyed by `baseBlockKey(source, content)`) and `Embed.base` (`![[x.base]]`); `juju.js`
  `renderBase` draws table/cards/list. Tabs showing bases re-render on any vault change (`showsBases`).
