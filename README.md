# ObsidianJuju

A viewer for existing Obsidian vaults (SwiftUI + WebKit, macOS 15+). Every note opens read-only, so you can't
edit a note by accident; you unlock one note at a time to edit it. You also get an app you can extend directly, with no plugins.

Build: `./build_app.sh` → `build/ObsidianJuju.app` (needs only the Swift command line tools).
Test: `./test.sh` (read-only guard + core checks).

## Opening a vault
On first launch, pick one of the vaults the Obsidian app knows about (read from Obsidian's `obsidian.json`), or
choose "Open folder as vault…". The last vault reopens on launch. Switch vaults from the vault name at the bottom
of the left sidebar.

## Hotkeys (CC = Cmd or Ctrl, set in Settings — same as BetterFileExplorer and PSY)
Same defaults as Obsidian:
- CC + `O` Quick switcher (fuzzy file/alias search; CC + `↵` opens in a new tab)
- CC + `P` Command palette
- CC + Shift + `F` Search in all files
- CC + `F` Find in current note (`↵` / Shift + `↵` next / previous)
- CC + Option + `←` / `→` Navigate back / forward
- CC + click a link, file or search result: open in a new tab
- CC + `T` New tab, CC + `W` close tab, CC + Shift + `T` undo close tab
- Ctrl + `Tab` / Ctrl + Shift + `Tab`, or CC + `PageDown` / `PageUp`: next / previous tab
- CC + `1`…`8` go to tab N, CC + `9` last tab
- CC + `=` / `-` / `0` Zoom in / out / reset
- CC + `R` Reload vault index
- CC + `,` Settings
- CC + `E` Unlock the current note for editing; once unlocked, toggle editor / preview
- With CC = Ctrl, Ctrl + `C` / `X` / `V` / `A` / `Z` (Shift + `Z`) also copy / cut / paste / select all / undo (redo)

## What renders like Obsidian (default theme, light and dark)
`#tag` chips (nested tags too), `[[wikilinks]]` with `|alias`, `#heading` and `#^block` targets, unresolved links,
`![[embeds]]` of notes, sections, blocks, images (`|300` sizing), audio and video,
YouTube and other web `<iframe>` embeds, Properties (frontmatter),
inline title, callouts (all built-in types, foldable `+`/`-`), task lists, `==highlights==`, `%%comments%%`,
footnotes, tables, code highlighting with a Copy button, `$math$` / `$$math$$` (KaTeX), and Mermaid diagrams.
Everything is bundled, so it works offline.

PDFs open in a native viewer tab; a PDF embedded in a note shows as a card that opens it.

Side panels: file explorer, search, and tags on the left; outline, backlinks, and outgoing links on the right.
Notes edited in Obsidian refresh live.

## Bases
`.base` files open in a tab, and bases also render when embedded (`![[Books.base]]`, or `![[Books.base#View]]` for
one view) and in ```` ```base ```` code blocks, where `this` is the note containing them.
- Views: table, cards (with an `image` cover property) and list, with a switcher when there are several.
  Other view types (e.g. map) fall back to a table.
- Supported: global and per-view filters (`and` / `or` / `not`), formulas, `properties` display names, `order`,
  `sort`, `groupBy`, `limit`, and summaries (built-in and custom `values` formulas).
- The formula language follows Obsidian's reference: `note.` / `file.` / `formula.` / `this`, arithmetic,
  comparisons, `&&` / `||` / `!`, date math with durations (`date + "1M"`), and the global, string, number, date,
  list, file, link and object functions (`file.hasTag`, `inFolder`, `hasLink`, `if`, `now`, `format`,
  `filter` / `map` / `reduce`, …).
- Read-only: cells can't be edited, and nothing is written back to the vault. Results refresh when notes change.

## Attachments outside the vault
Add folders outside the vault (e.g. a Google Drive folder) in Settings → "Attachment folders outside the vault"
(saved per vault, in the app's settings — nothing is written to the vault). Refer to a file in them with a
standard Markdown image whose address starts with `juju:`:

    ![](<juju:Pasted image 20261003201825.png>)
    ![|300](<juju:Pasted image 20261003201825.png>)      (width 300, as in Obsidian)

- The name is looked up in the vault first, then in the folders from top to bottom (any subfolder; the shortest
  path wins). `juju:Sub/name.png` narrows it to a path ending in `Sub/name.png`.
- Images, audio and video. The folders are only read, and changes in them refresh open notes.
- **Insert external image** (command palette, or File → Insert External Image…) unlocks the note if needed and
  lists the files in those folders. Type or paste a file name (a name copied in Finder, a full path or a
  `file://` URL all work), then press ↵ to write `![](<juju:name>)` at the cursor. When two files share a name it
  writes enough of the path to pick the right one; a name it can't find can still be inserted as typed.
- Obsidian shows these as a missing image; it doesn't treat them as links, so they never create notes.
  Plain `![[name.png]]` keeps Obsidian's meaning and only looks in the vault.

### JujuPix encrypted photos (.jjpx)
`.jjpx` photos encrypted by JujuPix work the same way: `![](<juju:passport.jpg.jjpx>)` (Insert external image lists
them with a lock icon). Until you unlock, a placeholder of the photo's shape shows a lock; click it (or run
"JujuPix: Unlock encrypted photos") and enter your JujuPix password or the library's recovery key.
- Decryption is done by JujuPix's own core (`../JujuPixCore`), in memory only. Decrypted photos are never written to
  disk, and the `.jjpx` files are only read.
