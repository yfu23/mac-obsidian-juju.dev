#!/bin/bash
# Keeps disk writes confined to two audited files:
#   - IndexCache.swift writes only to ~/Library/Caches.
#   - NoteWriter.swift overwrites an existing note the user explicitly unlocked (per-note edit mode),
#     and is only called from EditSession (Editor.swift); it also creates new empty notes the user asked
#     for (VaultModel.createNote), never overwriting, deletes what the user confirmed (VaultModel.performDelete),
#     and rewrites an unlocked base or a note property edited in its table (VaultModel, NoteWriter.rewrite).
# Fails if a file-writing API appears anywhere else, so the viewer stays read-only as features are added.
set -euo pipefail
cd "$(dirname "$0")/.."
pattern='\.write\(to:|\.write\(toFile:|\.write\(contentsOf:|writeToFile|createFile\(|removeItem\(|moveItem\(|copyItem\(|trashItem\(|replaceItemAt|FileHandle\(forWriting|FileHandle\(forUpdating|forWritingTo|createDirectory\(|setAttributes\([^)]*ofItemAtPath|fopen\(|\.atomically|truncate\('
hits=$(grep -rnE "$pattern" Sources/ObsidianJuju Sources/ObsidianJujuCore --include=*.swift \
  | grep -v '/IndexCache.swift:' | grep -v '/NoteWriter.swift:' || true)
if [ -n "$hits" ]; then
  echo "Read-only check FAILED — file-writing calls found outside IndexCache.swift / NoteWriter.swift:"
  echo "$hits"
  exit 1
fi
callers=$(grep -rn 'NoteWriter\.save(' Sources/ObsidianJuju Sources/ObsidianJujuCore --include=*.swift \
  | grep -v '/Editor.swift:' | grep -v '/NoteWriter.swift:' || true)
if [ -n "$callers" ]; then
  echo "Read-only check FAILED — NoteWriter.save may only be called from EditSession (Editor.swift):"
  echo "$callers"
  exit 1
fi
creators=$(grep -rnE 'NoteWriter\.(create|saveAttachment|copyNote|delete|rewrite)' Sources/ObsidianJuju Sources/ObsidianJujuCore --include=*.swift \
  | grep -v '/VaultModel.swift:' | grep -v '/NoteWriter.swift:' || true)
if [ -n "$creators" ]; then
  echo "Read-only check FAILED — NoteWriter.create / saveAttachment / copyNote / delete / rewrite may only be called from VaultModel:"
  echo "$creators"
  exit 1
fi
# The web renderer must not get editing affordances either.
if grep -nE 'contenteditable|designMode' Resources/Web/*.js Resources/Web/*.html >/dev/null; then
  echo "Read-only check FAILED — editable content in the web renderer."
  exit 1
fi
echo "Read-only check passed"
