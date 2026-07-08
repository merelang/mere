// Phase 27.2: Wasm runtime host harness for Mere examples.
// Loads a .wasm file, provides env imports (puts, read_file, write_file),
// invokes main, and captures puts output.
//
// Usage: node run_wasm.js <path-to-wasm>

const fs = require('fs');
const { Worker } = require('worker_threads');
const { makePgEnv } = require('./pg_env.js');
const { makeHttpFetchEnv } = require('./http_fetch_env.js');
const { makeSubprocessEnv } = require('./subprocess_env.js');

// Q-012: channel host ops over the SHARED wasm memory. A channel is a small
// region of shared linear memory (allocated by the creating instance's bump
// allocator); every instance's host import reads/writes it with JS Atomics,
// so the queue is coherent across worker threads. Layout in i32 words at
// `ptr`: [0]=mutex, [1]=count, [2]=head, [3]=cap, [4..]=ring buffer.
// Defined as a named function so its source can be injected into the worker
// bootstrap verbatim (workers need the same channel ops).
function makeChannelEnv(getBuffer, bumpAlloc) {
  const CAP = 4096;
  const lock = (i32, p) => {
    while (Atomics.compareExchange(i32, p, 0, 1) !== 0) Atomics.wait(i32, p, 1);
  };
  const unlock = (i32, p) => { Atomics.store(i32, p, 0); Atomics.notify(i32, p, 1); };
  return {
    mere_channel_new: (_unit) => {
      const ptr = bumpAlloc((4 + CAP) * 4);
      const i32 = new Int32Array(getBuffer());
      const p = ptr >> 2;
      i32[p] = 0; i32[p + 1] = 0; i32[p + 2] = 0; i32[p + 3] = CAP;
      return ptr;
    },
    mere_channel_send: (ptr, v) => {
      const i32 = new Int32Array(getBuffer());
      const p = ptr >> 2;
      lock(i32, p);
      const count = i32[p + 1], cap = i32[p + 3], head = i32[p + 2];
      i32[p + 4 + ((head + count) % cap)] = v;
      Atomics.store(i32, p + 1, count + 1);
      unlock(i32, p);
      Atomics.notify(i32, p + 1);  // wake recv waiters blocked on count
      return 0;
    },
    mere_channel_recv: (ptr) => {
      const i32 = new Int32Array(getBuffer());
      const p = ptr >> 2;
      for (;;) {
        lock(i32, p);
        const count = i32[p + 1];
        if (count > 0) {
          const head = i32[p + 2], cap = i32[p + 3];
          const v = i32[p + 4 + head];
          Atomics.store(i32, p + 2, (head + 1) % cap);
          Atomics.store(i32, p + 1, count - 1);
          unlock(i32, p);
          return v;
        }
        unlock(i32, p);
        Atomics.wait(i32, p + 1, 0);  // block while empty
      }
    },
  };
}

