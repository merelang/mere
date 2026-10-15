/* test/llvmffi/user_shim.c -- a user's own C side of two `extern fn`s
   (scripts/llvm_ffi_check.sh, v0.1.670). Compiled with optimisation, so the
   negation is a 32-bit instruction whose result leaves the upper half of the
   register zero: a caller that reads the `int` as 64 bits sees 4294967291
   for -5, which is what the LLVM backend did until it declared C's `int`. */
#include <stdio.h>
int mere_ffi_neg(int x) { return -x; }
const char* mere_ffi_greet(const char* who) {
  static char b[64];
  snprintf(b, sizeof b, "hi %s", who);
  return b;   /* a bare C string: no length header in front of it */
}
