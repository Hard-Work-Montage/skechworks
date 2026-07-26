# Accomplice

A bitmap + vector design tool for macOS, in the spirit of Fireworks. Local, no
subscription, no cloud, no account.

This repo currently contains **the liberator** — the piece that comes first, because
insurance should not wait on an editor.

## Why

240 of the 393 `.sketch` files on this machine are already unreadable by any modern
tool: 209 in the old Sketch 2/3 bundle format, 31 in the SQLite format Sketch used
before that. All dated 2013–2017. Design tools orphan their formats, and the work
goes with them.

Sketch itself is alive and shipping, but its roadmap is Variants, Sections, Stacks
and Slack integration — component-system features for product-design teams. There is
nothing on it about vector editing, bitmap editing, or export. The risk was never
that Sketch dies. It's that it keeps working for a decade while never again shipping
anything this workflow needs.

## The format: `.acmplc.png`

An Accomplice document is a PNG **and** a ZIP, at the same time. PNG readers stop at
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

**Double-clicking opens Accomplice**, while every other PNG on the machine still
belongs to Preview. LaunchServices resolves a file's type from the last extension
component only, so a `.acmplc.png` is a `public.png` and a third-party type cannot
outrank an Apple system type — the compound extension is registered but never wins.
The lever that does work is the per-file binding Finder writes for *Get Info > Open
With*: an extended attribute naming the handler. Accomplice stamps it on every file it
writes, and `acmplc claim <file|dir>` re-applies it in bulk.

That binding is a pure enhancement. Extended attributes don't survive zipping, email,
or most upload round trips; when it's lost the file just opens in Preview again, which
is what it did before. Nothing breaks.

**One caution:** the editable half lives in bytes appended after the PNG. Run the file
through an image optimizer, or re-save it from another image editor, and that half is
stripped — you keep the picture and lose the document. `acmplc verify` detects this.

## The app

```
./bin/build          # generate the Xcode project, build Release, re-sign
open build/Build/Products/Release/Accomplice.app
```

A viewer, for now: open an `.acmplc.png` (or a `.sketch` directly), browse pages,
inspect the layer tree, click the canvas to select a layer, export one page or all
pages as SVG. Zoom and pan with the trackpad.

The canvas draws through the same `Renderer.draw(page:in:)` the exporter uses, so what
is on screen and what lands in the SVG cannot drift apart.

Note `bin/build` re-signs the whole bundle in one pass at the end. Without that,
xcodebuild gives the app and the embedded `AccompliceCore.framework` separate ad-hoc
identities and dyld refuses to load the framework with "different Team IDs".

## Usage

```
acmplc info    <file.sketch>                    # what's in it
acmplc svg     <file.sketch> [-o dir]           # every page as SVG
acmplc png     <file.sketch> [-o dir] [--size]  # every page as PNG
acmplc convert <file.sketch> [-o out] [--cover N]
acmplc verify  <file.acmplc.png>                # prove both halves are intact
```

## Status

Verified against the real corpus: **62/62 TAM `.sketch` files converted, 172 pages,
172 SVG exports, zero failures.** All 62 pass `verify` as both PNG and ZIP. The
converted library holds **1,163 text layers — exactly the count an independent audit
of the raw `.sketch` files found**, so nothing is being dropped in translation.

Rendering is checked against Sketch's own embedded `previews/preview.png` as an
oracle. On the moon-phases coin, after eroding antialiased edges, **2 pixels differ
out of 250,000** — the geometry is exact and the residual is rasterizer antialiasing.

`acmplc roundtrip` writes a document, reads it back, renders both and diffs: worst
byte difference **0.07–0.15%** across lighthouse / moon phases / bear.

Size is honest: the converted library is **0.96× the size of the original `.sketch`
files**, and 97% of it is the placed bitmaps themselves. Zero orphaned assets — every
stored image is referenced by a layer.

Supported: multi-page documents, bezier paths, ovals/rectangles, groups, boolean ops
(union/subtract/intersect/difference), solid and gradient fills, borders with
inside/center/outside position and dashes, shadows, clipping masks, text (outlined via
CoreText), placed bitmaps.

Deliberately not supported: symbols, shared styles, libraries, prototyping, Smart
Layout, resizing constraints. An audit of the corpus found zero usage of any of them.

## Design notes

- **Zero dependencies.** A tool whose job is outliving other software should not
  inherit anyone else's supply chain. The ZIP reader/writer is hand-rolled against
  `Compression.framework`.
- **CoreGraphics does the hard math.** macOS 13 added curve-preserving boolean ops on
  `CGPath` (`union`, `subtracting`, `intersection`, `symmetricDifference`). Path
  booleans are the one genuinely difficult piece of a vector editor, and Apple ships it.
- **One compositor.** `Compose` resolves geometry once; the rasterizer and the SVG
  writer both consume it, so the preview and the engraving file cannot disagree.
- **Text is always outlined.** The output goes to a laser cutter, where a live `<text>`
  element is a liability.

## Build

```
swift build -c release
swift test
```

Requires macOS 13+ (that's where the `CGPath` booleans land).