- Settings → "JujuPix encrypted photos":
  - **Lock again**: after 5/15/30/60 minutes of idle time (default 15; also on sleep and screen lock) or only when
    quitting.
  - **Remember in Keychain**: off by default (you're asked for the password each time). When on, the derived keys
    (never the password) are kept in your login Keychain and unlocking asks for Touch ID or your Mac password.
- **Several libraries with different passwords**: each library is unlocked separately and they stay unlocked side by
  side. Click a photo whose library is still locked (even while others show) and enter that library's password;
  it's checked against the clicked photo. The palette command tries the password on one photo from each library
  your notes and attachment folders use (a library is a folder with `.jujupix`), so one password unlocks every
  library it belongs to. The Keychain keeps every library's key; a library it doesn't have yet is asked for.
- "JujuPix: Lock encrypted photos" (and auto-lock) locks every library at once.
- Building needs JujuPixCore checked out next to this repo (`~/git/JujuPixCore`); `build_app.sh` builds it.

## Edit mode (per note)
There is no global edit switch. Click the "Read-only" lock in the note header (or CC + `E`, or the palette's
"Edit mode: Unlock current note") to edit that one note. CC + `E` or the book/pencil button toggles the rendered
reading view.
- The note locks again as soon as you leave it: open another note, go back/forward, switch tabs, or close the tab.
- Edits autosave about a second after you stop typing (no CC + `S` needed), and are flushed when the note locks
  or the app quits.
- If the note changes on disk (e.g. in Obsidian) while you have unsaved edits, autosave pauses and a bar offers
  "Use disk version" or "Keep my version". Nothing is overwritten silently; if a note locks with edits that
  couldn't be saved, your text is copied to the clipboard.
- Only Markdown notes can be edited. Besides saving unlocked notes, the app only creates new notes you ask for
  and saves images you paste; it never overwrites, renames, moves or deletes files.
- Keys as in Obsidian: Home / End = start / end of the line, CC + `↑` / CC + `↓` = start / end of the note
  (Shift extends the selection; CC + `↑` / `↓` also scroll the reading view). With CC = Ctrl, turn off macOS's
  Mission Control shortcuts for Ctrl + `↑` / `↓` (System Settings → Keyboard → Keyboard Shortcuts → Mission
  Control), or macOS takes those keys first.

### Deleting notes and folders
Right-click a note, file or folder in the file list → "Delete", or run "Delete current file" (palette, File menu).
You're asked first ("Don't ask again" turns that off; Settings → "Confirm before deleting notes and folders" turns it
back on). Where it goes follows Obsidian's "Deleted files" setting: the macOS Trash (Obsidian's default), the
vault's `.trash` folder, or permanently. Open tabs showing it are saved and closed first. Links to it aren't changed
(as in Obsidian). A note doesn't need to be unlocked to be deleted.

Attachments follow Obsidian's "Delete attachments when deleting files" (Settings → Files and links; default "Ask
each time"): when a note is deleted, the files it links to or embeds that aren't notes, canvases or bases and that
no other note uses are its attachments. "Ask each time" lists them with checkboxes ("Delete file attachments?"),
"Always" deletes them with the note, "Never" keeps them. They go where deleted files go. Deleting a folder leaves
attachments elsewhere alone, as in Obsidian. Settings → General shows both Obsidian settings for the open vault.

### Right-click "Open in new tab"
Right-click a note in the file list, a search result, a backlink or outgoing link, or a link (or embedded note)
inside a note — in the reading view or the editor — and choose "Open in new tab" (or "Open link"). CC-click does
the same.

### Duplicating a note
The palette's "Duplicate current file" (Obsidian's name), File → Duplicate Current File, or right-click a note → "Make a copy" (as in Obsidian)
copies the note byte for byte to "Name 1.md" (next free number) in the same folder and opens it. Pending edits are
saved first; the copy opens unlocked if you were editing the original, otherwise read-only. Attachments aren't
duplicated (the copy links to the same files).

