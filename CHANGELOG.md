# Changelog

Short notes on every release. Also published at [accomplice.ai/whats-new](https://accomplice.ai/whats-new).

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
