// contrib/dom/dom.glue.js — browser host glue for `contrib/dom/dom.mere`.
//
// Wires the four `extern fn dom_*` declarations to real DOM operations.
// The caller (HTML host) instantiates the Wasm module with this glue
// merged into `env`:
//
//   import { makeDomGlue } from "./contrib/dom/dom.glue.js";
//   const { glue, attach } = makeDomGlue();
//   const { instance } = await WebAssembly.instantiate(wasmBytes, {
//     env: { ...glue, /* puts, math, etc. */ }
//   });
//   attach(instance);  // hands the instance's memory + table to the glue
//   instance.exports.main();
//
// The split between `glue` (passed to instantiate before the instance
// exists) and `attach` (called after) is forced by the order of Wasm
// instantiation — the env imports must be ready *before* the instance,
// but the glue needs the instance's memory + table to do anything.

export function makeDomGlue() {
  // Closure state — populated by `attach` after the Wasm module
  // instantiates. Until then the dom_* fns are no-ops that warn.
  let memory = null;
  let table = null;

  // Handle 0 is reserved as a "null" sentinel — `dom_get_by_id` returns
  // it when the id doesn't match anything, and the other ops are
  // defensively no-ops on it. User-allocated handles start at 1.
  const handles = [null];

  const readStr = (ptr) => {
    if (!memory) return "";
    const bytes = new Uint8Array(memory.buffer);
    let end = ptr;
    while (end < bytes.length && bytes[end] !== 0) end++;
    return new TextDecoder("utf-8").decode(bytes.subarray(ptr, end));
  };

  // Scratch buffer for returning strings to Mere. Sits high in memory;
  // each call to `dom_input_value` overwrites the previous result, so
  // copy via Mere's str_* builtins if you need to keep it across calls.
  // 56KB matches the convention in `scripts/run_wasm.js`.
  let scratchOffset = 56 * 1024;
  const SCRATCH_LIMIT = 60 * 1024;

  const writeStr = (s) => {
    if (!memory) return 0;
    const utf8 = new TextEncoder().encode(s);
    const total = utf8.length + 1;
    if (scratchOffset + total > SCRATCH_LIMIT) {
      // Wrap around — `dom_input_value` doesn't keep ownership across
      // calls anyway, so we can safely reset.
      scratchOffset = 56 * 1024;
    }
    const ptr = scratchOffset;
    new Uint8Array(memory.buffer).set(utf8, ptr);
    new Uint8Array(memory.buffer)[ptr + utf8.length] = 0;
    scratchOffset += total;
    return ptr;
  };

  const callClosure = (closurePtr) => {
    if (!memory || !table) {
      console.error("contrib/dom: callClosure invoked before attach()", { memory, table });
      return;
    }
    const view = new Int32Array(memory.buffer);
    const env = view[closurePtr >> 2];
    const fnIdx = view[(closurePtr + 4) >> 2];
    const fn = table.get(fnIdx);
    if (typeof fn !== "function") {
      console.error("contrib/dom: closure fn_idx not in table", { closurePtr, env, fnIdx, fn });
      return;
    }
    try {
      fn(env, 0);
    } catch (e) {
      console.error("contrib/dom: Mere closure threw", { closurePtr, env, fnIdx, error: e });
    }
  };

  const glue = {
    dom_get_by_id: (strPtr) => {
      const id = readStr(strPtr);
      const el = (typeof document !== "undefined") ? document.getElementById(id) : null;
      if (!el) return 0;
      handles.push(el);
      return handles.length - 1;
    },
    dom_set_text: (handleIdx, strPtr) => {
      const el = handles[handleIdx];
      if (el) el.textContent = readStr(strPtr);
    },
    dom_on_click: (handleIdx, closurePtr) => {
      const el = handles[handleIdx];
      if (!el) {
        console.warn("contrib/dom: dom_on_click on null handle", { handleIdx, closurePtr });
        return;
      }
      el.addEventListener("click", () => callClosure(closurePtr));
    },
    dom_input_value: (handleIdx) => {
      const el = handles[handleIdx];
      if (!el) return writeStr("");
      return writeStr(el.value !== undefined ? el.value : "");
    },
  };

  const attach = (instance) => {
    memory = instance.exports.memory;
    table = instance.exports.__indirect_function_table;
    if (!table) {
      throw new Error(
        "contrib/dom: instance does not export __indirect_function_table " +
        "— recompile with a current `mere -w` (Phase 48.2+)"
      );
    }
  };

  return { glue, attach };
}
