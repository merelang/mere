/* mat4xvec4_f32 reference, C -- the scalar single-precision program, which
   clang vectorizes on its own. -ffp-contract=off (see MANIFEST cflags): clang
   fuses a*b + c into one FMA by default on arm64, which rounds once instead of
   twice and gives different bits from every other row here.

   The four accumulators are folded left to right at the end, which is what
   Mere's f32x4_reduce_add is specified to do. */
#include <stdio.h>
#include <stdlib.h>

static void mk(double *v, long long count, long long seed) {
  long long x = seed;
  for (long long i = 0; i < count; i++) {
    x = (1103515245LL * x + 12345LL) % 2147483648LL;
    v[i] = (double)(x % 2001 - 1000) / 1000.0;
  }
}

int main(int argc, char **argv) {
  long long n = argc > 1 ? atoll(argv[1]) : 20000;
  double md[16];
  double *vd = malloc(sizeof(double) * 4 * n);
  mk(md, 16, 20260907);
  mk(vd, 4 * n, 77770707);
  /* The narrowing is the same one the lanes do: the inputs are doubles and a
     lane is a float. */
  float m[16]; for (int i = 0; i < 16; i++) m[i] = (float)md[i];
  float *vs = malloc(sizeof(float) * 4 * n);
  for (long long i = 0; i < 4 * n; i++) vs[i] = (float)vd[i];

  float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;
  for (int r = 0; r < 5000; r++) {
    for (long long i = 0; i < n; i++) {
      float x = vs[4 * i], y = vs[4 * i + 1];
      float z = vs[4 * i + 2], w = vs[4 * i + 3];
      a0 = a0 + (m[0] * x + m[4] * y + m[8] * z + m[12] * w);
      a1 = a1 + (m[1] * x + m[5] * y + m[9] * z + m[13] * w);
      a2 = a2 + (m[2] * x + m[6] * y + m[10] * z + m[14] * w);
      a3 = a3 + (m[3] * x + m[7] * y + m[11] * z + m[15] * w);
    }
  }
  float sf = a0 + a1; sf = sf + a2; sf = sf + a3;
  double s = (double)sf;
  unsigned long long bits;
  __builtin_memcpy(&bits, &s, 8);
  printf("n %lld\n", n);
  printf("checksum %llu %llu\n", bits >> 32, bits & 0xFFFFFFFFULL);
  return 0;
}
