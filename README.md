<p align="center">
  <img src="site/logo.png" alt="Accomplice" width="96">
</p>

<p align="center">
  Bitmap and vector, back together. A fast, local design tool for the Mac,<br>
  in the lineage of Fireworks and early Sketch.
</p>

<p align="center">
  <a href="https://accomplice.ai">accomplice.ai</a>&nbsp; • &nbsp;
  <a href="https://accomplice.ai/download">Download for Mac</a>&nbsp; • &nbsp;
  3 MB&nbsp; • &nbsp;macOS 14+&nbsp; • &nbsp;MIT
</p>

---

<p align="center">
  <img src="site/hero.png" alt="Accomplice: four artboards of a logo in different colours, with the layer list, inspector and built-in chat." width="840">
</p>

## Why I built Accomplice

One evening I checked my oldest design files. 240 of the 393 `.sketch` files on my
machine no longer open — formats Sketch itself walked away from. The work didn't wear
out. The software left.

It had happened to me before. I used Fireworks religiously until Adobe killed it in
2013, and nothing since has wanted to be what it was: one person, one file, pixels
and paths in the same canvas, assets out the door by lunch.

Accomplice is how I make sure neither eviction happens again. It's a 3 MB native Mac
app with no account, no subscription, and no telemetry — and every document is a PNG
with its own source riding inside, so even if this app disappears, `unzip` gets your
artwork back as plain SVG. The escape hatch is the file format.

## Quick start

Grab the [signed, notarized build](https://accomplice.ai/download) — unzip, drop in
Applications, open. Or build it yourself:

```bash
git clone https://github.com/adamhowell/accomplice.git
cd accomplice
./bin/build
open build/Build/Products/Release/Accomplice.app
```

## What it does

- **Pen tool with live booleans** — subtract a shape and both parts stay editable;
  double-click straight into a combined shape, even into the holes it cut
- **Auto Shapes** — stars and polygons that remember their recipe; change 7 points
  to 5 and the shape re-draws
- **Text on circles**, for badges and coins, with every text property live
- **Quick photo work** — crop, brightness/contrast/saturation, marquee and brush
  erase, all non-destructive; the pixels underneath are never touched
- **Reads your old `.sketch` files** — verified pixel-for-pixel against Sketch's own
  render on a 62-file corpus
- **Export as a first-class workflow** — SVG, PNG, JPG at 1–3×, from the inspector,
  drawn by the same code as the canvas so they can never disagree

## The accomplice

There's an assistant in the corner of the window, and it's only allowed to do the
work you were never going to enjoy:

> rename these forty layers
> reorder the layer list to match the canvas
> make every black fill our brand blue
> swap the headline on all six artboards

It runs against a model on your own machine (Ollama works out of the box) or an API
key you own. It never touches the canvas unless you ask, every change lands as one
ordinary undo step you can inspect and revert, and your files are never used to
train anything. Nothing leaves the room.

An accomplice does the part you didn't want to do, and never asks for credit.

## The format

An `.acmplc.png` is a PNG **and** a ZIP at the same time — the Fireworks `.fw.png`
trick, which nobody has shipped since 2013. Finder thumbnails it, Preview opens it,
and `unzip` produces every page as SVG, the document as readable JSON, and the
placed images. There is no step where you need this program to get your artwork
back. Details in [docs/format.md](docs/format.md).

## Design notes

Zero dependencies — a tool whose job is outliving other software shouldn't inherit
anyone's supply chain. CoreGraphics does the hard math (macOS ships curve-preserving
path booleans). One compositor feeds both the canvas and the exporter. Text is
always outlined, because laser cutters don't have fonts. More in
[docs/design-notes.md](docs/design-notes.md).

## License

[MIT](LICENSE). If this project ever stops, fork it — the build instructions above
are the whole ceremony.
