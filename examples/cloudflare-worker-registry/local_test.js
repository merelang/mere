// local_test.js — Node smoke test for the package registry Worker.
//
// No CF bindings needed for v0.1 (read-only from bundled JSON).
// Same Request/Response shapes as CF Workers via Node 22 native APIs.
//
// Usage:
//   sh build.sh
//   node local_test.js

import fs from "node:fs";

const wasmBytes = fs.readFileSync(new URL("./main.wasm", import.meta.url));
globalThis.__test_wasm = new WebAssembly.Module(wasmBytes);
const packagesJson = fs.readFileSync(
  new URL("./packages.json", import.meta.url),
  "utf8"
);
globalThis.__test_packages = JSON.parse(packagesJson);

const workerSource = fs
  .readFileSync(new URL("./worker.js", import.meta.url), "utf8")
  .replace(
    'import wasmModule from "./main.wasm";',
    "const wasmModule = globalThis.__test_wasm;"
  )
  .replace(
    'import packagesData from "./packages.json";',
    "const packagesData = globalThis.__test_packages;"
  );

const workerModuleUrl =
  "data:text/javascript;base64," +
  Buffer.from(workerSource, "utf8").toString("base64");
const worker = (await import(workerModuleUrl)).default;

const call = async (method, path) => {
  const req = new Request("http://localhost" + path, { method });
  const resp = await worker.fetch(req);
  const text = await resp.text();
  return { status: resp.status, headers: Object.fromEntries(resp.headers), body: text };
};

const check = (label, actual, expected) => {
  const pass = JSON.stringify(actual) === JSON.stringify(expected);
  if (pass) console.log(`  ok   ${label}`);
  else {
    console.log(`  FAIL ${label}`);
    console.log(`       expected: ${JSON.stringify(expected)}`);
    console.log(`       actual:   ${JSON.stringify(actual)}`);
  }
  return pass;
};

let allOk = true;
const record = (b) => { if (!b) allOk = false; };

console.log("=== registry smoke test ===\n");

// 1. Landing
console.log("1. GET / landing");
const r1 = await call("GET", "/");
record(check("status", r1.status, 200));
record(check("content-type is HTML",
  r1.headers["content-type"].startsWith("text/html"), true));
console.log("");

// 2. GET /pkg returns the whole registry
console.log("2. GET /pkg lists all packages");
const r2 = await call("GET", "/pkg");
record(check("status", r2.status, 200));
const all = JSON.parse(r2.body);
record(check("has mere-http", "mere-http" in all, true));
record(check("has mere-db", "mere-db" in all, true));
record(check("has mere-json", "mere-json" in all, true));
console.log("");

// 3. GET /pkg/mere-http one package
console.log("3. GET /pkg/mere-http metadata");
const r3 = await call("GET", "/pkg/mere-http");
record(check("status", r3.status, 200));
const httpPkg = JSON.parse(r3.body);
record(check("owner", httpPkg.owner, "merelang"));
record(check("latest", httpPkg.latest, "0.1.0"));
record(check("has 0.1.0 version", "0.1.0" in httpPkg.versions, true));
console.log("");

// 4. GET /pkg/mere-http/latest
console.log("4. GET /pkg/mere-http/latest");
const r4 = await call("GET", "/pkg/mere-http/latest");
record(check("status", r4.status, 200));
const httpLatest = JSON.parse(r4.body);
record(check("name", httpLatest.name, "mere-http"));
record(check("version", httpLatest.version, "0.1.0"));
record(check("tarball URL present",
  httpLatest.tarball.startsWith("https://github.com/"), true));
console.log("");

// 5. GET /pkg/mere-http/0.1.0 specific version
console.log("5. GET /pkg/mere-http/0.1.0");
const r5 = await call("GET", "/pkg/mere-http/0.1.0");
record(check("status", r5.status, 200));
const v5 = JSON.parse(r5.body);
record(check("version", v5.version, "0.1.0"));
console.log("");

// 6. Unknown package → 404
console.log("6. GET /pkg/nonexistent → 404");
const r6 = await call("GET", "/pkg/nonexistent");
record(check("status", r6.status, 404));
console.log("");

// 7. Unknown version → 404
console.log("7. GET /pkg/mere-http/9.9.9 → 404");
const r7 = await call("GET", "/pkg/mere-http/9.9.9");
record(check("status", r7.status, 404));
console.log("");

// 8. POST → 404 (only GET supported)
console.log("8. POST / → 404");
const r8 = await call("POST", "/");
record(check("status", r8.status, 404));
console.log("");

console.log(allOk ? "=== all pass ===" : "=== FAILURES ===");
process.exit(allOk ? 0 : 1);
