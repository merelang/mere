# contrib/window — a window, its pixels, and its input

The other half of [`contrib/raster`](../raster/README.md). That one turns a document
into pixels and deliberately opens nothing; this one puts pixels on a screen and
takes keys and clicks back. **A window is for interaction** — checking that a page
was drawn correctly is a comparison against reference pixels, and needs no display.

```
import "contrib/window/window.mere";

match Window.open_ 640 480 "mere" with
| None -> print "no display"
| Some win ->
  let c = Canvas.new_ 640 480 in
  let _ = Canvas.clear c (Canvas.rgba 255 255 255 255) in
  let _ = Path.fill c (Canvas.full_clip c) shape black false in
  let _ = Window.show win c (Canvas.rgba 255 255 255 255) in
  match Window.poll 16 with
  | Quit -> Window.close win
  | KeyDown k -> ...
```

## What it is

| name | type | notes |
|---|---|---|
| `Window.open_` | `int -> int -> str -> window option` | `None` when there is no display, no SDL, or eight windows are already open |
| `Window.size` | `window -> (int * int)` | the **renderer's** size — see below |
| `Window.show` | `window -> canvas -> int -> bool` | composite over a background and present |
| `Window.capture` | `window -> canvas option` | the window's pixels, read back |
| `Window.poll` | `int -> event` | one event or `Nothing`; the argument is a timeout in ms |
| `Window.close` | `window -> bool` | |

`event` is `Nothing | Quit | KeyDown of int | KeyUp of int | MouseDown of (int*int) |
MouseUp of (int*int) | MouseMove of (int*int) | Resized of (int*int)`. A key is an
SDL keycode.

## C backend only

The runtime is SDL2, emitted by the C backend when a program declares a `win_*`
extern — the same conditional treatment PortMidi gets. Build with

```
mere -c app.mere > app.c
clang -O2 $(sdl2-config --cflags) app.c -o app $(sdl2-config --libs) -lm
```

The other three backends have no window and are not meant to: the browser has the
DOM, and the bare-metal backend has a framebuffer.

**Nothing here needed a language feature.** Pixels cross the boundary as a flat
arena offset and everything else is an int, which is the contract the socket family
established years earlier. The probe that established this was four `extern fn`
lines and no compiler change at all.

## `size` asks the renderer, not the window

They are different numbers on a HiDPI display: a 640×480 window has a 1280×960
renderer, and the pixels are in the second one. A capability that reported the
window's size would hand out a number the pixels are not in — which is exactly how
the first readback comparison went wrong when this was a probe. `Window.size`
returns `SDL_GetRendererOutputSize`, and `capture` uses it.

## How this is checked, without a display

`scripts/window_check.sh` draws a known pattern with `contrib/raster`, shows it,
reads the window's pixels back, and compares: 3072 pixels, 0 mismatches. It runs
under SDL's `dummy` video driver, which has a software renderer and a real event
queue but no display, so it works in CI and does not open a window on your desktop.

**The readback is only evidence because `capture` poisons the pixel block first.**
`show` wrote the image into that same block, so a readback that did nothing would
hand back exactly what was written and every pixel would match — a gate that passes
without testing anything. With the poison, a no-op readback shows up as 3072 of 3072
pixels differing, which is how that was checked.

## Pixels

One pixel per four bytes, `0xAARRGGBB` written big-endian — so ARGB in memory
order, which is `SDL_PIXELFORMAT_ARGB32`, the byte-order alias rather than the
packed one. `Window.show` does the conversion from a `canvas` (whose bytes are
premultiplied RGBA) with the same source-over arithmetic as `Canvas.to_ppm`, so the
window and a saved file agree by construction.

## Not here yet

- **Event delivery is not gated.** `poll` is checked only for answering `Nothing` on
  an empty queue: delivering a real key or click needs either a display or a way to
  inject one, and a test-only extern that pushes events would be checking the
  scaffolding rather than the capability.
- **One texture per window, recreated when the size changes.** Fine for a full-frame
  blit, wrong for partial updates.
- **No text input, clipboard, cursor, or window title changes after open.**
- **No resize handling beyond reporting it**: `Resized` arrives, and the program is
  responsible for making a new canvas.
