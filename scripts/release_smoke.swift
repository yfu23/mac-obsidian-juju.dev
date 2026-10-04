// Release-build smoke test, run by build_app.sh: the optimizer once broke the note-name check (every name was
// rejected in release while debug-built CoreChecks passed), so a few public-API results are checked on the
// release objects before the app is assembled.
import Foundation
import ObsidianJujuCore

var failed = false
func expect(_ name: String, _ got: String?, _ want: String?) {
    if got != want { failed = true; print("FAIL \(name): got \(String(describing: got)) want \(String(describing: want))") }
}
expect("plain name", NoteWriter.nameProblem("Untitled 5"), nil)
expect("pasted image name", NoteWriter.nameProblem("Pasted image 20261005143012"), nil)
expect("unicode name", NoteWriter.nameProblem("VOLLUTO 沃魯托"), nil)
expect("slash rejected", NoteWriter.nameProblem("a/b") == nil ? "accepted" : "rejected", "rejected")
expect("hash rejected", NoteWriter.nameProblem("x#y") == nil ? "accepted" : "rejected", "rejected")
expect("plain property", Frontmatter.apply(.set(key: "t", value: .text("hello world")), to: ""), "---\nt: hello world\n---\n")
expect("quoted property", Frontmatter.apply(.set(key: "t", value: .text("#tag")), to: ""), "---\nt: \"#tag\"\n---\n")
expect("bold span", MarkdownStyle.spans(in: "a **b** c").first.map { "\($0.kind)" }, "bold")
if failed { exit(1) }
print("Release smoke test passed")
