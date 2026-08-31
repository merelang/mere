# contrib/font — a TrueType file, as widths and outlines

What a renderer has to know before it can put a line of text anywhere, and what
it has to know before it can draw one. Nothing here opens a window and nothing
here is about the web: it reads a font file and answers two questions.

**Metrics first, outlines after, and the order is the point.** Four tables answer
everything a box needs — how tall a line is and how wide a string is — and the
curves in `glyf` answer neither. A bug in one can never be mistaken for a bug in
the other.

## Files

| file | exports | lines |
|---|---|---|
| `font.mere` | `type font`, `module Font { load, glyph, kern, advance, line_height, codepoint, text_units, text_units_of_px, scale, text_width, segments_str, raster_str, coverage_str, text_raster, glyph_quads, quads_cover, outline_str }` | ~780 |

`font.mere` imports nothing. It takes bytes and returns numbers and curves.

## Usage

```
import "contrib/font/font.mere";

let f = Font.load "NotoSans-Regular.ttf";
let w = Font.text_width f "Hello" 16;          // pixels, at 16px
let g = Font.glyph f (Font.codepoint "A");     // a code point to a glyph index
let qs = Font.glyph_quads f g;                 // its outline, as quadratics
Font.quads_cover qs x y                        // is this point inside the glyph
```

`text_raster` renders a whole string to ASCII art, which is what the gates
compare: a raster is a thing another program can check, and a screenshot is not.

## What it reads, and what it does not

| | |
|---|---|
| outlines | `glyf` / `loca` only — a CFF font (`.otf`, and most of macOS's Japanese faces) has no outlines here |
| character map | `cmap` format 4 only, so code points above U+FFFF map to glyph 0 |
| kerning | `GPOS` pair adjustment |
| collections | none — a `.ttc` has a `ttcf` header before the table directory and is not opened |
| variations | none — `gvar` is not read, so a variable font draws at whatever its `fvar` default is, which is frequently the **lightest** master rather than the regular one |

The last one is worth saying out loud because it fails quietly: a variable font
satisfies every condition above and still comes out thin, and no error says so.

## Backends

interp, C and RV32I take this file. **Wasm and LLVM do not**, both inside the
contour walker in `_points`, and with different symptoms — the Wasm backend
cannot see an inner-lifted capture (`os`), the LLVM backend an inner binding
(`ends`). Neither is caused by anything here; they are the two backends' MVP
limits on inner-lifted functions meeting the most nested code in the tree. So
there is no `bootstrap_wat_ok` entry for this module, and its absence is a fact
about the backends rather than an oversight.

## Where the gates are

The oracles are somebody else's numbers: a browser's `measureText` over the same
font file for the metrics, and its glyph geometry for the outlines. They live
with the consumer that has the browser to compare against
([mbrowse](https://github.com/284km/mbrowse), `scripts/font_check.sh` and
`scripts/glyf_check.sh`) rather than here, because a metrics reader that agrees
with a tool nobody uses has agreed with nothing.
