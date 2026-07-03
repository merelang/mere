// Phase 27.2: Wasm runtime host harness for Mere examples.
// Loads a .wasm file, provides env imports (puts, read_file, write_file),
// invokes main, and captures puts output.
//
// Usage: node run_wasm.js <path-to-wasm>

const fs = require('fs');

if (process.argv.length < 3) {
  console.error("usage: node run_wasm.js <path-to-wasm>");
  process.exit(2);
}
const wasmPath = process.argv[2];

(async () => {
  const wasmBytes = fs.readFileSync(wasmPath);
  let memory; // captured after instantiate

  // Read a C-style null-terminated string from linear memory at offset.
  const readCStr = (ptr) => {
    const bytes = new Uint8Array(memory.buffer);
    let end = ptr;
    while (end < bytes.length && bytes[end] !== 0) end++;
    return Buffer.from(bytes.subarray(ptr, end)).toString("utf8");
  };

  const env = {
    puts: (ptr) => {
      // C's puts appends a newline; match that.
      process.stdout.write(readCStr(ptr) + "\n");
    },
    read_file: (pathPtr) => {
      const path = readCStr(pathPtr);
      try {
        const content = fs.readFileSync(path, "utf8");
        // Allocate via bump: find global $__lang_bump and bump it.
        // For simplicity, write to a fixed scratch region near the end of
        // memory. Phase 27.2 MVP: bump pointer is at a known global.
        const bytes = Buffer.from(content + "\0", "utf8");
        const ptr = bumpAlloc(bytes.length);
        new Uint8Array(memory.buffer).set(bytes, ptr);
        return ptr;
      } catch (e) {
        console.error("read_file failed:", e.message);
        return 0;
      }
    },
    write_file: (pathPtr, contentPtr) => {
      const path = readCStr(pathPtr);
      const content = readCStr(contentPtr);
      try {
        fs.writeFileSync(path, content);
        return 0;
      } catch (e) {
        console.error("write_file failed:", e.message);
        return 1;
      }
    },
    // Phase 34.3 (Wasm float): str_of_float / float_of_str host imports.
    // Approximates OCaml's string_of_float format (%.12g, with a trailing
    // "." for integer-valued floats).
    __lang_str_of_float: (f) => {
      let s;
      if (Number.isNaN(f)) s = "nan";
      else if (f === Infinity) s = "inf";
      else if (f === -Infinity) s = "-inf";
      else {
        // %.12g equivalent: 12 significant digits, strip trailing zeros
        s = f.toPrecision(12);
        // Strip trailing zeros in fractional part (mimics %g)
        if (s.includes('e') || s.includes('E')) {
          // 1.23000000000e+10 -> 1.23e+10
          s = s.replace(/(\.\d*?)0+(e[+-]?\d+)/i, '$1$2').replace(/\.(e[+-]?\d+)/i, '$1');
        } else if (s.includes('.')) {
          s = s.replace(/\.?0+$/, '');
          if (s === '' || s === '-') s = '0';
        }
        // OCaml: append "." for plain integer-valued floats
        if (!/[.eEni]/.test(s)) s += '.';
      }
      const bytes = Buffer.from(s + '\0', 'utf8');
      const ptr = bumpAlloc(bytes.length);
      new Uint8Array(memory.buffer).set(bytes, ptr);
      return ptr;
    },
    __lang_float_of_str: (ptr) => {
      const s = readCStr(ptr);
      return parseFloat(s);
    },
    // Phase 34.4: libm functions (anything not in Wasm intrinsics is provided by the host)
    __lang_sin: Math.sin,
    __lang_cos: Math.cos,
    __lang_tan: Math.tan,
    __lang_f_pow: Math.pow,
    __lang_atan2: Math.atan2,
    // Phase 32.4 (C1 FFI): default impls for common libc functions that
    // Mere programs declare via `extern fn`. Add more as needed.
    getpid: () => process.pid,
    getppid: () => process.ppid,
    unix_time: () => Math.floor(Date.now() / 1000),
    rand: () => Math.floor(Math.random() * 0x7fffffff),
    srand: (_seed) => {},  // JS Math.random can't be seeded; no-op
    sleep: (_n) => 0,       // skip blocking sleep in JS context
    abs_int: (n) => Math.abs(n | 0),
    getenv: (namePtr) => {
      const name = readCStr(namePtr);
      const v = process.env[name];
      if (v === undefined) return 0;  // NULL — Mere expects str, segfault risk
      const bytes = Buffer.from(v + "\0", "utf8");
      const ptr = bumpAlloc(bytes.length);
      new Uint8Array(memory.buffer).set(bytes, ptr);
      return ptr;
    },
    setenv: (namePtr, valuePtr, _overwrite) => {
      const name = readCStr(namePtr);
      const value = readCStr(valuePtr);
      process.env[name] = value;
      return 0;
    },
    system: (cmdPtr) => {
      const cmd = readCStr(cmdPtr);
      try {
        require("child_process").execSync(cmd, { stdio: "inherit" });
        return 0;
      } catch (e) {
        return e.status || 1;
      }
    },
    // arg_count / arg_get — user-facing CLI args (everything after the
    // .wasm path on the command line). Same as `argv[1:]` in a normal
    // program: `node run_wasm.js foo.wasm --flag path/to/input` gives
    // arg_count() = 2, arg_get(0) = "--flag", arg_get(1) = "path/…".
    // Needed for self-hosted CLI tools (mere-in-Mere compiler driver
    // that takes an input file path).
    arg_count: () => process.argv.length - 3,
    arg_get: (n) => {
      const args = process.argv.slice(3);
      const v = args[n | 0] || "";
      const bytes = Buffer.from(v + "\0", "utf8");
      const ptr = bumpAlloc(bytes.length);
      new Uint8Array(memory.buffer).set(bytes, ptr);
      return ptr;
    },
  };

  // Allocate on the shared Mere heap by advancing `$__lang_bump`
  // (mirrors the newer run_http_server.js). Grows memory one 64KB
  // page at a time when a write would exceed the current buffer.
  // Small allocations (env / getenv strings, single args) don't
  // trigger growth; the self-host CLI reading multi-KB source files
  // does.
  let langBump = null;  // set after instantiate
  const PAGE = 64 * 1024;
  const bumpAlloc = (n) => {
    if (!langBump) {
      // Legacy fallback for pre-Phase-55 wasm that didn't export
      // __lang_bump. A fixed high-offset scratch worked for the
      // tiny compute demos this runner was originally shipped for.
      // Real programs should recompile with a current mere.
      const p = scratchOffset;
      scratchOffset += (n + 7) & ~7;
      return p;
    }
    const aligned = (n + 7) & ~7;
    const start = langBump.value;
    const needed = start + aligned;
    if (needed > memory.buffer.byteLength) {
      const growPages = Math.ceil((needed - memory.buffer.byteLength) / PAGE);
      memory.grow(growPages);
    }
    langBump.value = start + aligned;
    return start;
  };
  let scratchOffset = 56 * 1024;  // used only when langBump is absent

  const { instance } = await WebAssembly.instantiate(wasmBytes, { env });
  memory = instance.exports.memory;
  langBump = instance.exports.__lang_bump || null;

  // Phase 48.2 (C2 Stage 2): helper for invoking a Mere closure value
  // (an i32 pointer to a 2-word { env, fn_idx } record in linear memory)
  // from JS. Hosts that wire `extern fn ... -> (T -> U) -> ...` should
  // hold onto the closure pointer the Wasm code passes, then use this
  // helper from event callbacks etc.
  //
  // Usage from a host import:
  //   env.dom_on_click = (btnPtr, closurePtr) => {
  //     document.getElementById(...).addEventListener('click', () =>
  //       callMereClosure(closurePtr, /* arg */ 0));
  //   };
  const table = instance.exports.__indirect_function_table;
  const callMereClosure = (closurePtr, arg = 0) => {
    if (!table) throw new Error("Wasm module did not export __indirect_function_table");
    // Mere's bump allocator does not enforce 4-byte alignment, so the
    // closure record's offset may be misaligned. Int32Array indexing
    // rounds the byte offset to a 4-byte boundary; DataView accepts any.
    const view = new DataView(memory.buffer);
    const env = view.getInt32(closurePtr, true);
    const fnIdx = view.getInt32(closurePtr + 4, true);
    return table.get(fnIdx)(env, arg);
  };
  // Expose for hosts that bind extra env imports later (e.g. DOM glue).
  globalThis.__mere_call_closure = callMereClosure;

  try {
    instance.exports.main();
  } catch (e) {
    if (e instanceof WebAssembly.RuntimeError) {
      // Wasm trap (typically from fail's unreachable). Mere's fail prints
      // via puts BEFORE unreachable, so the message has already been
      // output. Exit cleanly.
      process.exit(1);
    } else {
      throw e;
    }
  }
})().catch((e) => {
  console.error("error:", e);
  process.exit(1);
});
