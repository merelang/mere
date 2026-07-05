// local_test.js — Node-based smoke test for the CF Worker template.
//
// Wrangler installs a heavier miniflare/V8 runtime. This script is
// smaller: it just verifies the worker.js module surface works end
// to end, using Node 22's built-in `Request` / `Response`. Same shape
// CF gives you, minus KV / R2 / Durable Object bindings (none used).
//
// Usage:
//   sh build.sh               # produce main.wasm first
//   node local_test.js        # runs 3 request scenarios

import fs from "node:fs";

// Rewrite `import wasmModule from "./main.wasm"` for Node — Node
// doesn't support that import assertion directly. We patch the
// import to read the file synchronously instead.
const wasmBytes = fs.readFileSync(new URL("./main.wasm", import.meta.url));

// Load worker.js but replace its wasm import with our compiled module.
// Simplest: dynamically import a shim that provides the module.
globalThis.__test_wasm = new WebAssembly.Module(wasmBytes);
const workerSource = fs.readFileSync(new URL("./worker.js", import.meta.url), "utf8")
  .replace(
    'import wasmModule from "./main.wasm";',
    'const wasmModule = globalThis.__test_wasm;'
  );
const workerModuleUrl =
  "data:text/javascript;base64," +
  Buffer.from(workerSource, "utf8").toString("base64");
const worker = (await import(workerModuleUrl)).default;

const runCase = async (label, request) => {
  const resp = await worker.fetch(request);
  const body = await resp.text();
  console.log(`--- ${label} ---`);
  console.log("status:", resp.status);
  console.log("headers:", Object.fromEntries(resp.headers));
  console.log("body:", body);
  console.log("");
};

await runCase(
  "GET /",
  new Request("http://localhost/", { method: "GET" })
);
await runCase(
  "GET /hello?name=world",
  new Request("http://localhost/hello?name=world", { method: "GET" })
);
await runCase(
  "POST /submit",
  new Request("http://localhost/submit", {
    method: "POST",
    body: JSON.stringify({ msg: "hi" }),
    headers: { "content-type": "application/json" },
  })
);
