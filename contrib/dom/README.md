# contrib/dom — DOM bindings for browser-side Mere

`extern fn` declarations + a JS host glue that let Mere code drive the
DOM, talk to a server, and receive pushes, when compiled to Wasm and
loaded in a browser.

Started as the Phase 48 C2 frontend-FFI MVP (elements that already
exist, click and key input — enough for games and emulators). v0.1.152
added the groups a document-shaped app needs: building elements,
request/response, and server push. v0.1.168 added what a list you can
filter and edit needs: removing one node, input events, and timers.
v0.1.170 added what a form needs and a list does not: blur, focus and
change, checkbox state, and removing an attribute.

## Files

| file | content | lines |
|---|---|---|
| `dom.mere` | `extern type JsRef;` + 34 `extern fn` declarations | ~215 |
| `dom.glue.js` | ES module exporting `makeDomGlue()` — the browser host implementation | ~490 |

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
| `dom_remove` | `JsRef -> unit` | `element.remove()` — detaches one node, siblings keep focus and caret |
| `dom_remove_attr` | `JsRef -> str -> unit` | `element.removeAttribute(name)` — the counterpart `dom_set_attr` lacked |
| `dom_checked` | `JsRef -> bool` | `input.checked` — a checkbox's meaning is not in its `value` |
| `dom_set_checked` | `JsRef -> bool -> unit` | `input.checked = ...` |

### Events

| fn | signature | maps to |
|---|---|---|
| `dom_on_click` | `JsRef -> (unit -> unit) -> unit` | `element.addEventListener("click", ...)` |
| `dom_on_submit` | `JsRef -> (unit -> unit) -> unit` | `"submit"`, with `preventDefault()` applied by the host |
| `dom_on_input` | `JsRef -> (str -> unit) -> unit` | `"input"`, with the field's current value — fires on every keystroke |
| `dom_on_change` | `JsRef -> (str -> unit) -> unit` | `"change"` — a `<select>` has no keystrokes; a checkbox reports `"1"` / `"0"` |
| `dom_on_blur` | `JsRef -> (str -> unit) -> unit` | `"blur"`, with the field's value — where validation belongs |
| `dom_on_focus` | `JsRef -> (unit -> unit) -> unit` | `"focus"` — where taking the complaint back down belongs |
| `dom_on_key` | `(str -> unit) -> unit` | `document.addEventListener("keydown", ...)`; passes the key name |
| `dom_set_timeout` | `int -> (unit -> unit) -> int` | `setTimeout`, returning a cancellable handle |
| `dom_clear_timeout` | `int -> unit` | `clearTimeout` — what makes a debounce a debounce |
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

## Testing with one

Some claims a dump cannot settle — whether a node is the *same* node,
where the caret is, whether the browser generated a `blur`. Each app that
makes one carries its own check, run against its own server and skipped
when Playwright is absent:

| check | what only a browser can show |
|---|---|
| `scripts/check_browser.mjs` (tally) | OPFS: state survives a browser restart |
| `examples/tasks/browser_check.mjs` | the row being edited is the same node, caret intact |
| `examples/profile/browser_check.mjs` | blur and focus as the user causes them, by moving between fields |

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

## Editing a list in place

A list that only grows can be redrawn wholesale — `dom_set_text el ""`
drops every child and the rest is rebuilt from state, which is what the
chat and tally clients do. A list you can filter and edit cannot: a row
holding an `<input>` you are typing into must not be rebuilt, or the
field goes out from under the caret.

`dom_remove`, `dom_on_input` and the timer pair exist for that, and
`examples/tasks` is the app that forced them: filtering removes only the
rows that stopped matching and appends only the ones that started, so a
row that stays is never touched. `examples/tasks/browser_check.mjs`
asserts exactly that — after typing in the search box, the row being
edited is the same DOM node with its caret still at offset 3. It takes a
real browser: a rebuilt row would look identical in a headless dump, and
the caret is the only thing that tells them apart.

The timers do two jobs there. Debounce: a keystroke cancels the pending
filter and queues a new one, so a burst of typing costs one re-render
rather than one per character. Retry: a save that fails comes back on a
doubling delay instead of being dropped.

## A form, as opposed to a list

A list is edited one item at a time and every keystroke is worth acting
on. A form is a set of fields with a shape: it is valid or it is not, it
differs from what was loaded or it does not, and its controls are not all
text. `input` and `click` cannot express any of that.

`dom_on_blur` / `dom_on_focus` / `dom_on_change` / `dom_checked` /
`dom_set_checked` / `dom_remove_attr` exist for that, and
`examples/profile` is the app that forced them. Validation runs on blur,
because checking on every keystroke tells someone their email is invalid
while they are still typing the part before the `@`; the complaint comes
back down on focus, because they have returned to fix it. A `<select>`
emits `change` and no keystrokes at all, so without it the theme picker
would be inert. A checkbox has no useful `value` — its meaning is
`el.checked`, a property that is not the attribute of the same name. And
`dom_remove_attr` closes a hole `dom_set_attr` had left since v0.1.152: a
form could disable its save button while the input was invalid and then
never enable it again.

`examples/profile/browser_check.mjs` asserts the part a headless harness
cannot: it can *fire* a blur, but only a browser can *cause* one by the
user clicking the next field.

## Limitations

- **No pointer / drag events**: `click`, `submit`, `input`, `change`,
  `blur`, `focus`, `keydown` and the animation frame are wired;
  `pointerdown` and friends follow the same shape.
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
