// worker.js — Cloudflare Worker entry for the Mere package registry.
//
// Loads the compiled wasm + the bundled packages.json, dispatches
// each incoming Request to the Mere handler via the standard
// `cf_on_fetch` closure pattern, and returns the resulting Response.
//
// v0.1 is read-only: no KV, no GitHub API. Package data comes from
// `packages.json` inlined at build time. Dynamic behaviour (GitHub
// tag lookup + KV caching) lands in v0.2.

import wasmModule from "./main.wasm";
import packagesData from "./packages.json";

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

// Serialize the bundled packagesData once so the extern hands out
// the same string each request (no per-request JSON.stringify cost).
const registryDataStr = JSON.stringify(packagesData);

const stub = () => 0;
const env = {
  cf_on_fetch: (closurePtr) => { handlerClosurePtr = closurePtr; },
  cf_registry_data: () => writeStr(registryDataStr),
  puts: (ptr) => { console.log(readCStr(ptr)); },
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

const requestToJson = (request) => {
  const url = new URL(request.url);
  return JSON.stringify({
    method: request.method,
    path: url.pathname + url.search,
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
  // Mere may return `body` either as a JSON string (escaped) OR as
  // `body_raw:true` + `body` as an already-serialized JSON value
  // (for /pkg endpoints, forwarding the registry blob unmodified).
  const body = parsed.body_raw
    ? JSON.stringify(parsed.body)
    : (parsed.body ?? "");
  return new Response(body, {
    status: parsed.status ?? 200,
    headers: parsed.headers ?? {},
  });
};

export default {
  async fetch(request) {
    try {
      await ensureReady();
      const reqJson = requestToJson(request);
      const respJson = callHandler(reqJson);
      return jsonToResponse(respJson);
    } catch (e) {
      return new Response("worker error: " + e.message, { status: 500 });
    }
  },
};
