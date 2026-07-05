// worker.js — Cloudflare Worker entry.
//
// Loads main.wasm (pre-compiled from main.mere via wat2wasm), wires the
// `cf_on_fetch` extern so the Mere program can register a request
// handler, then exports a default `fetch` handler that serializes each
// incoming Request to JSON, invokes the Mere closure, and deserializes
// the response.
//
// The Wasm module is imported as a static asset via wrangler's
// `[wasm_modules]` binding. See wrangler.toml.

// wrangler injects the compiled Wasm module here at build time.
// Locally (node-based test runner), the same shape works via
// `WebAssembly.compile(fs.readFileSync(...))`.
import wasmModule from "./main.wasm";

// State that survives across fetch events (V8 isolate warm-start).
let memory = null;
let table = null;
let langBump = null;
let handlerClosurePtr = null;

const PAGE = 64 * 1024;

const readCStr = (ptr) => {
  const bytes = new Uint8Array(memory.buffer);
  let end = ptr;
  while (end < bytes.length && bytes[end] !== 0) end++;
  return new TextDecoder("utf-8").decode(bytes.subarray(ptr, end));
};

const writeStr = (s) => {
  const utf8 = new TextEncoder().encode(s + "\0");
  const aligned = (utf8.length + 7) & ~7;
  const start = langBump.value;
  const needed = start + aligned;
  const capacity = memory.buffer.byteLength;
  if (needed > capacity) {
    const growPages = Math.ceil((needed - capacity) / PAGE);
    memory.grow(growPages);
  }
  new Uint8Array(memory.buffer).set(utf8, start);
  langBump.value = start + aligned;
  return start;
};

const callHandler = (reqJson) => {
  if (handlerClosurePtr === null) {
    throw new Error("Mere handler was never registered — did main() run?");
  }
  const view = new DataView(memory.buffer);
  const env = view.getInt32(handlerClosurePtr, true);
  const fnIdx = view.getInt32(handlerClosurePtr + 4, true);
  const argPtr = writeStr(reqJson);
  const resultPtr = table.get(fnIdx)(env, argPtr);
  return readCStr(resultPtr);
};

// Minimal env — no TCP, no fs, no subprocess. CF Workers only get
// what V8 exposes; our Mere code sticks to compute + string ops.
const stub = () => 0;
const env = {
  cf_on_fetch: (closurePtr) => { handlerClosurePtr = closurePtr; },
  puts: (ptr) => {
    // console.log for `print` calls. Fine in CF Worker.
    console.log(readCStr(ptr));
  },
  // Stubs for prelude imports Mere programs always reference even
  // when unused. Standard set from run_wasm.js.
  read_file: stub,
  write_file: stub,
  __lang_str_of_float: stub,
  __lang_float_of_str: () => 0.0,
  __lang_sin: Math.sin,
  __lang_cos: Math.cos,
  __lang_tan: Math.tan,
  __lang_f_pow: Math.pow,
  __lang_atan2: Math.atan2,
};

// One-time init: compile + run main() so the handler gets registered.
let instantiated = null;
const ensureReady = async () => {
  if (instantiated) return instantiated;
  const instance = await WebAssembly.instantiate(wasmModule, { env });
  memory = instance.exports.memory;
  table = instance.exports.__indirect_function_table;
  langBump = instance.exports.__lang_bump;
  instance.exports.main();
  instantiated = instance;
  return instance;
};

// Extract the fields the Mere handler cares about into a JSON envelope.
const requestToJson = async (request) => {
  const url = new URL(request.url);
  const headers = {};
  request.headers.forEach((v, k) => { headers[k] = v; });
  const body = ["GET", "HEAD"].includes(request.method)
    ? ""
    : await request.text();
  return JSON.stringify({
    method: request.method,
    path: url.pathname + url.search,
    headers,
    body,
  });
};

const jsonToResponse = (jsonStr) => {
  let parsed;
  try {
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    return new Response(
      "worker: Mere handler returned non-JSON: " + jsonStr,
      { status: 500 }
    );
  }
  return new Response(parsed.body ?? "", {
    status: parsed.status ?? 200,
    headers: parsed.headers ?? {},
  });
};

export default {
  async fetch(request) {
    try {
      await ensureReady();
      const reqJson = await requestToJson(request);
      const respJson = callHandler(reqJson);
      return jsonToResponse(respJson);
    } catch (e) {
      return new Response("worker error: " + e.message, { status: 500 });
    }
  },
};
