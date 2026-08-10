// scripts/mere_host.js — the one definition of how a JS host talks to a
// compiled Mere module.
//
// Reading and writing a Mere value across the boundary is four operations
// — measure a string, allocate one, call a closure, check the ABI — and
// for a long time each host had its own copy of all four. That is how the
// length header reached `run_wasm.js` and no other runner, how the i64
// closure convention reached contrib/dom and not contrib/http, and how a
// fixed 4KB scratch window survived in one glue years after the others
// moved to the shared heap. Every one of those was a silent wrong answer
// at runtime, not a link error.
//
// So there is one copy now, and the layout is written down once:
//
//   value      i64; an address is the low 32 bits
//   str        [i32 len][bytes][NUL], the value points at byte0, so the
//              length is at ptr-4 (what $__lang_strlen loads)
//   bytes      [i32 len][raw bytes], the value points at the header
//   closure    { i32 env, i32 fn_idx }, called as (i64, i64) -> i64
//
// contrib/dom/dom.glue.js keeps its own copy on purpose: it is an ES
// module fetched by a browser, so it cannot require() this one. That copy
// is held to the same ABI by the check below and by a test that runs a
// round trip through both.

const { MERE_ABI, checkAbi } = require("./mere_abi.js");

const PAGE = 64 * 1024;

// `getMemory` returns the live WebAssembly.Memory (never cache `.buffer`
// — growing detaches it). `getBump` returns the exported `__lang_bump`
// global, or null before attach.
// `bumpAlloc` may be supplied instead of `getBump` by a host that
// already owns an allocator (pg_env is handed one by whichever runner
// loaded it).
function makeMarshal({ getMemory, getBump, bumpAlloc: injectedAlloc }) {
  // Advance the module's own bump pointer, growing linear memory when the
  // request would run past the end. Sharing the allocator is what keeps
  // host-written strings from colliding with Mere's own — the fixed
  // scratch window this replaced wrapped around and overwrote both.
  const bumpAlloc = injectedAlloc || ((n) => {
    const memory = getMemory();
    const bump = getBump();
    if (!memory || !bump) return 0;
    const aligned = (n + 7) & ~7;
    const start = bump.value;
    const needed = start + aligned;
    if (needed > memory.buffer.byteLength) {
      memory.grow(Math.ceil((needed - memory.buffer.byteLength) / PAGE));
    }
    bump.value = start + aligned;
    return start;
  });

  // JS string -> Mere str. Returns a pointer to byte0.
  const writeStr = (s) => {
    const utf8 = Buffer.from(s == null ? "" : String(s), "utf8");
    const start = bumpAlloc(4 + utf8.length + 1);
    if (!start) return 0;
    const memory = getMemory();
    // Views must be taken after bumpAlloc — a grow detaches the old buffer.
    new DataView(memory.buffer).setInt32(start, utf8.length, true);
    const mem = new Uint8Array(memory.buffer);
    mem.set(utf8, start + 4);
    mem[start + 4 + utf8.length] = 0;
    return start + 4;
  };

  // Raw bytes -> mere_bytes buffer. Returns a pointer to the header, which
  // is what the Wasm-side bytes bridge expects.
  const writeBytes = (buf) => {
    const start = bumpAlloc(4 + buf.length);
    if (!start && buf.length) return 0;
    const memory = getMemory();
    new DataView(memory.buffer).setInt32(start, buf.length, true);
    new Uint8Array(memory.buffer).set(buf, start + 4);
    return start;
  };

  // Mere str -> JS string, stopping at the NUL. Correct for text, and the
  // only option for a pointer that did not come from writeStr.
  const readCStr = (ptr) => {
    const memory = getMemory();
    if (!memory || !ptr) return "";
    const bytes = new Uint8Array(memory.buffer);
    let end = ptr;
    while (end < bytes.length && bytes[end] !== 0) end++;
    return Buffer.from(bytes.subarray(ptr, end)).toString("utf8");
  };

  // Mere str -> raw bytes, using the length header. Needed whenever the
  // value may contain a zero byte: an HTTP response body carrying a .wasm
  // asset begins with one, and a NUL scan returns nothing at all.
  const readStrBytes = (ptr) => {
    const memory = getMemory();
    if (!memory || !ptr) return Buffer.alloc(0);
    const len = new DataView(memory.buffer).getInt32(ptr - 4, true);
    if (len < 0 || ptr + len > memory.buffer.byteLength) return Buffer.alloc(0);
    return Buffer.from(new Uint8Array(memory.buffer).subarray(ptr, ptr + len));
  };

  // Read a mere_bytes buffer (pointer to the header) as raw bytes.
  const readBytes = (ptr) => {
    const memory = getMemory();
    if (!memory || !ptr) return Buffer.alloc(0);
    const len = new DataView(memory.buffer).getInt32(ptr, true);
    if (len < 0 || ptr + 4 + len > memory.buffer.byteLength) return Buffer.alloc(0);
    return Buffer.from(new Uint8Array(memory.buffer).subarray(ptr + 4, ptr + 4 + len));
  };

  // Copy `len` bytes that are ALREADY in linear memory into a fresh Mere
  // str. This is what a database driver does with every column value it
  // reads off the wire.
  const copyToStr = (srcPtr, len) => {
    const n = len | 0;
    const start = bumpAlloc(4 + n + 1);
    const memory = getMemory();
    new DataView(memory.buffer).setInt32(start, n, true);
    const bytes = new Uint8Array(memory.buffer);
    bytes.copyWithin(start + 4, srcPtr | 0, (srcPtr | 0) + n);
    bytes[start + 4 + n] = 0;
    return start + 4;
  };

  return { bumpAlloc, writeStr, writeBytes, readCStr, readStrBytes, readBytes, copyToStr };
}

// Dispatch a Mere closure value. `getTable` returns the exported
// __indirect_function_table.
function makeClosureCaller({ getMemory, getTable, who }) {
  // ptr is a { i32 env, i32 fn_idx } record; arg is already a Mere value
  // (a pointer or an integer). Returns the callee's i64 result as a
  // Number, since callers use it for pointer arithmetic.
  return (closurePtr, arg = 0) => {
    const memory = getMemory();
    const table = getTable();
    if (!memory || !table) {
      console.error(`${who}: closure called before attach()`);
      return 0;
    }
    // The bump allocator does not guarantee 4-byte alignment, so use
    // DataView, which accepts any byte offset.
    const view = new DataView(memory.buffer);
    const env = view.getInt32(closurePtr, true);
    const fnIdx = view.getInt32(closurePtr + 4, true);
    const fn = table.get(fnIdx);
    if (typeof fn !== "function") {
      console.error(`${who}: closure fn_idx not in table`, { closurePtr, env, fnIdx });
      return 0;
    }
    try {
      const r = fn(BigInt(env), BigInt(arg));
      return typeof r === "bigint" ? Number(r) : r;
    } catch (e) {
      console.error(`${who}: Mere closure threw`, { closurePtr, env, fnIdx, error: e });
      return 0;
    }
  };
}

module.exports = { MERE_ABI, checkAbi, makeMarshal, makeClosureCaller, PAGE };
