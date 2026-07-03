// Phase 27.2: Wasm runtime host harness for Mere examples.
// Loads a .wasm file, provides env imports (puts, read_file, write_file),
// invokes main, and captures puts output.
//
// Usage: node run_wasm.js <path-to-wasm>

const fs = require('fs');
const path = require('path');
const { Worker } = require('worker_threads');

if (process.argv.length < 3) {
  console.error("usage: node run_wasm.js <path-to-wasm>");
  process.exit(2);
}
const wasmPath = process.argv[2];

// ---- Synchronous TCP transport ------------------------------------------
//
// Wasm runs synchronously, but net.Socket is async. Bridge the two via a
// worker_thread that owns the sockets and a SharedArrayBuffer for
// request/response. The Wasm-side externs write into ctrl[]/data[], notify
// the worker, and Atomics.wait for the response. Lazy — the worker only
// spins up on first tcp_* call.

const TCP_DATA_OFFSET = 32;
const TCP_BUF_BYTES = 1 << 20;  // 1 MiB — large enough for typical DB row/frame
const TCP_SAB = new SharedArrayBuffer(TCP_DATA_OFFSET + TCP_BUF_BYTES);
const tcpCtrl = new Int32Array(TCP_SAB, 0, 8);
const tcpData = new Uint8Array(TCP_SAB, TCP_DATA_OFFSET);
const TCP_OP = { CONNECT: 1, WRITE: 2, READ: 3, CLOSE: 4, SET_TIMEOUT: 5 };
let tcpWorker = null;

function tcpEnsureWorker() {
  if (tcpWorker) return;
  const workerPath = path.join(__dirname, 'tcp_worker.js');
  tcpWorker = new Worker(workerPath, {
    workerData: { sab: TCP_SAB, dataOffset: TCP_DATA_OFFSET },
  });
  tcpWorker.unref();  // don't keep the process alive for the worker alone
}

// Fire off a request, block until worker responds. Result stored in ctrl[4];
// data payload (for READ) already sits in tcpData[0..ctrl[3]].
function tcpCall(op, arg1, arg2) {
  tcpEnsureWorker();
  Atomics.store(tcpCtrl, 1, op);
  Atomics.store(tcpCtrl, 2, arg1 | 0);
  Atomics.store(tcpCtrl, 3, arg2 | 0);
  Atomics.store(tcpCtrl, 0, 1);
  tcpWorker.postMessage(0);
  Atomics.wait(tcpCtrl, 0, 1);
  Atomics.store(tcpCtrl, 0, 0);
  return Atomics.load(tcpCtrl, 4);
}

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
    // ---- Sync TCP (see scripts/tcp_worker.js) ----------------------------
    // Wire-protocol clients (contrib/db/pg.mere etc.) build on these four
    // primitives. All calls are strictly synchronous from Wasm's POV; the
    // async plumbing happens in the worker thread.
    //
    // tcp_connect(host: str, port: int) -> int
    //   Returns fd (>=1) on success, -1 on connect failure.
    tcp_connect: (hostPtr, port) => {
      const host = readCStr(hostPtr);
      const bytes = Buffer.from(host, 'utf8');
      tcpData.set(bytes, 0);
      return tcpCall(TCP_OP.CONNECT, bytes.length, port | 0) | 0;
    },
    // tcp_write(fd, buf_ptr: int, len: int) -> int (bytes written, -1 on error).
    // buf_ptr is a raw byte pointer into Wasm linear memory — obtain from
    // mem_alloc or str_ptr. Binary-safe (NUL bytes pass through).
    tcp_write: (fd, bufPtr, len) => {
      const src = new Uint8Array(memory.buffer, bufPtr, len);
      tcpData.set(src, 0);
      return tcpCall(TCP_OP.WRITE, fd | 0, len | 0) | 0;
    },
    // tcp_read(fd, buf_ptr: int, cap: int) -> int (bytes read, 0=EOF, -1=error).
    tcp_read: (fd, bufPtr, cap) => {
      const capped = Math.min(cap | 0, TCP_BUF_BYTES);
      const n = tcpCall(TCP_OP.READ, fd | 0, capped) | 0;
      if (n > 0) {
        const dst = new Uint8Array(memory.buffer, bufPtr, n);
        dst.set(tcpData.subarray(0, n));
      }
      return n;
    },
    tcp_close: (fd) => { tcpCall(TCP_OP.CLOSE, fd | 0, 0); return 0; },
    tcp_set_timeout: (fd, ms) => { tcpCall(TCP_OP.SET_TIMEOUT, fd | 0, ms | 0); return 0; },

    // ---- Byte-buffer primitives for binary protocols ---------------------
    // Mere `str` is C-string (NUL-terminated), so binary framing needs a
    // raw-pointer path. These are thin wrappers over the bump allocator
    // and DataView reads/writes.

    // str_ptr(s: str) -> int  — coerce a str value to its raw pointer.
    // At the Wasm level this is a no-op (`str` IS an i32 pointer); the
    // extern boundary is what lets the type-checker accept it.
    str_ptr: (ptr) => ptr,

    // mem_alloc(n: int) -> int  — bump-allocate n bytes, returns pointer.
    // Contents are undefined; caller writes via mem_set_* before use.
    mem_alloc: (n) => bumpAlloc(n | 0),

    // Byte / u32 accessors — offsets are byte offsets from the pointer.
    mem_set_u8: (ptr, off, b) => {
      new Uint8Array(memory.buffer)[(ptr | 0) + (off | 0)] = b & 0xff;
      return 0;
    },
    mem_get_u8: (ptr, off) => {
      return new Uint8Array(memory.buffer)[(ptr | 0) + (off | 0)] | 0;
    },
    mem_set_u32be: (ptr, off, val) => {
      new DataView(memory.buffer).setUint32((ptr | 0) + (off | 0), val >>> 0, false);
      return 0;
    },
    mem_get_u32be: (ptr, off) => {
      // Coerce back to signed i32 — PG lengths fit comfortably in 31 bits.
      return new DataView(memory.buffer).getInt32((ptr | 0) + (off | 0), false);
    },
    mem_set_u16be: (ptr, off, val) => {
      new DataView(memory.buffer).setUint16((ptr | 0) + (off | 0), val & 0xffff, false);
      return 0;
    },
    mem_get_u16be: (ptr, off) => {
      return new DataView(memory.buffer).getUint16((ptr | 0) + (off | 0), false);
    },

    // mem_copy_str(dst: int, off: int, s: str) -> int
    //   Copies s's bytes (up to but excluding its terminating NUL) into
    //   dst starting at dst+off. Returns the new offset past the copy.
    mem_copy_str: (dst, off, srcPtr) => {
      const bytes = new Uint8Array(memory.buffer);
      let src = srcPtr | 0;
      let d = (dst | 0) + (off | 0);
      while (bytes[src] !== 0) bytes[d++] = bytes[src++];
      return d - (dst | 0);
    },

    // mem_to_str(ptr: int, len: int) -> str
    //   Materialize a Mere str by copying len bytes and appending a NUL.
    //   Callers must ensure the bytes are text (embedded NUL truncates
    //   the resulting str when used with str_len / concat).
    mem_to_str: (ptr, len) => {
      const n = len | 0;
      const dst = bumpAlloc(n + 1);
      const bytes = new Uint8Array(memory.buffer);
      bytes.copyWithin(dst, ptr | 0, (ptr | 0) + n);
      bytes[dst + n] = 0;
      return dst;
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
