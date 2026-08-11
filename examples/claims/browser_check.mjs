// examples/claims/browser_check.mjs — drive the claim form in a real browser.
//
// The claim this example makes is that the form is the record: no control
// below is written down in index.html, and the page is built at startup
// from the field names the compiler already knows. A headless dump can
// show the elements exist; only a browser shows that they behave like
// controls — that typing into a generated <input> reaches the model, that
// leaving one runs the rule the schema associates with its name, and that
// the server's own refusal lands in the generated error slot.
//
// Playwright is not a dependency of this repo. Install it wherever you
// like and point this at it:
//
//   npm i -D playwright && npx playwright install chromium
//   node examples/claims/browser_check.mjs
//
//   # or reuse an existing install without touching this repo:
//   PLAYWRIGHT_PATH=/path/to/node_modules/playwright \
//     node examples/claims/browser_check.mjs
//
// Missing Playwright is a SKIP, not a failure.
//
// Requires examples/claims/server.mere to be running:
//   mere -w examples/claims/server.mere > /tmp/claims_server.wat
//   wat2wasm --enable-tail-call /tmp/claims_server.wat -o /tmp/claims_server.wasm
//   node scripts/run_http_server.js /tmp/claims_server.wasm

import { rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BASE = process.env.CLAIMS_URL || "http://localhost:8080/";

let playwright;
try {
  const spec = process.env.PLAYWRIGHT_PATH || "playwright";
  playwright = await import(spec.startsWith("/") ? join(spec, "index.mjs") : spec);
} catch (e) {
  console.log("SKIP browser check — playwright not found (set PLAYWRIGHT_PATH or npm i -D playwright)");
  process.exit(0);
}

const userDir = mkdtempSync(join(tmpdir(), "mere-claims-"));
let failures = 0;
const check = (label, ok, detail) => {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${detail ? " — " + detail : ""}`);
  if (!ok) failures++;
};

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

const err = (name) => page.textContent("#err-" + name);
const disabled = (id) => page.$eval("#" + id, (el) => el.disabled);

// Back to an empty draft first: this check submits, and a submitted claim
// refuses further edits, so without the reset it can only run once.
await page.request.post(BASE + "api/claim/reset", { data: "" });

// Start from a known draft.
await page.request.post(BASE + "api/claim", {
  headers: { "Content-Type": "application/json" },
  data: JSON.stringify({
    title: "Kyoto trip", spent_on: "2026-08-11", purpose: "client visit",
    lines: [{ desc: "train", amount: 12800, category: "Travel" }],
    note: null, approver: null, status: "Draft",
  }),
});

await page.goto(BASE, { waitUntil: "load" });
await page.waitForFunction(
  () => document.querySelector("#status")?.textContent === "loaded",
  null, { timeout: 8000 });

// --- the form is the record ------------------------------------------
const generated = await page.$$eval("#form input, #form textarea", (els) => els.map((e) => e.id));
check("every scalar field of the record has a control",
  JSON.stringify(generated) ===
    JSON.stringify(["f-title", "f-spent_on", "f-purpose", "f-note", "f-approver", "f-status"]),
  JSON.stringify(generated));
check("labels are derived from the field names when nothing overrides them",
  (await page.textContent('label[for="f-title"]')) === "Title"
  && (await page.textContent('label[for="f-status"]')) === "Status");
check("a field the user does not own is shown, not edited",
  await page.$eval("#f-status", (el) => el.readOnly));
check("the loaded values are in the generated controls",
  (await page.inputValue("#f-title")) === "Kyoto trip"
  && (await page.inputValue("#f-spent_on")) === "2026-08-11");
check("nothing is unsaved on arrival", (await disabled("save")));

// --- a view is built and torn down, and takes its watchers with it ----
// Nothing in the language makes the second half happen; store_unwatch is an
// ordinary call. What is checked is that the app makes it, because the
// alternative is measurable: before close_view existed, three round trips
// left eleven watchers running, nine of them painting into detached nodes.
const watchers = async () =>
  Number((await page.textContent("#watchers")).replace("watchers: ", ""));
const opening = await watchers();
for (let i = 0; i < 3; i++) {
  await page.click("#tab-summary");
  await page.waitForTimeout(80);
  await page.click("#tab-form");
  await page.waitForTimeout(80);
}
check("three round trips between views leave no watchers behind",
  (await watchers()) === opening, `${opening} -> ${await watchers()}`);

await page.click("#tab-summary");
await page.waitForTimeout(120);
check("the summary view is one watcher, not the form's two",
  (await watchers()) === 1, String(await watchers()));
check("and it renders from the same state",
  (await page.textContent("#sum-title")) === "Kyoto trip",
  await page.textContent("#sum-title"));
await page.click("#tab-form");
await page.waitForTimeout(120);

// --- a generated control is a real control ---------------------------
await page.fill("#f-title", "");
await page.click("#f-purpose");                 // blur title
await page.waitForFunction(
  () => document.querySelector("#err-title")?.textContent !== "", null, { timeout: 3000 })
  .catch(() => {});
check("leaving an empty required field runs the schema's rule for it",
  (await err("title")) === "Title is required", await err("title"));
await page.click("#f-title");
await page.waitForTimeout(150);
check("returning to it takes the complaint down", (await err("title")) === "");
await page.fill("#f-title", "Kyoto trip");
await page.click("#f-purpose");
await page.waitForTimeout(200);
check("fixing it clears the error", (await err("title")) === "");

// --- the total is derived from the lines -----------------------------
await page.fill("#line-0-amount", "20000");
await page.waitForTimeout(200);
check("the total follows the lines", (await page.textContent("#total")) === "¥20,000",
  await page.textContent("#total"));

// --- a rule only the server can apply --------------------------------
await page.click("#add-line");
await page.waitForTimeout(200);
await page.fill("#line-1-desc", "flight");
await page.fill("#line-1-amount", "150000");
await page.waitForTimeout(200);
await page.click("#save");
await page.waitForFunction(
  () => document.querySelector("#err-approver")?.textContent !== "", null, { timeout: 5000 });
check("the server's own rule lands in the generated error slot",
  (await err("approver")).startsWith("A claim over"), await err("approver"));

await page.fill("#f-approver", "nobody");
await page.click("#f-title");
await page.click("#save");
await page.waitForFunction(
  () => document.querySelector("#err-approver")?.textContent.startsWith("There is no"),
  null, { timeout: 5000 });
check("and so does the one about who exists", (await err("approver")).startsWith("There is no"));

await page.fill("#f-approver", "kato");
await page.click("#f-title");
await page.click("#save");
await page.waitForFunction(
  () => document.querySelector("#status")?.textContent === "saved", null, { timeout: 5000 });
check("a claim that satisfies both sides saves", (await err("approver")) === "");

// --- submit is a transition the server owns --------------------------
await page.click("#submit");
await page.waitForFunction(
  () => document.querySelector("#claim-status")?.textContent === "status: submitted",
  null, { timeout: 5000 });
check("submitting moves the status and the browser is told",
  (await page.inputValue("#f-status")) === "Submitted",
  await page.textContent("#claim-status"));
check("a submitted claim can no longer be submitted", await disabled("submit"));

await ctx.close();
rmSync(userDir, { recursive: true, force: true });
console.log(failures === 0
  ? "\nclaims browser check: all passed"
  : `\nclaims browser check: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
