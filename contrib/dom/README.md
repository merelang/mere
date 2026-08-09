# contrib/dom — DOM bindings for browser-side Mere

`extern fn` declarations + a JS host glue that let Mere code drive the
DOM, talk to a server, and receive pushes, when compiled to Wasm and
loaded in a browser.

Started as the Phase 48 C2 frontend-FFI MVP (elements that already
exist, click and key input — enough for games and emulators). v0.1.152
added the groups a document-shaped app needs: building elements,
request/response, and server push.

## Files

| file | content | lines |
|---|---|---|
| `dom.mere` | `extern type JsRef;` + 22 `extern fn` declarations | ~150 |
| `dom.glue.js` | ES module exporting `makeDomGlue()` — the browser host implementation | ~330 |

## API

### Elements

| fn | signature | maps to |
|---|---|---|
| `dom_get_by_id` | `str -> JsRef` | `document.getElementById(id)` (returns handle 0 when not found) |
| `dom_create` | `str -> JsRef` | `document.createElement(tag)` — detached until appended |
| `dom_append` | `JsRef -> JsRef -> unit` | `parent.appendChild(child)` |
| `dom_set_text` | `JsRef -> str -> unit` | `element.textContent = ...` |
| `dom_set_attr` | `JsRef -> str -> str -> unit` | `element.setAttribute(name, value)` |
| `dom_set_value` | `JsRef -> str -> unit` | `input.value = ...` (a property, not an attribute) |
| `dom_input_value` | `JsRef -> str` | `element.value` |
| `dom_scroll_to_end` | `JsRef -> unit` | `el.scrollTop = el.scrollHeight` |

### Events

| fn | signature | maps to |
|---|---|---|
| `dom_on_click` | `JsRef -> (unit -> unit) -> unit` | `element.addEventListener("click", ...)` |
| `dom_on_submit` | `JsRef -> (unit -> unit) -> unit` | `"submit"`, with `preventDefault()` applied by the host |
| `dom_on_key` | `(str -> unit) -> unit` | `document.addEventListener("keydown", ...)`; passes the key name |
| `dom_on_frame` | `(unit -> unit) -> unit` | a `requestAnimationFrame` loop |
| `dom_key_held` | `int -> int` | polled key state for games (0-3 = d-pad, 4-7 = A/B/select/start) |

### Network

| fn | signature | maps to |
|---|---|---|
| `dom_fetch` | `str -> str -> str -> str` | blocking request (synchronous `XMLHttpRequest`); returns the body |
| `dom_fetch_async` | `str -> str -> str -> (str -> unit) -> unit` | `fetch(...)`; hands the body to a callback |
| `dom_fetch_status` | `unit -> int` | status of the most recently completed request |
| `dom_fetch_header` | `str -> str -> unit` | queue one header for the next request |
| `dom_sse` | `str -> (str -> unit) -> (str -> unit) -> unit` | `new EventSource(url)` — on-message, on-state (`"open"` / `"error"`) |

Requests are offered in both a blocking and a callback shape
deliberately. `dom_fetch` mirrors the native `http_fetch` /
`http_fetch_status` pair exactly, so the same logic reads the same on
both sides — at the cost of freezing the UI thread for the round trip.
`dom_fetch_async` costs a closure and gains a responsive page. Push has
no blocking form at all: `dom_sse` is a callback in every design.

### Canvas / audio / ROM

| fn | signature | maps to |
|---|---|---|
| `dom_canvas_fill_style` | `JsRef -> str -> unit` | `ctx.fillStyle = ...` |
| `dom_canvas_fill_rect` | `JsRef -> int -> int -> int -> int -> unit` | `ctx.fillRect(x, y, w, h)` |
| `dom_audio_tone` | `int -> int -> int -> unit` | one Web Audio oscillator channel (chan, freq, vol 0..15) |
| `dom_rom_size` / `dom_rom_byte` | `int -> int` | host-held cartridge bytes, served one at a time |
| `dom_tz_offset` | `unit -> int` | minutes to add to UTC for the viewer's local clock |

