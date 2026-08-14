// examples/tally/store.worker.js — the browser home of store.mere.
//
// Runs the storage module inside a Worker and backs its positioned file
// I/O with an OPFS sync access handle. That handle is the reason this
// file exists at all: `read(buf, {at})`, `write(buf, {at})`, `flush()`
// and `getSize()` are SYNCHRONOUS, and they map one-to-one onto
// file_pread / file_pwrite / file_fsync / file_size — but the API is
// only available off the main thread. So the same store.mere that runs
// against the filesystem under Node runs against OPFS here, unchanged.
//
// One asymmetry to know about: acquiring a handle
// (`createSyncAccessHandle`) is asynchronous even though every operation
// on it is synchronous. Mere calls `file_openrw` synchronously and
// cannot await, so every file the module will touch has to be opened
// before the module runs. A single-log store makes that easy; a store
// that opens files by name at runtime would need a different shape —
// probably an explicit "mount" step in the protocol.
//
// Covered two ways: scripts/run_dom_headless.mjs --worker exercises the
// same store.mere and message protocol under Node, and
// scripts/check_browser.mjs drives this file in Chrome — writing through
// the store, reloading, and restarting the browser to confirm the
// counters come back off disk.

const DB_PATH = "/tmp/mere_tally.log";   // store.mere's `db`
const OPFS_NAME = "tally.log";           // what it becomes in OPFS

let memory = null, table = null, langBump = null, handler = null;
let accessHandle = null;
const PAGE = 64 * 1024;

const readStr = (ptr) => {
  const bytes = new Uint8Array(memory.buffer);
  let end = ptr;
  while (end < bytes.length && bytes[end] !== 0) end++;
  return new TextDecoder("utf-8").decode(bytes.subarray(ptr, end));
};

// Mere str layout: [i32 len][bytes][NUL], value points at byte0.
const writeStr = (s) => {
  const utf8 = new TextEncoder().encode(s);
  const aligned = (4 + utf8.length + 1 + 7) & ~7;
  const start = langBump.value;
  if (start + aligned > memory.buffer.byteLength) {
    memory.grow(Math.ceil((start + aligned - memory.buffer.byteLength) / PAGE));
  }
  new DataView(memory.buffer).setInt32(start, utf8.length, true);
  const mem = new Uint8Array(memory.buffer);
  mem.set(utf8, start + 4);
  mem[start + 4 + utf8.length] = 0;
  langBump.value = start + aligned;
  return start + 4;
};

const bumpAlloc = (n) => {
  const aligned = (n + 7) & ~7;
  const start = langBump.value;
  if (start + aligned > memory.buffer.byteLength) {
    memory.grow(Math.ceil((start + aligned - memory.buffer.byteLength) / PAGE));
  }
  langBump.value = start + aligned;
  return start;
};

// Handle 0 is the null sentinel, matching the Node hosts.
const openFiles = [undefined];

const stub = () => 0;
const env = {
  puts: () => 0,
  time: () => Date.now() / 1000,
  read_file: stub,
  write_file: stub,
  __lang_str_of_float: stub,
  __lang_float_of_str: () => 0.0,
  __lang_sin: Math.sin, __lang_cos: Math.cos, __lang_tan: Math.tan, __lang_exp: Math.exp, __lang_log: Math.log,
  __lang_f_pow: Math.pow, __lang_atan2: Math.atan2,

  // The one file was opened before the module started; this just hands
  // back its slot. An unknown path is a programming error rather than a
  // runtime condition, so it reports and returns the null handle.
  file_openrw: (pathPtr) => {
    const path = readStr(pathPtr);
    if (path !== DB_PATH) {
      console.error("tally worker: no pre-opened OPFS handle for", path);
      return 0;
    }
    return 1;
  },
  file_size: () => (accessHandle ? accessHandle.getSize() : 0),
  file_pread: (handle, off, len) => {
    let got = 0;
    const buf = new Uint8Array(Math.max(0, len));
    if (accessHandle && handle === 1 && len > 0 && off >= 0) {
      got = accessHandle.read(buf, { at: off });
    }
    const ptr = bumpAlloc(4 + got);
    new DataView(memory.buffer).setInt32(ptr, got, true);
    new Uint8Array(memory.buffer).set(buf.subarray(0, got), ptr + 4);
    return ptr;
  },
  file_pwrite: (handle, off, bytesPtr) => {
    if (!accessHandle || handle !== 1 || off < 0) return 0;
    const len = new DataView(memory.buffer).getInt32(bytesPtr, true);
    // Copy out of linear memory: write() may not accept a view backed by
    // a growable WebAssembly.Memory buffer.
    const src = new Uint8Array(memory.buffer).slice(bytesPtr + 4, bytesPtr + 4 + len);
    return accessHandle.write(src, { at: off });
  },
  file_fsync: () => { if (accessHandle) accessHandle.flush(); return 0; },
  // The handle stays open for the life of the Worker; closing it would
  // mean re-acquiring asynchronously on the next call.
  file_close: () => 0,

  // The store registers its message handler here, exactly as an HTTP
  // handler registers with http_serve.
  worker_serve: (closurePtr) => { handler = closurePtr; },
};

const dispatch = (request) => {
  if (handler === null) return "";
  const view = new DataView(memory.buffer);
  const envPtr = view.getInt32(handler, true);
  const fnIdx = view.getInt32(handler + 4, true);
  const fn = table.get(fnIdx);
  const argPtr = writeStr(request);
  const reply = fn(BigInt(envPtr), BigInt(argPtr));
  return readStr(typeof reply === "bigint" ? Number(reply) : reply);
};

const ready = (async () => {
  const root = await navigator.storage.getDirectory();
  const fileHandle = await root.getFileHandle(OPFS_NAME, { create: true });
  accessHandle = await fileHandle.createSyncAccessHandle();
  openFiles.push(accessHandle);

  const bytes = await fetch("/static/store.wasm").then((r) => r.arrayBuffer());
  const { instance } = await WebAssembly.instantiate(bytes, { env });
  memory = instance.exports.memory;
  table = instance.exports.__indirect_function_table;
  langBump = instance.exports.__lang_bump;
  instance.exports.main();
})();

self.onmessage = async (e) => {
  const { id, request } = e.data;
  await ready;
  let reply = "";
  try {
    reply = dispatch(request);
  } catch (err) {
    console.error("tally worker: store threw", { request, err });
  }
  self.postMessage({ id, reply });
};
