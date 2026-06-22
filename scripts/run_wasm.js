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
    // OCaml string_of_float の format (%.12g + 整数値なら trailing ".")
    // にできるだけ近づける。
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
          // 1.23000000000e+10 → 1.23e+10
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
  };

  // Allocate bytes by bumping the `__lang_bump` mutable global.
  // We can't easily mutate Wasm globals from JS, so we use a simple
  // approach: append to a fixed scratch region near the end of memory.
  // For Phase 27.2 MVP, just use a static offset that's known to be unused.
  let scratchOffset = 0; // set after instantiation based on memory size
  const bumpAlloc = (n) => {
    const ptr = scratchOffset;
    scratchOffset += (n + 7) & ~7; // 8-byte align
    return ptr;
  };

  const { instance } = await WebAssembly.instantiate(wasmBytes, { env });
  memory = instance.exports.memory;

  // Initialize scratch to start at the END of currently-allocated memory.
  // Wasm memory starts at 1 page = 64KB and grows. Use offset 56KB as
  // scratch (safe for most small examples).
  scratchOffset = 56 * 1024;

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