## Testing without a browser

`scripts/run_dom_headless.mjs` instantiates a `mere -w` module against
this glue under Node, with a small DOM plus `fetch` / synchronous XHR /
`EventSource`, and prints the element tree the program built:

```sh
node scripts/run_dom_headless.mjs examples/chat/app.wasm \
  http://localhost:8080 --set text=hello --fire compose:submit
```

Elements are created on demand, so any id the program asks for works
without a page fixture.

## Usage

### Mere side

```mere
import "contrib/dom/dom.mere";

let display = dom_get_by_id "count" in
let btn = dom_get_by_id "tick" in
let _ = dom_on_click btn (fn (u: unit) ->
  dom_set_text display "tick!"
) in
0
```

### Build

```sh
mere -w app.mere > app.wat
wat2wasm --enable-tail-call app.wat -o app.wasm
```

The compiler emits `return_call` for tail positions, so `--enable-tail-call`
is required. Browsers have shipped the proposal since Chrome 112 /
Firefox 121 / Safari 18.2.

### HTML side

```html
<!DOCTYPE html>
<html>
<body>
  <button id="tick">Click me</button>
  <div id="count">…</div>

  <script type="module">
    import { makeDomGlue } from "./contrib/dom/dom.glue.js";

    const wasmBytes = await fetch("./app.wasm").then(r => r.arrayBuffer());
    const { glue, attach } = makeDomGlue();
    const { instance } = await WebAssembly.instantiate(wasmBytes, {
      env: {
        ...glue,
        puts: (ptr) => { /* optional: forward to console.log */ },
      }
    });
    attach(instance);
    instance.exports.main();
  </script>
</body>
</html>
```

The split between `glue` (passed to `instantiate` before the module
exists) and `attach(instance)` (called after) is forced by the order of
Wasm instantiation — `env` imports must be ready before the instance,
but the glue needs the instance's `memory` + exported function table to
do anything.

## How it works

- `JsRef` opaque type lowers to `i32` in Wasm. The host glue maintains
  a `handles` array; the i32 is an index into that array. Handle `0` is
  reserved as a "null" sentinel.
- Strings cross the boundary via Wasm's linear memory:
  - **Mere → JS** (e.g. `dom_set_text` argument): JS reads a
    null-terminated UTF-8 byte sequence at the given offset.
  - **JS → Mere** (e.g. `dom_input_value` return): JS allocates on the
    Mere heap by advancing the exported `__lang_bump` global, writing
    the `[i32 len][bytes][NUL]` layout a Mere `str` requires, and
    returns a pointer to byte0. Host strings are therefore stable for
    the lifetime of the page — but the arena has no free, so a
    long-lived stream of them grows linear memory monotonically.
- `dom_on_click` takes a Mere closure as `(unit -> unit)`, which in
  Wasm is an `i32` pointer to a `{ env, fn_idx }` record. The glue
  reads both words and dispatches through the exported
  `__indirect_function_table`. The closure's captured env lives in
  Mere's bump arena, so it survives for the lifetime of the page.

## Limitations

- **No node removal or replacement**: elements can be created and
  appended but not detached, so a list can only grow. Add
  `dom_remove` + a glue entry when an app actually needs it.
- **No `input` / `change` / `blur` events**: `click`, `submit`, `keydown`
  and the animation frame are wired; the rest follow the same shape.
- **Single global handle table**: handles are never freed. An app that
  creates many ephemeral elements leaks entries; wiring handlers at
  startup and appending steadily (a chat log) is fine.
- **Arena-only host strings**: every string the host hands to Mere is
  permanent, so a page that runs for days accumulates them.
- **No VDOM**: diffing and component structure belong in userland on
  top of these primitives, not in the bindings.

## Position

Stage 2 contrib (incubation), part of the Phase 48 frontend MVP. See
[contrib/README.md](../README.md) for the lifecycle. Graduation target
is `mere-dom` (separate repo, after pkg manager lands), at which point
the lib will likely also gain `mere-vdom` / `mere-events` siblings.
