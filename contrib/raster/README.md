# contrib/raster — drawing into pixels (Mere implementation)

Enough of a 2D rasterizer to draw a page: a pixel buffer, source-over
compositing, and one antialiased polygon fill that everything else is expressed
in terms of.

**Nothing here opens a window**, and that is the point. A browser's job is to turn
a document into pixels; checking that it did so correctly means comparing those
pixels with a reference, which needs no display. A window is for interaction and
comes later.

## Files

| file | exports | lines |
|---|---|---|
| `canvas.mere` | `type canvas`, `type clip`, `module Canvas { new_, clear, rgba, get, set, blend, fill_rect, full_clip, clip_of, clip_intersect, to_ppm, to_ascii }` | ~200 |
| `path.mere` | `type point`, `module Path { pt, quad_to, cubic_to, fill, stroke, stroke_segment }` | ~230 |

## Usage

```
import "contrib/raster/path.mere";

let c = Canvas.new_ 64 48;
let _ = Canvas.clear c (Canvas.rgba 255 255 255 255);
let cl = Canvas.full_clip c;
let _ = Canvas.fill_rect c cl 8 8 16 12 (Canvas.rgba 255 0 0 255);
let tri = Cons (Path.pt 2.0 2.0, Cons (Path.pt 30.0 6.0, Cons (Path.pt 8.0 24.0, Nil)));
let _ = Path.fill c cl (Cons (tri, Nil)) (Canvas.rgba 0 0 0 255) false;
write_bytes "out.ppm" (Canvas.to_ppm c (Canvas.rgba 255 255 255 255))
```

## Premultiplied alpha

A colour is one int, `0xRRGGBBAA`, **premultiplied**. That is a decision rather
than a detail: with straight alpha, source-over needs a division per channel and
stops being associative once you composite twice. Premultiplied makes it

```
out = src + dst * (255 - src_alpha) / 255
```

on every channel including alpha — no division by the result, no special case for
a transparent destination. The cost is one multiply in `rgba` on the way in and one
divide in `to_ppm` on the way out, both in one place.

`a * b / 255` is rounded and **exact at both ends**: `255 * 255` must give 255 and
not 256. The obvious `(t + t/255)/255` gives 256 there, which overflows the byte
into the next channel of the packed colour — the first smoke test drew an opaque
black canvas instead of a white one, which is how that got caught immediately
rather than as a subtle tint later.

**Coverage is separate from alpha and multiplies it.** The rasterizer says "this
pixel is 40% inside the shape", the colour says "the shape is 50% opaque", and the
two compose in `blend`. Keeping them apart is what lets one blend serve both
antialiasing and translucency, and the parity test asserts that coverage 128 with
a solid colour and coverage 255 with a half-alpha colour land on the same pixel
value.

## Coverage, not sampling

`Path.fill` cuts each pixel row into `sub` horizontal slices. For each slice it
intersects the polygon edges, sorts the crossings, and adds the spans between them
to a per-pixel accumulator — **exactly in x**. A vertical edge at x = 3.25 puts 75%
into pixel 3 and nothing into pixel 2; only y is quantized. That is much better
than point-sampling a grid for the same cost, because the horizontal term is
closed-form rather than counted.

Winding is non-zero by default and even-odd on request: a glyph with a counter
needs non-zero, and the parity test fills the same five-pointed star both ways to
show the difference (non-zero fills the middle, even-odd leaves it hollow).

Curves are flattened by recursive subdivision to a flatness tolerance — the
standard answer, and it needs no arc-length arithmetic. A stroke is the fill of an
outline, so there is one rasterizer rather than two; caps are butt and there are no
joins yet, which is enough for a border or a rule.

**Geometry is float and coverage is integer**, and that was measured rather than
assumed: doubles print identically on interp, C and Wasm (`1/3`, `sqrt 2`,
`0.1 + 0.2`), so float geometry costs no determinism, while an integer accumulator
cannot drift.

## How this is checked

`test/parity/raster.mere` renders each case as **ASCII art** — one character per
pixel from a ramp — and holds the backends to the same output. A difference reads
as a shape rather than as a changed digest, and antialiasing shows up as the
gradient it is. The corpus covers the blend itself, rectangles, clipping,
off-canvas geometry, fractional-coordinate edges, both winding rules, a square
with a hole, quadratic and cubic curves, strokes, and the degenerate input a
layout engine will eventually hand it (empty path lists, two-point "polygons",
zero-length segments).

## Which backends this runs on

**interp and C.** The framebuffer is a `ByteBuf`, which the LLVM and Wasm backends
do not have — they refuse `bytebuf_new` at emit time, so the parity harness records
them as `UNSUP` rather than as failures. C is the backend a native renderer targets,
and the interpreter is an independent second implementation, so the gate still
compares two.

Worth knowing if you go looking: a bare `bytebuf_new` on the LLVM backend reports
`unsupported LLVM codegen type element: 'a` rather than naming the builtin, while
the same call inside a record correctly says `unbound variable: bytebuf_new`. Same
missing feature, two messages, one of them meaningless.

## Not here yet

- **Joins and caps** beyond butt: round and mitre joins are outline construction
  rather than a new primitive.
- **A PNG encoder.** `to_ppm` exists so that `contrib/raster` is testable without
  depending on one.
- **Transforms.** A matrix applied to points before filling, which is where a
  layout engine's scroll offset and zoom belong.
- **Clipping to a path** rather than to a rectangle.
