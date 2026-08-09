// scripts/check_browser.mjs — drive examples/tally in a real browser.
//
// The Node harness (run_dom_headless.mjs) covers the app and the store,
// but it cannot cover the one binding that only exists in a browser: the
// OPFS access handle behind examples/tally/store.worker.js. This does,
// by running the page, writing through the store, restarting the browser
// process, and checking the counters came back off disk.
//
// Playwright is not a dependency of this repo. Install it wherever you
// like and point this at it:
//
//   npm i -D playwright && npx playwright install chromium
//   node scripts/check_browser.mjs
//
//   # or reuse an existing install without touching this repo:
//   PLAYWRIGHT_PATH=/path/to/node_modules/playwright \
//     node scripts/check_browser.mjs
//
// Missing Playwright is a SKIP, not a failure — same convention as
// scripts/parity.sh with a missing backend toolchain.
//
// Requires examples/tally/server.mere to be running:
//   mere -w examples/tally/server.mere > /tmp/tally_server.wat
//   wat2wasm --enable-tail-call /tmp/tally_server.wat -o /tmp/tally_server.wasm
//   node scripts/run_http_server.js /tmp/tally_server.wasm

import { rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BASE = process.env.TALLY_URL || "http://localhost:8080/";
const COUNTER = "browser-check";

let playwright;
try {
  const spec = process.env.PLAYWRIGHT_PATH || "playwright";
  playwright = await import(spec.startsWith("/") ? join(spec, "index.mjs") : spec);
} catch (e) {
  console.log("SKIP browser check — playwright not found (set PLAYWRIGHT_PATH or npm i -D playwright)");
  process.exit(0);
}

const profile = mkdtempSync(join(tmpdir(), "mere-browser-"));
let failures = 0;
const check = (label, ok, detail) => {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${detail ? " — " + detail : ""}`);
  if (!ok) failures++;
};

// Prefer the installed Chrome so a bundled-browser download is optional.
const launch = async () => {
  for (const opts of [{ channel: "chrome" }, {}]) {
    try {
      return await playwright.chromium.launchPersistentContext(profile,
        { headless: true, ...opts });
    } catch (e) { /* try the next */ }
  }
  return null;
};

const board = (page) => page.$$eval("#board li", (els) =>
  els.map((li) => ({
    name: li.querySelector(".name")?.textContent,
    count: li.querySelector(".count")?.textContent,
  })));

const session = async (fn) => {
  const ctx = await launch();
  if (!ctx) {
    console.log("SKIP browser check — no chromium available (npx playwright install chromium)");
    process.exit(0);
  }
  const page = await ctx.newPage();
  page.on("pageerror", (e) => check("no page errors", false, e.message));
  try { await fn(page); } finally { await ctx.close(); }
};

// ---- first session: write through the store -------------------------

await session(async (page) => {
  await page.goto(BASE, { waitUntil: "load" });

  // The store must run off the main thread: createSyncAccessHandle is a
  // Worker-only API, which is the whole reason for the split.
  const mainThreadHasSyncHandle = await page.evaluate(() =>
    typeof FileSystemFileHandle !== "undefined" &&
    "createSyncAccessHandle" in FileSystemFileHandle.prototype);
  check("sync access handle is Worker-only", mainThreadHasSyncHandle === false,
    mainThreadHasSyncHandle ? "exposed on the main thread too" : "absent on the main thread");

  await page.waitForFunction(
    () => document.querySelector("#status")?.textContent === "local",
    null, { timeout: 10000 });

  await page.fill("#label", COUNTER);
  await page.click("#add button[type=submit]");
  await page.waitForSelector("#board li", { timeout: 10000 });

  await page.click(`#bump-${COUNTER}`);
  await page.waitForFunction(
    (n) => [...document.querySelectorAll("#board li")].some(
      (li) => li.querySelector(".name")?.textContent === n &&
              li.querySelector(".count")?.textContent === "1"),
    COUNTER, { timeout: 10000 });
  check("write through the OPFS-backed store", true);

  await page.reload({ waitUntil: "load" });
  await page.waitForSelector("#board li", { timeout: 10000 });
  const afterReload = await board(page);
  const reloaded = afterReload.find((r) => r.name === COUNTER);
  check("survives a reload", reloaded?.count === "1", JSON.stringify(afterReload));

  await page.click("#sync");
  await page.waitForFunction(
    () => ["synced", "offline"].includes(document.querySelector("#status")?.textContent),
    null, { timeout: 15000 });
  const status = await page.textContent("#status");
  check("syncs with the server", status === "synced", `status=${status}`);
});

// ---- second session: a new browser process --------------------------

await session(async (page) => {
  await page.goto(BASE, { waitUntil: "load" });
  await page.waitForSelector("#board li", { timeout: 10000 });
  const rows = await board(page);
  const found = rows.find((r) => r.name === COUNTER);
  check("survives a browser restart", found?.count === "1", JSON.stringify(rows));
});

rmSync(profile, { recursive: true, force: true });
console.log(failures === 0 ? "\nbrowser: all checks passed" : `\nbrowser: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
