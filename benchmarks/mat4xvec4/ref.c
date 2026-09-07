/* mat4xvec4 reference, C -- the scalar program, which clang vectorizes on its
   own. Compiled with -ffp-contract=off (see MANIFEST cflags): clang fuses
   a*b + c into one FMA by default on arm64, which rounds once instead of twice
   and produces different bits from every other row here.

   Column-major, m[4*j + i] = row i of column j, and each output component
   accumulates column 0, 1, 2, 3 in that order -- the order is part of the
   answer, and the Mere rows walk it the same way. */
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
  double m[16];
  double *vs = malloc(sizeof(double) * 4 * n);
  mk(m, 16, 20260907);
  mk(vs, 4 * n, 77770707);

  double ax = 0.0, ay = 0.0, az = 0.0, aw = 0.0;
  for (int r = 0; r < 5000; r++) {
    for (long long i = 0; i < n; i++) {
      double x = vs[4 * i], y = vs[4 * i + 1];
      double z = vs[4 * i + 2], w = vs[4 * i + 3];
      ax = ax + (m[0] * x + m[4] * y + m[8] * z + m[12] * w);
      ay = ay + (m[1] * x + m[5] * y + m[9] * z + m[13] * w);
      az = az + (m[2] * x + m[6] * y + m[10] * z + m[14] * w);
      aw = aw + (m[3] * x + m[7] * y + m[11] * z + m[15] * w);
    }
  }
  double s = ax + ay + az + aw;
  unsigned long long bits;
  __builtin_memcpy(&bits, &s, 8);
  printf("n %lld\n", n);
  printf("checksum %llu %llu\n", bits >> 32, bits & 0xFFFFFFFFULL);
  return 0;
}
