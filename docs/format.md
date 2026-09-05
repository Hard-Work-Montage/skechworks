# The `.sw` format

A Skechworks document is a PNG **and** a ZIP, at the same time. PNG readers stop at
`IEND`; ZIP readers scan backward for the central directory. Neither notices the other.

- **Double-click it** — Finder thumbnails it and Skechworks opens it. Rename it to
  `.png` and any image viewer on any OS shows you the cover page.
- **`unzip` it** — every page as SVG in `exports/`, the editable document as JSON in
  `pages/`, placed images in `assets/`.

Geometry is stored as SVG path data, so the document is readable with a text editor.
There is no step where you need this program to get your artwork back. That is the
entire point.

This is the Fireworks `.fw.png` trick, which nobody has shipped since Adobe killed
Fireworks in 2013.

**Double-clicking opens Skechworks**, while every other PNG on the machine still
belongs to Preview. LaunchServices resolves a file's type from the last extension
component only, so a `.sw.png` is a `public.png` and a third-party type cannot
outrank an Apple system type — the compound extension is registered but never wins.
The lever that does work is the per-file binding Finder writes for *Get Info > Open
With*: an extended attribute naming the handler. Skechworks stamped it on every file it
wrote, and `sw claim <file|dir>` re-applies it in bulk.

**Since 0.1.61 documents save as `.sw`**, an extension the app owns outright, so a new
document needs no binding at all. `.sw.png` files still open, a save moves one onto
`.sw`, and `sw rename <file|dir>` moves a whole library. Everything below is about
the `.sw.png` files that remain.

**A bound file must not carry `com.apple.quarantine`.** Gatekeeper assesses a
quarantined document that has a per-file handler, and a PNG cannot pass that — the
warning names the document, not the app, says Apple "could not verify ... is free of
malware", and offers to move it to the Trash. Signing and notarizing the app does not
change this; syspolicyd only looks at the document (confirmed 2026-09-05, macOS 26,
0.1.59 stapled in /Applications). Preview stamps quarantine on files it touches, so
this happens to real documents. Skechworks strips the flag from any file it binds or
opens as its own format, which means a challenged file is healed by opening it once
through File > Open, a drag onto the icon, or Open Recent. `xattr -d
com.apple.quarantine <file>` does the same by hand. `sw unclaim` removes the binding
if you ever need to.

Otherwise the binding degrades gracefully: extended attributes don't survive zipping,
email, or most upload round trips, and when it's lost the file just opens in Preview
again, which is what it did before.

**One caution:** the editable half lives in bytes appended after the PNG. Run the file
through an image optimizer, or re-save it from another image editor, and that half is
stripped — you keep the picture and lose the document. `sw verify` detects this.
