# contrib/dom — minimal DOM bindings for browser-side Mere

Five `extern fn` declarations + a JS host glue that lets Mere code
manipulate DOM elements when compiled to Wasm and loaded in a browser.

This is the user-facing layer of the Phase 48 C2 frontend-FFI MVP.

## Files

| file | content | lines |
|---|---|---|
| `dom.mere` | `extern type JsRef;` + 5 `extern fn` declarations | ~30 |
| `dom.glue.js` | ES module exporting `makeDomGlue()` — the browser host implementation | ~100 |

## API

| fn | signature | maps to |
|---|---|---|
| `dom_get_by_id` | `str -> JsRef` | `document.getElementById(id)` (returns handle 0 when not found) |
| `dom_set_text` | `JsRef -> str -> unit` | `element.textContent = ...` |
| `dom_on_click` | `JsRef -> (unit -> unit) -> unit` | `element.addEventListener("click", ...)` |
| `dom_input_value` | `JsRef -> str` | `element.value` (copied into a host scratch buffer) |
| `dom_on_key` | `(str -> unit) -> unit` | `document.addEventListener("keydown", ...)`; passes the key name (e.g. `"ArrowLeft"`) to the closure |

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
wat2wasm app.wat -o app.wasm
```

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
  - **JS → Mere** (e.g. `dom_input_value` return): JS writes into a
    high-memory scratch buffer (starts at 56KB) and returns the
    pointer. The next call to `dom_input_value` overwrites the scratch
    — copy via `substring` / `str_*` builtins if you need to retain it.
- `dom_on_click` takes a Mere closure as `(unit -> unit)`, which in
  Wasm is an `i32` pointer to a `{ env, fn_idx }` record. The glue
  reads both words and dispatches through the exported
  `__indirect_function_table`. The closure's captured env lives in
  Mere's bump arena, so it survives for the lifetime of the page.

## MVP limitations

- **Read-only string lifetime for `dom_input_value`**: only valid until
  the next call. Plan accordingly when reading multiple inputs.
- **No DOM node creation**: the lib operates on elements that already
  exist in the page. Building DOM trees from Mere is future work
  (would need either bindings for `document.createElement` + parent
  insertion, or a VDOM-style diff/patch layer in contrib).
- **Click only**: no `input` / `change` / `keydown` etc. Same shape
  applies — add another `dom_on_*` extern fn + glue entry when needed.
- **Single global handle table**: handles are never freed. For a
  long-running SPA that creates many ephemeral elements this would
  leak; for short-lived demos and event handlers wired at startup
  it's a non-issue.

## Position

Stage 2 contrib (incubation), part of the Phase 48 frontend MVP. See
[contrib/README.md](../README.md) for the lifecycle. Graduation target
is `mere-dom` (separate repo, after pkg manager lands), at which point
the lib will likely also gain `mere-vdom` / `mere-events` siblings.
