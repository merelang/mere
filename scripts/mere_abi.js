// scripts/mere_abi.js — the contract between a compiled module and its host.
//
// A Wasm module and the JS that runs it agree on more than function names:
// how a value is represented, how a string is laid out, how a closure is
// called. None of that is in the import list, so a host built against an
// older compiler links cleanly and then produces empty strings or crashes
// on the first call. Every bug of that shape found so far — a request line
// that arrived as "", a password hash that hashed to nothing, a result set
// of empty columns — was this mismatch failing quietly.
//
// So the compiler stamps an ABI number into every module and hosts check
// it before doing anything. A mismatch is now a refusal at startup that
// names both sides, instead of a wrong answer later.
//
// ABI 1
//   - a Mere value is i64; addresses are the low 32 bits
//   - a str is `[i32 len][bytes][NUL]`, and the value points at byte0, so
//     the length is at ptr-4. BOTH compilers lay it out this way: the
//     self-hosted Wasm backend emitted a bare NUL-terminated buffer while
//     stamping this same number until v0.1.263, and a host that trusted the
//     header printed half a megabyte of zeros for one of its strings
//   - a closure value is `{ i32 env, i32 fn_idx }`
//   - a closure is called as (param i64 i64) (result i64)
//   - compound fields are 8-byte slots; variant cells are
//     `{ i64 tag, i64 payload }`
//
// Bump this when any of that changes, and fix the hosts in the same
// commit — that is the whole point of the number existing.

const MERE_ABI = 1;

// Throws unless `instance` was built by a compiler this host understands.
// `who` names the host in the message so the fix is obvious.
function checkAbi(instance, who) {
  const g = instance.exports.__mere_abi;
  const found = g === undefined ? undefined : (g.value !== undefined ? g.value : g);
  if (found === undefined) {
    throw new Error(
      `${who}: this module exports no __mere_abi, so it predates ABI ${MERE_ABI}. ` +
      `Recompile it with a current mere — the value representation and string ` +
      `layout have changed, and linking would succeed while producing empty ` +
      `strings at runtime.`);
  }
  if (found !== MERE_ABI) {
    throw new Error(
      `${who}: module ABI ${found}, host ABI ${MERE_ABI}. ` +
      (found < MERE_ABI
        ? `Recompile the module with a current mere.`
        : `Update the host — it is older than the compiler that built this module.`));
  }
}

module.exports = { MERE_ABI, checkAbi };
