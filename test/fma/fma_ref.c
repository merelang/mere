/* test/fma/fma_ref.c -- the oracle for test/fma/fma_bits.mere.
 *
 * The same inputs, drawn from the same generator, through the C library's
 * fma(3) -- the hardware instruction on arm64 and on x86 with FMA, glibc's
 * correctly rounded software elsewhere. Every line here mirrors a line of the
 * .mere program; a change to one is a change to both.
 *
 * Built WITHOUT -ffast-math and with contraction off, so that the only fused
 * operation in this file is the one it names.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#pragma STDC FP_CONTRACT OFF

static long long nx(long long x) { return (x * 1103515245LL + 12345) % 2147483648LL; }

static double of_bits(long long hi, long long lo) {
  uint64_t u = ((uint64_t)hi << 32) | (uint64_t)lo; double d; memcpy(&d, &u, 8); return d;
}
static long long bits_hi(double d) { uint64_t u; memcpy(&u, &d, 8); return (long long)(u >> 32); }
static long long bits_lo(double d) { uint64_t u; memcpy(&u, &d, 8); return (long long)(u & 0xffffffffULL); }

static double special(int k) {
  switch (k) {
  case 0: return of_bits(0, 0);
  case 1: return of_bits(2147483648LL, 0);
  case 2: return 1.0;
  case 3: return 0.0 - 1.0;
  case 4: return of_bits(1072693248LL, 1);
  case 5: return of_bits(1072693247LL, 4294967295LL);
  case 6: return of_bits(0, 1);
  case 7: return of_bits(1048575LL, 4294967295LL);
  case 8: return of_bits(1048576LL, 0);
  case 9: return of_bits(2146435071LL, 4294967295LL);
  case 10: return of_bits(2146435072LL, 0);
  case 11: return of_bits(4293918720LL, 0);
  case 12: return of_bits(2146959360LL, 0);
  case 13: return of_bits(509607936LL, 0);
  case 14: return of_bits(1608515584LL, 0);
  case 15: return of_bits(1572864LL, 0);
  case 16: return of_bits(1069128089LL, 2576980378LL);
  case 17: return of_bits(3221749760LL, 0);
  case 18: return of_bits(2145386496LL, 0);
  case 19: return of_bits(0, 3);
  case 20: return of_bits(4292870143LL, 4294967295LL);
  default: return of_bits(2657091584LL, 0);
  }
}

static double any_bits(long long r1, long long r2, long long r3) {
  return of_bits((r1 % 65536) * 65536 + r2 % 65536, (r3 % 65536) * 65536 + (r1 / 65536) % 65536);
}

static double with_exp(long long e, long long r1, long long r2) {
  long long hi = (e + 1023) * 1048576 + r1 % 1048576;
  double d = of_bits(hi, (r2 * 2 + r1 % 2) % 4294967296LL);
  return ((r1 / 1048576) % 2 == 0) ? d : 0.0 - d;
}

static long long fold1(long long acc, double r) {
  long long hi = (r != r) ? 2146959360LL : bits_hi(r);
  long long lo = (r != r) ? 0 : bits_lo(r);
  return ((acc * 31 + hi) % 1000000007 * 31 + lo) % 1000000007;
}

static long long step(long long acc, double a, double b, double c) {
  double l0 = fma(a, b, c);   /* lane 0 of f64x2_fma: (a, b, c) */
  double l1 = fma(b, c, a);   /* lane 1: (b, c, a) */
  return fold1(fold1(fold1(acc, fma(a, b, c)), l0), l1);
}

static long long clampe(long long e) { return e < -1022 ? -1022 : e > 1023 ? 1023 : e; }

int main(void) {
  long long acc = 7;
  for (int i = 0; i < 10648; i++)
    acc = step(acc, special(i / 484), special((i / 22) % 22), special(i % 22));
  printf("specials %lld\n", acc);

  long long x = 12345; acc = 7;
  for (int i = 0; i < 20000; i++) {
    long long x1 = nx(x), x2 = nx(x1), x3 = nx(x2), x4 = nx(x3), x5 = nx(x4);
    long long x6 = nx(x5), x7 = nx(x6), x8 = nx(x7), x9 = nx(x8);
    acc = step(acc, any_bits(x1, x2, x3), any_bits(x4, x5, x6), any_bits(x7, x8, x9));
    x = x9;
  }
  printf("random %lld\n", acc);

  x = 54321; acc = 7;
  for (int i = 0; i < 20000; i++) {
    long long x1 = nx(x), x2 = nx(x1), x3 = nx(x2), x4 = nx(x3), x5 = nx(x4);
    long long x6 = nx(x5), x7 = nx(x6), x8 = nx(x7);
    long long sum = (x1 % 2201) - 1140;
    long long ea = clampe(sum / 2 + (x2 % 101) - 50);
    long long eb = clampe(sum - ea);
    long long ec = clampe(ea + eb + (x3 % 129) - 64);
    acc = step(acc, with_exp(ea, x4, x5), with_exp(eb, x6, x7), with_exp(ec, x8, x3));
    x = x8;
  }
  printf("edges %lld\n", acc);

  for (int near = 0; near <= 1; near++) {
    x = near ? 4242 : 999; acc = 7;
    for (int i = 0; i < 20000; i++) {
      long long x1 = nx(x), x2 = nx(x1), x3 = nx(x2), x4 = nx(x3), x5 = nx(x4);
      double a = with_exp((x1 % 401) - 200, x2, x3);
      double b = with_exp((x4 % 401) - 200, x5, x1);
      double p = 0.0 - a * b;
      double c = near ? p * (1.0 + (double)(x5 % 64 - 32) * 0.0000000000000002220446049250313) : p;
      acc = step(acc, a, b, c);
      x = x5;
    }
    printf("%s %lld\n", near ? "near" : "cancel", acc);
  }

  x = 777; acc = 7;
  for (int i = 0; i < 20000; i++) {
    long long x1 = nx(x), x2 = nx(x1), x3 = nx(x2), x4 = nx(x3), x5 = nx(x4), x6 = nx(x5);
    long long sa = (x1 % 1200) - 600, sb = (x2 % 200) - 100;
    double a = (double)((x3 % 67108864) | 67108865) * of_bits((sa + 1023) * 1048576, 0);
    double b = (double)((x4 % 67108864) | 67108865) * of_bits((sb + 1023) * 1048576, 0);
    long long ec0 = 52 + sa + sb - 60 - x5 % 1000;
    long long ec = ec0 < -1022 ? -1022 : ec0;
    acc = step(acc, a, b, with_exp(ec, x6, x5));
    x = x6;
  }
  printf("ties %lld\n", acc);
  return 0;
}
