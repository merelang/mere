// examples/profile/browser_check.mjs — drive the profile form in a real
// browser.
//
// run_dom_headless.mjs can fire a blur; only a browser can *cause* one.
// The behaviour this example is built around — a field is judged when the
// user leaves it and forgiven when they come back — is a claim about
// events the page never dispatches itself, so it is worth one real Chrome.
//
// Playwright is not a dependency of this repo. Install it wherever you
// like and point this at it:
//
//   npm i -D playwright && npx playwright install chromium
//   node examples/profile/browser_check.mjs
//
//   # or reuse an existing install without touching this repo:
//   PLAYWRIGHT_PATH=/path/to/node_modules/playwright \
//     node examples/profile/browser_check.mjs
//
// Missing Playwright is a SKIP, not a failure — same convention as
// scripts/parity.sh with a missing backend toolchain.
//
// Requires examples/profile/server.mere to be running:
//   mere -w examples/profile/server.mere > /tmp/profile_server.wat
//   wat2wasm --enable-tail-call /tmp/profile_server.wat -o /tmp/profile_server.wasm
//   node scripts/run_http_server.js /tmp/profile_server.wasm

import { rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BASE = process.env.PROFILE_URL || "http://localhost:8080/";

let playwright;
try {
  const spec = process.env.PLAYWRIGHT_PATH || "playwright";
  playwright = await import(spec.startsWith("/") ? join(spec, "index.mjs") : spec);
} catch (e) {
  console.log("SKIP browser check — playwright not found (set PLAYWRIGHT_PATH or npm i -D playwright)");
  process.exit(0);
}

const userDir = mkdtempSync(join(tmpdir(), "mere-profile-"));
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

const summary = () => page.textContent("#summary");
const err = (id) => page.textContent("#err-" + id);
const disabled = (id) => page.$eval("#" + id, (el) => el.disabled);

// Start from a known server state.
await page.request.post(BASE + "api/profile", {
  headers: { "Content-Type": "text/plain" },
  data: "name\tAda\nemail\tada@example.com\nbio\t\ntheme\tdark\nnotify\t1\n",
});

await page.goto(BASE, { waitUntil: "load" });
await page.waitForFunction(
  () => document.querySelector("#status")?.textContent === "loaded",
  null, { timeout: 8000 });

check("the form loads what the server has",
  (await page.inputValue("#name")) === "Ada"
  && (await page.inputValue("#theme")) === "dark"
  && (await page.isChecked("#notify")));
check("nothing is unsaved on arrival", (await summary()) === "No unsaved changes");
check("save and revert start disabled",
  (await disabled("save")) && (await disabled("revert")));

// --- judged on leaving, forgiven on returning -------------------------
await page.click("#email");
await page.fill("#email", "ada@");
await page.waitForTimeout(150);
check("typing a half-finished address says nothing", (await err("email")) === "",
  await err("email"));

await page.click("#name");            // moving to another field is what blurs email
await page.waitForFunction(
  () => document.querySelector("#err-email")?.textContent !== "",
  null, { timeout: 3000 }).catch(() => {});
check("leaving an invalid field complains",
  (await err("email")).startsWith("Email needs an @"), await err("email"));
check("and save is withheld while it is wrong", await disabled("save"));

await page.click("#email");
await page.waitForTimeout(150);
check("returning to the field takes the complaint down", (await err("email")) === "");
check("but save stays withheld until it is re-checked", await disabled("save"));

await page.fill("#email", "ada@example.org");
await page.click("#name");
await page.waitForTimeout(200);
check("fixing it and leaving clears the error and offers save",
  (await err("email")) === "" && !(await disabled("save")));

// --- derived state ----------------------------------------------------
await page.selectOption("#theme", "light");
await page.uncheck("#notify");
await page.waitForTimeout(200);
check("a select and a checkbox count as changes too",
  (await summary()) === "3 unsaved changes", await summary());

await page.click("#revert");
await page.waitForTimeout(300);
check("revert restores every control from the saved record",
  (await page.inputValue("#email")) === "ada@example.com"
  && (await page.inputValue("#theme")) === "dark"
  && (await page.isChecked("#notify"))
  && (await summary()) === "No unsaved changes", await summary());

// --- the rules only the server knows ----------------------------------
await page.fill("#name", "root");
await page.click("#email");           // blur; the client has no opinion on "root"
await page.waitForTimeout(200);
check("the client does not object to a name only the server can judge",
  (await err("name")) === "");
await page.click("#save");
await page.waitForFunction(
  () => document.querySelector("#err-name")?.textContent !== "",
  null, { timeout: 5000 });
check("a rejection from the server lands where a local one would",
  (await err("name")).startsWith("That name is reserved"), await err("name"));
check("and the change is still unsaved", (await summary()) === "1 unsaved change");

// --- a save that works ------------------------------------------------
await page.fill("#name", "Grace");
await page.click("#email");
await page.click("#save");
await page.waitForFunction(
  () => document.querySelector("#status")?.textContent === "saved",
  null, { timeout: 5000 });
check("saving makes the new value the baseline",
  (await summary()) === "No unsaved changes" && (await disabled("save")));

await ctx.close();
rmSync(userDir, { recursive: true, force: true });
console.log(failures === 0
  ? "\nprofile browser check: all passed"
  : `\nprofile browser check: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
