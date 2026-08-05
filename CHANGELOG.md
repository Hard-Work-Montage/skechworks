# Changelog

Short notes on every release. Also published at [accomplice.ai/whats-new](https://accomplice.ai/whats-new).

## 0.4.5 (August 4, 2026)

- Arrow keys nudge the layer you picked in the layer list.
- Shift-cmd-click steps down through overlapping layers, wrapping at the bottom.

## 0.4.4 (August 4, 2026)

- Shift erases in a straight line, snapped to 45-degree headings.

## 0.4.3 (August 4, 2026)

- The drop decides the parent: drag a layer fully out of its artboard and it lands on the canvas, drop it on another board and it moves in.

## 0.4.2 (August 4, 2026)

- The W/H padlock: aspect ratio locked by default, and shift inverts the mode mid-drag. An unlocked layer constrains while shift is held.
- A group's selection box measures everything it paints — bitmaps included, not just the vector children.

## 0.4.1 (August 4, 2026)

- Click what you see: art an artboard clips away can't be selected, right-clicked or marqueed from a neighboring panel.
- A lone layer inside an artboard aligns to the board — align-left hugs the board's left edge.
- The align icons live in the Properties panel now, with Flip Horizontal and Flip Vertical beside them and in the Arrange menu. Chat can flip too.
- Remove and Vectorize sit under an AI Tools section in the Tools menu.
- The app icon renders full-size on macOS Tahoe.
- Fixed: downloads could be rejected as unverified on Macs other than the one that built them.

## 0.4 (August 4, 2026)

- Autosave: unsaved work survives a quit, crash, or kill, and comes back on launch.
- Paste lands in the tab you're looking at, not whichever opened last.
- Paste at Selection (shift-cmd-V): the copy lands exactly on the selection's top-left.

## 0.3 (August 4, 2026)

- Big files feel fast. The canvas keeps a rendered copy of the artwork and reuses it between edits, and redraws only touch what's on screen. A 5,000-path SVG now selects, hovers and marquees without a spinner.
- Artboards are picked on purpose: click the name label or the layer list. Select All gathers the artwork, never the boards themselves.
- Pasting can no longer drop a copied artboard inside another one and plate over its contents.
- Chat: "make every layer white" now works however the reply spells the color.
- Fixed: signing in to Accomplice could land you back on the sign-in button even after pressing Allow. The token is now stored, verified, and a real storage failure says so out loud.
- `acmplc bench` accepts an .svg, so you can measure what a big file costs before opening it.

## 0.2.1 (August 3, 2026)

- Fixed: opening a .sketch file showed blank pages. A .sketch is also a zip, and the importer was swallowing it as an empty document instead of handing it to the Sketch reader.
- Sketch artboards arrive as the white cards Sketch draws, not artwork floating on the dark canvas. Exports still come out transparent unless Sketch would have included the background.
- Sketch Frames (the artboard replacement in newer Sketch) import as artboards: card color, name label, and panels that clip their contents.

## 0.2 (August 3, 2026)

- Remove: drag a box over anything in a photo and it gets painted out, the gap filled from its surroundings. Accomplice reads the picture and works out what you meant.
- Vectorize: a bitmap goes out, editable paths come back, sitting exactly where the image was.
- Bitmap editing: crop, brightness, contrast, saturation, and an eraser that never destroys a pixel.
- Sign in from Settings and see your credit balance.
- Insert an artboard around the current selection.
- Plain PNGs and JPEGs open straight into a document.
- Paste lands in the selected artboard and keeps its stacking order.
- A marquee inside an artboard selects the art, not the board.
- Group gathers a selection that spans containers.
- SVG export drops the hairline slivers boolean sweeps leave behind.
- Saved files carry only the assets the artwork still uses.
- Fixed: a sign-in crash, erase strokes landing away from the brush, and masked groups reporting bounds their mask hides.

## 0.1 (July 30, 2026)

- First public release. Pages, artboards, a pen tool with real point editing, boolean shapes, curved text, Sketch import, SVG in and out.
- Files are .acmplc.png: a real PNG any app can preview, with the editable document riding inside.