### Pasting images
Paste a screenshot, an image copied from another app, or image files copied in Finder into an unlocked note
(CC + `V`): the image is saved where Obsidian's "Default location for new attachments" says (vault root, the note's
folder, a subfolder of it, or a fixed folder; `.obsidian/app.json`), named like Obsidian ("Pasted image
20261004101530.png"; copied files keep their names, with " 1", " 2"… if taken), and `![[…]]` is written at the
cursor (`![](…)` if Obsidian is set to Markdown links). Clipboard text still pastes as text.

### Image zoom
In the reading view, click an image to see it large on a dimmed overlay. Scroll (or pinch) to zoom in further, drag
to move around, and click or press Esc to close. Unlocked JujuPix photos zoom the same way (a locked one asks to
unlock); images that are links follow the link instead.

### Copy an image's file name or path
In the reading view, hover over an image: "Name" and "Path" buttons appear in its top-right corner. "Name" copies
the file name (`beach 1.png`), "Path" the full path on disk — for vault images, images from outside folders
(`juju:`) and JujuPix photos (the `.jjpx` file). For a web image, "Path" copies its address.

### Live preview
The editor shows styles as you type, like Obsidian's Live Preview: headings, **bold**, *italic*, ~~strikethrough~~,
==highlight==, bold with nested italic, bold and italic, `code`, links (aliases shown) and embedded images (vault
images, `juju:` images from outside folders, and unlocked JujuPix photos) under their line. The syntax characters
are hidden except on the line with the cursor. Frontmatter shows as an editable Properties panel like Obsidian's
(type icons, tag and list pills, checkboxes, links, "Empty"): click a value to edit it, toggle checkboxes, add or
remove list items and tags, rename or remove a property from its icon menu, and "+ Add property" (or "Add file
property", CC + `;`, which also works on notes without properties). Each change rewrites only that property's YAML
lines (undoable, autosaved). The cursor stays out of the hidden YAML; use "Toggle Live Preview/Source mode" to edit
it as text. Callouts (`> [!info] Title`) show as Obsidian's colored boxes with icon and title (a folded `[!x]-`
shows only its title) until the cursor enters them, then as source. A one-line `<iframe>` (e.g. a YouTube embed)
shows as a thumbnail with a play button under its line; the video plays in the reading view (CC+E). The palette's
"Toggle Live Preview/Source mode" (or Settings → Editor) switches to plain source. It only changes the display: the saved text is exactly what you typed.

### Formatting
In an unlocked note: CC + `B` bold (`**…**`), CC + `I` italic (`*…*`, or `_…_` inside bold so the nesting stays
valid), and the palette's "Toggle strikethrough" (`~~…~~`), "Toggle highlight" (`==…==`) and "Toggle bold and
italic" (`***…***`); also in the Format menu. They wrap the selection or the word at the cursor, and remove the
style if it's already there.

### New notes
CC + `N`, File → New Note, the palette's "Create new note", or right-click a folder → "New note". Type a name
(prefilled with "Untitled") and press ↵; the note is created empty and opens unlocked for editing. It goes where
Obsidian's "Default location for new notes" says (`.obsidian/app.json`: vault root, same folder as the current
note, or a chosen folder). An existing file is never overwritten.

### Vim mode
Settings → Editor → "Vim keybindings" (or the palette's "Vim: Toggle Vim keybindings"). Same engine and keys as
Notepad+++: Normal / Insert / Visual / V-Line, counts, `h j k l w b e 0 ^ $ gg G { } % f t ; `, operators
`d c y > < gu gU g~` with motions and text objects (`iw aw ip ap i" a" i( a( i[ i{`), `x X D C s S Y p P u
Ctrl-r J ~ r o O`, Ctrl-d/u/f/b, `/` `?` `n N`, and an optional escape chord (e.g. `jk`). A status bar under the
editor shows the mode or command line. A note opens in Normal mode.
- Ex commands: `:42` go to line, `:s/a/b/g`, `:%s/a/b/g` (regex), `:w` save now, `:q` / `:wq` / `:x` lock the
  note (edits are already autosaved, so `:q!` can't discard them), `:tabnew`, `:bn` / `:bp`, `:qa` quit.
- With CC = Ctrl, Ctrl-r/d/u/f/b go to Vim in Normal/Visual mode instead of the app hotkeys.

## Search
Obsidian syntax: `word another` (all must match), `"exact phrase"`, `-exclude`, `tag:#work`, `path:Projects`,
`file:plan`. Matching is case-insensitive substring. An inverted index makes large vaults fast. It's cached in
`~/Library/Caches/ObsidianJuju`, and only changed files are re-read.

## Write guarantee
- Vault access goes through `VaultReader`, which has no write API.
- The only vault writer is `NoteWriter`: it overwrites an existing `.md` note in place, and only when the disk
  still matches what the editor loaded. Only `EditSession` (an unlocked note) calls it. It can also create a new,
  empty note, a copy of a note or a pasted image (`O_EXCL`, so never over an existing file), called only from `VaultModel`.
- `scripts/check_readonly.sh` (run by `build_app.sh` and `test.sh`) fails if any file-writing call shows up
  outside `NoteWriter.swift` and `IndexCache.swift` (which writes only to `~/Library/Caches`), or if anything
  other than `Editor.swift` calls `NoteWriter.save` or anything other than `VaultModel.swift` calls
  `NoteWriter.create` / `copyNote` / `saveAttachment`.
- The web renderer has no `contenteditable`, and task checkboxes are disabled.

## Roadmap
- Hover page preview, graph view, bookmarks.
