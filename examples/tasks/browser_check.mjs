// examples/tasks/browser_check.mjs — drive the task list in a real browser.
//
// The claim this example is built around cannot be checked without one.
// run_dom_headless.mjs can show that filtering leaves the right rows in
// the DOM, but "the row you are editing keeps its focus and its caret"
// is about identity and selection state that only a browser maintains:
// if the row were rebuilt, the new <input> would look identical in a
// dump and the caret would be gone.
//
// Playwright is not a dependency of this repo. Install it wherever you
// like and point this at it:
//
//   npm i -D playwright && npx playwright install chromium
//   node examples/tasks/browser_check.mjs
//
//   # or reuse an existing install without touching this repo:
//   PLAYWRIGHT_PATH=/path/to/node_modules/playwright \
//     node examples/tasks/browser_check.mjs
//
// Missing Playwright is a SKIP, not a failure — same convention as
// scripts/parity.sh with a missing backend toolchain.
//
// Requires examples/tasks/server.mere to be running:
//   mere -w examples/tasks/server.mere > /tmp/tasks_server.wat
//   wat2wasm --enable-tail-call /tmp/tasks_server.wat -o /tmp/tasks_server.wasm
//   node scripts/run_http_server.js /tmp/tasks_server.wasm

import { rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BASE = process.env.TASKS_URL || "http://localhost:8080/";

let playwright;
try {
  const spec = process.env.PLAYWRIGHT_PATH || "playwright";
  playwright = await import(spec.startsWith("/") ? join(spec, "index.mjs") : spec);
} catch (e) {
  console.log("SKIP browser check — playwright not found (set PLAYWRIGHT_PATH or npm i -D playwright)");
  process.exit(0);
}

const userDir = mkdtempSync(join(tmpdir(), "mere-tasks-"));
let failures = 0;
const check = (label, ok, detail) => {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${detail ? " — " + detail : ""}`);
  if (!ok) failures++;
};

// Prefer the installed Chrome so a bundled-browser download is optional.
const launch = async () => {
  for (const opts of [{ channel: "chrome" }, {}]) {
    try {
      return await playwright.chromium.launchPersistentContext(userDir,
        { headless: true, ...opts });
    } catch (e) { /* try the next */ }
  }
  return null;
};

const ctx = await launch();
if (!ctx) {
  console.log("SKIP browser check — no Chrome/Chromium available to playwright");
  rmSync(userDir, { recursive: true, force: true });
  process.exit(0);
}

const page = await ctx.newPage();
page.on("pageerror", (e) => console.log("[pageerror]", e.message));

const ids = () => page.$$eval("#list li", (els) => els.map((e) => e.id));

// Seed two tasks whose titles differ in whether they contain an "a", so a
// filter can be made to drop one and keep the other.
for (const title of ["alpha task", "second job"]) {
  await page.request.post(BASE + "api/tasks", {
    headers: { "Content-Type": "text/plain" },
    data: "add\t" + title,
  });
}

await page.goto(BASE, { waitUntil: "load" });
await page.waitForSelector("#list li", { timeout: 8000 });
const initial = await ids();
check("the list loads", initial.length >= 2, JSON.stringify(initial));

// --- the point of the example ----------------------------------------
// Put the caret in the middle of a task's title, then type in the search
// box so the filter re-runs. The edited row still matches, so it must not
// have been rebuilt: same node, caret intact.
const firstId = initial[0].replace("task-", "");
await page.click(`#edit-${firstId}`);
await page.$eval(`#edit-${firstId}`, (el) => { el.setSelectionRange(3, 3); });
await page.$eval(`#edit-${firstId}`, (el) => { el.dataset.mark = "same-node"; });

await page.fill("#search", "a");
await page.waitForTimeout(600);   // past the 250ms filter debounce

const survived = await page.$eval(`#edit-${firstId}`, (el) => ({
  marked: el.dataset.mark === "same-node",
  caret: el.selectionStart,
})).catch(() => ({ marked: false, caret: -1 }));

check("the edited row is the same node after filtering", survived.marked === true,
  JSON.stringify(survived));
// Focus is in the search box, because that is where the typing is. What
// matters is that the row was not rebuilt underneath it: had it been, the
// caret would have gone with the node.
check("focus is where the user is typing",
  (await page.evaluate(() => document.activeElement?.id)) === "search");
check("the caret did not move", survived.caret === 3, `caret=${survived.caret}`);

// --- filtering removes only what stops matching ----------------------
await page.fill("#search", "zzzz");
await page.waitForTimeout(600);
check("a filter matching nothing empties the list", (await ids()).length === 0);
await page.fill("#search", "");
await page.waitForTimeout(600);
check("clearing the filter brings the rows back",
  (await ids()).length === initial.length, JSON.stringify(await ids()));

// --- delete takes out one row and leaves the rest --------------------
const before = await ids();
const victim = before[before.length - 1].replace("task-", "");
await page.click(`#del-${victim}`);
await page.waitForTimeout(500);
const after = await ids();
check("delete removes exactly one row",
  after.length === before.length - 1 && !after.includes(`task-${victim}`),
  JSON.stringify(after));

// --- a failed save comes back ----------------------------------------
// The server's fault injector fails the next save on purpose, because a
// retry path that is never taken is a path that is never tested.
await page.request.post(BASE + "api/flaky", { data: "1" });
const keep = (await ids())[0].replace("task-", "");
await page.fill(`#edit-${keep}`, "renamed in a browser");
await page.waitForFunction(
  () => document.querySelector("#status")?.textContent.startsWith("save failed"),
  null, { timeout: 5000 }).catch(() => {});
const retrying = await page.textContent("#status");
check("a failed save reports a retry", retrying.startsWith("save failed"), retrying);
await page.waitForFunction(
  () => document.querySelector("#status")?.textContent === "saved",
  null, { timeout: 8000 });
check("and lands on the retry", true, await page.textContent("#status"));

await ctx.close();
rmSync(userDir, { recursive: true, force: true });
console.log(failures === 0
  ? "\ntasks browser check: all passed"
  : `\ntasks browser check: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
