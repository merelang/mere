/* matmul reference, C. Compiled with -ffp-contract=off (see MANIFEST cflags):
   clang fuses a*b+c into one FMA by default on arm64, which rounds once
   instead of twice and produces different bits from every other row here. */
#include <stdio.h>
#include <stdlib.h>

static void mk(double *v, long long n, long long seed) {
  long long x = seed;
  for (long long i = 0; i < n * n; i++) {
    x = (1103515245LL * x + 12345LL) % 2147483648LL;
    v[i] = (double)(x % 2001 - 1000) / 1000.0;
  }
}

int main(int argc, char **argv) {
  long long n = argc > 1 ? atoll(argv[1]) : 128;
  double *a = malloc(sizeof(double) * n * n);
  double *b = malloc(sizeof(double) * n * n);
  double *c = malloc(sizeof(double) * n * n);
  mk(a, n, 20260825);
  mk(b, n, 77770707);
  for (long long i = 0; i < n; i++)
    for (long long j = 0; j < n; j++) {
      double acc = 0.0;
      for (long long k = 0; k < n; k++) acc = acc + a[i * n + k] * b[k * n + j];
      c[i * n + j] = acc;
    }
  double s = 0.0;
  for (long long i = 0; i < n * n; i++) s = s + c[i];
  unsigned long long bits;
  __builtin_memcpy(&bits, &s, 8);
  printf("n %lld\n", n);
  printf("checksum %llu %llu\n", bits >> 32, bits & 0xFFFFFFFFULL);
  return 0;
}
