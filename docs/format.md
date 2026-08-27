# The `.sw.png` format

An Sketchyworks document is a PNG **and** a ZIP, at the same time. PNG readers stop at
`IEND`; ZIP readers scan backward for the central directory. Neither notices the other.

- **Double-click it** — Finder thumbnails it, Preview opens it, any image viewer on
  any OS shows you the cover page.
- **`unzip` it** — every page as SVG in `exports/`, the editable document as JSON in
  `pages/`, placed images in `assets/`.

Geometry is stored as SVG path data, so the document is readable with a text editor.
There is no step where you need this program to get your artwork back. That is the
entire point.

This is the Fireworks `.fw.png` trick, which nobody has shipped since Adobe killed
Fireworks in 2013.

**Double-clicking opens Sketchyworks**, while every other PNG on the machine still
belongs to Preview. LaunchServices resolves a file's type from the last extension
component only, so a `.sw.png` is a `public.png` and a third-party type cannot
outrank an Apple system type — the compound extension is registered but never wins.
The lever that does work is the per-file binding Finder writes for *Get Info > Open
With*: an extended attribute naming the handler. Sketchyworks stamps it on every file it
writes, and `sw claim <file|dir>` re-applies it in bulk.

**The binding requires a Developer ID signature.** With an ad-hoc signature the app is
Gatekeeper-rejected, and macOS then challenges any *document* bound to it — the warning
names the document, not the app, and offers to move it to the Trash. `bin/build` picks
up a Developer ID automatically and warns loudly if it can't find one. `sw unclaim`
removes the binding if you ever need to.

Otherwise the binding degrades gracefully: extended attributes don't survive zipping,
email, or most upload round trips, and when it's lost the file just opens in Preview
again, which is what it did before.

**One caution:** the editable half lives in bytes appended after the PNG. Run the file
through an image optimizer, or re-save it from another image editor, and that half is
stripped — you keep the picture and lose the document. `sw verify` detects this.
