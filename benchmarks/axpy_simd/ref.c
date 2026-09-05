// axpy_simd reference (the scalar axpy program; clang vectorizes it): same LCG, same unfused arithmetic (-ffp-contract=off in the
// MANIFEST, as for matmul), same hundred passes, same bit-pattern output.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void mk(double *v, long long n, long long x) {
  for (long long i = 0; i < n; i++) {
    x = (1103515245LL * x + 12345) % 2147483648LL;
    v[i] = (double)(x % 2001 - 1000) / 1000.0;
  }
}
int main(int argc, char **argv) {
  long long n = argc > 1 ? atoll(argv[1]) : 2000000;
  double *a = malloc(sizeof(double) * n), *c = malloc(sizeof(double) * n);
  mk(a, n, 20260905);
  mk(c, n, 77770707);
  double alpha = 1.5;
  for (int r = 0; r < 100; r++)
    for (long long i = 0; i < n; i++) c[i] = c[i] + alpha * a[i];
  double s = 0.0;
  for (long long i = 0; i < n; i++) s = s + c[i];
  unsigned long long bits;
  memcpy(&bits, &s, 8);
  printf("n %lld\n", n);
  printf("checksum %llu %llu\n", bits >> 32, bits & 0xFFFFFFFFULL);
  return 0;
}
