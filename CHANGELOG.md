# Changelog

Short notes on every release. Also published at [accomplice.ai/whats-new](https://accomplice.ai/whats-new).

## 0.1.14 (August 5, 2026)

- Text wraps inside its box. A sentence used to run straight off the layer however narrow the box was drawn.
- Editing text happens in place: the words you type sit where the artwork sits, in its own face and colour, instead of a white field laid over the top.
- New text arrives with its aspect ratio unlocked, and the padlock is gone from the inspector for text. A text box is resized to change where the copy wraps, never to stretch the letters.
- Line height is a multiplier now: 1 is single spaced and the default, 2 is airy, 0 packs the lines together. Files written before this still lay out the same.
- Fixed: arrow keys stopped nudging the selection on the canvas in 0.1.12, when the tool keys moved off the menus and began swallowing every arrow press on their way past.
- Fixed: nudging or dragging a layer inside a flipped group moved it the wrong way. A frame lives in its container's space, so the direction you asked for is mapped through the container first. Rotated groups behave too.
- Fixed: editing text on canvas showed two sets of words, the old ones ghosting a line below what you typed.

## 0.1.13 (August 5, 2026)

- Every number field steps with the arrow keys: 1 at a time, 10 with shift. Position, size, angle, radius, font size, kern, line height, shadow offsets, brush size, color channels and border width all behave the same way.
- New rectangles arrive with their aspect ratio unlocked, ready to stretch into a panel or a band. Circles, images and shapes keep the padlock on.

## 0.1.12 (August 5, 2026)

- Renaming a layer in the layer list works: double-click, type, Enter.
- The tool keys (R, O, T, P, V, E) only fire when the canvas has focus. They no longer interrupt you while you are typing a layer name, a color value, or a message.
- Fixed: selecting a text layer stretched the inspector wide enough to squeeze the canvas.

## 0.1.11 (August 5, 2026)

- Perspective for images: hold command and drag a corner handle, and that corner follows the pointer. Right-click offers Flatten Distort. Chat and connected tools can set it precisely with the distort command.
- Double-click a bitmap to select pixels, Fireworks style: drag a box, copy it, or paste over it.
- Paste puts the copy on whatever you have selected, centered and stacked directly above it.
- Thin lines are clickable along their stroke, not just inside a fill they don't have.
- Escape keeps a drawn line instead of discarding it. A single stranded point still gets dropped.
- Erased areas stay put through resizes and perspective warps.
- The font menu shows every family in its own face.
- Launch opens exactly the windows it needs, with no spare untitled tab.
- Quitting can no longer lose recent work: every unsaved document snapshots before the app exits, a stale snapshot can never hide a newer save, and opening a file that is already open focuses its tab instead of duplicating it.
- Connected tools can place an image file straight onto a named artboard.

## 0.1.10 (August 4, 2026)

- Quit with files open, launch with the same files open.
- The eraser edits the layer you selected, not whatever sits on top.
- Erasing happens live under the brush instead of on release.

## 0.1.9 (August 4, 2026)

- Arrow keys nudge the layer you picked in the layer list.
- Shift-cmd-click steps down through overlapping layers, wrapping at the bottom.

## 0.1.8 (August 4, 2026)

- Shift erases in a straight line, snapped to 45-degree headings.

## 0.1.7 (August 4, 2026)

- The drop decides the parent: drag a layer fully out of its artboard and it lands on the canvas, drop it on another board and it moves in.

## 0.1.6 (August 4, 2026)

- The W/H padlock: aspect ratio locked by default, and shift inverts the mode mid-drag. An unlocked layer constrains while shift is held.
- A group's selection box measures everything it paints — bitmaps included, not just the vector children.

## 0.1.5 (August 4, 2026)

- Click what you see: art an artboard clips away can't be selected, right-clicked or marqueed from a neighboring panel.
- A lone layer inside an artboard aligns to the board — align-left hugs the board's left edge.
- The align icons live in the Properties panel now, with Flip Horizontal and Flip Vertical beside them and in the Arrange menu. Chat can flip too.
- Remove and Vectorize sit under an AI Tools section in the Tools menu.
- The app icon renders full-size on macOS Tahoe.
- Fixed: downloads could be rejected as unverified on Macs other than the one that built them.

## 0.1.4 (August 4, 2026)

- Autosave: unsaved work survives a quit, crash, or kill, and comes back on launch.
- Paste lands in the tab you're looking at, not whichever opened last.
- Paste at Selection (shift-cmd-V): the copy lands exactly on the selection's top-left.

## 0.1.3 (August 4, 2026)

- Big files feel fast. The canvas keeps a rendered copy of the artwork and reuses it between edits, and redraws only touch what's on screen. A 5,000-path SVG now selects, hovers and marquees without a spinner.
- Artboards are picked on purpose: click the name label or the layer list. Select All gathers the artwork, never the boards themselves.
- Pasting can no longer drop a copied artboard inside another one and plate over its contents.
- Chat: "make every layer white" now works however the reply spells the color.
- Fixed: signing in to Accomplice could land you back on the sign-in button even after pressing Allow. The token is now stored, verified, and a real storage failure says so out loud.
- `acmplc bench` accepts an .svg, so you can measure what a big file costs before opening it.

## 0.1.2 (August 3, 2026)

- Fixed: opening a .sketch file showed blank pages. A .sketch is also a zip, and the importer was swallowing it as an empty document instead of handing it to the Sketch reader.
- Sketch artboards arrive as the white cards Sketch draws, not artwork floating on the dark canvas. Exports still come out transparent unless Sketch would have included the background.
- Sketch Frames (the artboard replacement in newer Sketch) import as artboards: card color, name label, and panels that clip their contents.

## 0.1.1 (August 3, 2026)

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
