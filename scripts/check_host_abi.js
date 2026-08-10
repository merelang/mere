// scripts/check_host_abi.js — hold the one duplicated host copy in step.
//
// Every JS host shares scripts/mere_host.js except contrib/dom/dom.glue.js,
// which is an ES module a browser fetches and therefore cannot require()
// it. That copy is the only place the boundary layout is written twice, and
// duplication is precisely how the previous round of bugs happened, so it
// gets checked rather than trusted.
//
//   node scripts/check_host_abi.js
//
// Exits non-zero on a mismatch. Cheap enough to run in CI next to the
// test suite.

const fs = require("fs");
const path = require("path");
const { MERE_ABI } = require("./mere_abi.js");

const glue = fs.readFileSync(
  path.join(__dirname, "..", "contrib", "dom", "dom.glue.js"), "utf8");

let failures = 0;
const check = (label, ok, detail) => {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${detail ? " — " + detail : ""}`);
  if (!ok) failures++;
};

const declared = glue.match(/^const MERE_ABI = (\d+);/m);
check("contrib/dom declares an ABI", declared !== null,
  declared ? `MERE_ABI = ${declared[1]}` : "no `const MERE_ABI = N` found");

if (declared) {
  check("contrib/dom agrees with scripts/mere_abi.js",
    Number(declared[1]) === MERE_ABI,
    `dom=${declared[1]} shared=${MERE_ABI}`);
}

// The three facts that copy has to get right. Each was wrong in some host
// at some point, and each failed silently at runtime rather than at link
// time, so grep for the shape rather than trusting review.
check("writes the str length header",
  /setInt32\(start, utf8\.length, true\)/.test(glue),
  "writeStr must emit [i32 len] before the bytes");
check("returns a pointer to byte0",
  /return start \+ 4;/.test(glue),
  "the str value points past the header");
check("calls closures with BigInt args",
  /fn\(BigInt\([^)]*\), *(?:BigInt\([^)]*\)|0n)\)/.test(glue),
  "the closure type is (param i64 i64) (result i64)");

console.log(failures === 0
  ? "\nhost ABI: contrib/dom is in step"
  : `\nhost ABI: ${failures} mismatch(es)`);
process.exit(failures === 0 ? 0 : 1);