// Q-012: worker bootstrap for spawn. A spawned worker instantiates the SAME
// wasm module over the SAME shared memory (so the closure's env offset and
// the function-table index are both valid), then invokes the closure via the
// indirect function table: table.get(fnIdx)(envOffset, 0). It signals
// completion by setting a shared flag that mere_join waits on. Channel ops
// operate on the shared memory (makeChannelEnv, injected below). This MVP
// supports non-allocating worker closures (the bump allocator is per-instance;
// a shared allocator is a follow-up), which covers int-channel compute.
const WORKER_CODE = `
const { workerData } = require('worker_threads');
const { wasmBytes, memory, fnIdx, envOff, doneSab, bumpBase } = workerData;
const readCStr = (ptr) => {
  const bytes = new Uint8Array(memory.buffer);
  let end = ptr; while (end < bytes.length && bytes[end] !== 0) end++;
  return Buffer.from(bytes.subarray(ptr, end)).toString('utf8');
};
${makeChannelEnv.toString()}
const stub = () => 0;
const env = Object.assign({
  memory,
  puts: (ptr) => process.stdout.write(readCStr(ptr) + '\\n'),
  mere_spawn: stub, mere_join: stub,
  __lang_str_of_float: stub, __lang_float_of_str: stub,
  __lang_sin: Math.sin, __lang_cos: Math.cos, __lang_tan: Math.tan,
  __lang_f_pow: Math.pow, __lang_atan2: Math.atan2,
}, makeChannelEnv(() => memory.buffer, () => { throw new Error('no alloc in spawned worker'); }));
(async () => {
  const { instance } = await WebAssembly.instantiate(wasmBytes, { env });
  // Point this worker's bump allocator at its private region so allocations
  // in the spawned closure don't collide with other workers or the parent.
  if (instance.exports.__lang_bump) instance.exports.__lang_bump.value = bumpBase;
  const table = instance.exports.__indirect_function_table;
  try { table.get(fnIdx)(envOff, 0); } catch (e) { /* wasm trap in child */ }
  Atomics.store(new Int32Array(doneSab), 0, 1);
  Atomics.notify(new Int32Array(doneSab), 0);
})();
`;

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
    // Monotonic milliseconds since process start, truncated to i32.
    // Same shape as run_http_server.js so contrib modules that pull
    // `now_ms` (e.g. metrics duration counters) work under either
    // runner.
    now_ms: () => Math.floor(require("perf_hooks").performance.now()) | 0,
    rand: () => Math.floor(Math.random() * 0x7fffffff),
    srand: (_seed) => {},  // JS Math.random can't be seeded; no-op
    sleep: (_n) => 0,       // skip blocking sleep in JS context
    // sleep_ms(ms) — synchronous millisecond sleep via Atomics.wait
    // on a private SharedArrayBuffer. Blocks the whole Wasm frame
    // (which is what Mere programs want when they call it), so this
    // is only useful for CLIs / worker loops that WANT to pause; a
    // web server should not call it or all requests will stall.
    sleep_ms: (ms) => {
      if (!ms || ms <= 0) return 0;
      const sab = new SharedArrayBuffer(4);
      Atomics.wait(new Int32Array(sab), 0, 0, ms);
      return 0;
    },
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
    // TCP + byte-buffer + crypto externs come from the shared pg_env
    // module; they're merged into `env` below with Object.assign.
  };
  Object.assign(env, makePgEnv({
    getMemory: () => memory.buffer,
    bumpAlloc: (n) => bumpAlloc(n),
  }));
  // Outbound HTTP (http_fetch and friends) — same curl-based
  // implementation as run_http_server.js. Any Mere CLI that declares
  // `extern fn http_fetch: ...` can now make outbound calls too.
  const writeStr = (s) => {
    const utf8 = Buffer.from((s || "") + "\0", "utf8");
    const ptr = bumpAlloc(utf8.length);
    new Uint8Array(memory.buffer).set(utf8, ptr);
    return ptr;
  };
  Object.assign(env, makeHttpFetchEnv({ readCStr, writeStr }));
  Object.assign(env, makeSubprocessEnv({ readCStr, writeStr }));

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

  // Q-012: if the module imports a shared memory (a threaded program), the
  // host must create it so every worker instance shares one memory. Detect
  // that from the module's import list and wire spawn/join.
  const wasmModule = new WebAssembly.Module(wasmBytes);
  const moduleImports = WebAssembly.Module.imports(wasmModule);
  const needsSharedMem = moduleImports.some(
    (i) => i.module === 'env' && i.name === 'memory' && i.kind === 'memory');
  let sharedMemory = null;
  if (needsSharedMem) {
    sharedMemory = new WebAssembly.Memory({ initial: 1024, maximum: 65536, shared: true });
    env.memory = sharedMemory;
    let nextTid = 1;
    const threads = new Map();
    env.mere_spawn = (closurePtr) => {
      const view = new DataView(sharedMemory.buffer);
      const envOff = view.getInt32(closurePtr, true);
      const fnIdx = view.getInt32(closurePtr + 4, true);
      const tid = nextTid++;
      const doneSab = new SharedArrayBuffer(4);
      // Each worker allocates from a disjoint bump region so concurrent
      // allocations can't collide (the bump pointer is a per-instance global).
      // This is the pragmatic alternative to a single shared atomic bump:
      // the main instance uses the low region, worker i uses [16MB + i*8MB, …).
      const bumpBase = 16 * 1024 * 1024 + (tid - 1) * 8 * 1024 * 1024;
      const worker = new Worker(WORKER_CODE, {
        eval: true,
        workerData: { wasmBytes, memory: sharedMemory, fnIdx, envOff, doneSab, bumpBase },
      });
      worker.on('error', (e) => console.error('worker error:', e));
      threads.set(tid, { worker, done: new Int32Array(doneSab) });
      return tid;
    };
    env.mere_join = (tid) => {
      const t = threads.get(tid);
      if (t) { Atomics.wait(t.done, 0, 0); t.worker.terminate(); }
      return 0;
    };
    // Channels live in the shared memory; the creating (main) instance
    // allocates via its bump allocator, workers just read/write.
    Object.assign(env, makeChannelEnv(() => sharedMemory.buffer, bumpAlloc));
  }

  // instantiate(Module, imports) resolves to the Instance directly (unlike
  // instantiate(bytes, imports) which resolves to { instance, module }).
  const instance = await WebAssembly.instantiate(wasmModule, { env });
  memory = needsSharedMem ? sharedMemory : instance.exports.memory;
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
