# Design notes, CLI and verification

## The app

```
./bin/build          # generate the Xcode project, build Release, re-sign
open build/Build/Products/Release/Skechworks.app
```

A viewer, for now: open an `.sw.png` (or a `.sketch` directly), browse pages,
inspect the layer tree, click the canvas to select a layer, export one page or all
pages as SVG. Zoom and pan with the trackpad.

The canvas draws through the same `Renderer.draw(page:in:)` the exporter uses, so what
is on screen and what lands in the SVG cannot drift apart.

Note `bin/build` re-signs the whole bundle in one pass at the end. Without that,
xcodebuild gives the app and the embedded `SkechworksCore.framework` separate ad-hoc
identities and dyld refuses to load the framework with "different Team IDs".

## Usage

```
sw info    <file.sketch>                    # what's in it
sw svg     <file.sketch> [-o dir]           # every page as SVG
sw png     <file.sketch> [-o dir] [--size]  # every page as PNG
sw convert <file.sketch> [-o out] [--cover N]
sw verify  <file.sw.png>                # prove both halves are intact
```

## Status

Verified against the real corpus: **62/62 TAM `.sketch` files converted, 172 pages,
172 SVG exports, zero failures.** All 62 pass `verify` as both PNG and ZIP. The
converted library holds **1,163 text layers — exactly the count an independent audit
of the raw `.sketch` files found**, so nothing is being dropped in translation.

Rendering is checked against Sketch's own embedded `previews/preview.png` as an
oracle. On the moon-phases coin, after eroding antialiased edges, **2 pixels differ
out of 250,000** — the geometry is exact and the residual is rasterizer antialiasing.

`sw roundtrip` writes a document, reads it back, renders both and diffs: worst
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
  writer both consume it, so the preview and the exported file cannot disagree.
- **Text is always outlined.** An exported SVG should look identical on a machine
  that has never heard of your fonts.

## Build

```
swift build -c release
swift test
```

Requires macOS 13+ (that's where the `CGPath` booleans land).


## Local-first constraints

The homepage promises local-first behaviour. The app must keep these true:

- No license check or account ping on launch.
- The credit balance is only touched when a credit-backed AI call actually runs.
- Acceptance test: with a funded account, pull the network and confirm the app is
  identical minus AI menu items.
