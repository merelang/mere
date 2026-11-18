/* Compare complete unsigned multisets, including duplicates and high bits. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t sort_calls, scratch_live;
static int fail_scratch;
static void *pin_test_malloc(size_t n) {
  if (fail_scratch) return NULL;
  void *p = malloc(n);
  if (p) scratch_live++;
  return p;
}
static void pin_test_free(void *p) {
  if (p) { assert(scratch_live); scratch_live--; }
  free(p);
}
static void pin_test_qsort(void *p, size_t n, size_t size,
                           int (*compare)(const void *, const void *)) {
  sort_calls++;
  qsort(p, n, size, compare);
}
#define malloc pin_test_malloc
#define free pin_test_free
#define qsort pin_test_qsort
#define main generated_main
#include "runtime.c"
#undef main
#undef malloc
#undef free
#undef qsort

static int reference_compare(const void *a, const void *b) {
  uintptr_t left = *(const uintptr_t *)a, right = *(const uintptr_t *)b;
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}
static uint64_t state = UINT64_C(0xd1766b98237ac541);
static uintptr_t random_word(void) {
  state ^= state << 13; state ^= state >> 7; state ^= state << 17;
  return (uintptr_t)state;
}
static void require(int ok, const char *witness) {
  if (!ok) { fprintf(stderr, "%s\n", witness); abort(); }
}

static void check(size_t n, unsigned pattern, int allocation_failure) {
  uintptr_t *guarded = malloc((n + 2) * sizeof(*guarded));
  uintptr_t *expected = malloc((n ? n : 1) * sizeof(*expected));
  assert(guarded && expected);
  uintptr_t *words = guarded + 1;
  guarded[0] = UINTPTR_MAX - 11; guarded[n + 1] = UINTPTR_MAX - 19;
  for (size_t i = 0; i < n; i++) {
    uintptr_t w = random_word();
    switch (pattern) {
      case 0: w = i; break;
      case 1: w = n - i; break;
      case 2: w = UINTPTR_MAX; break;
      case 3: w = (i % 5) * (UINTPTR_MAX / 5); break;
      case 4: w &= UINT32_MAX; break;
      case 5: w = (UINTPTR_MAX & ~(uintptr_t)0xffffff) | (w & 0xffffff); break;
      case 6: w = i % 2 ? UINTPTR_MAX : 0; break;
      case 7: break;
      default: w = (w & 255) << ((pattern - 8) * 8); break;
    }
    words[i] = expected[i] = w;
  }
  int varying = 0;
  for (size_t i = 1; i < n; i++) varying |= words[i] != words[0];
  qsort(expected, n, sizeof(*expected), reference_compare);
  size_t calls = sort_calls;
  fail_scratch = allocation_failure;
  __lang_pin_sort(words, n);
  fail_scratch = 0;
  require(!memcmp(expected, words, n * sizeof(*words)), "pin sort differs from reference");
  require(guarded[0] == UINTPTR_MAX - 11 && guarded[n + 1] == UINTPTR_MAX - 19,
          "pin sort changed a guard");
  require(!scratch_live, "pin sort scratch retained");
  if (n >= 256 && varying && !allocation_failure)
    require(sort_calls == calls, "large pin sort used qsort");
  if (n > 1 && (n < 256 || (varying && allocation_failure)))
    require(sort_calls == calls + 1, "pin sort fallback missing");
  free(expected); free(guarded);
}

int main(void) {
  __lang_pin_sort(NULL, 0);
  const size_t sizes[] = {0, 1, 2, 31, 255, 256, 257, 511, 512, 513, 1023, 4096, 16384};
  for (size_t s = 0; s < sizeof(sizes) / sizeof(*sizes); s++)
    for (unsigned pattern = 0; pattern < 8 + sizeof(uintptr_t); pattern++)
      for (int failure = 0; failure < 2; failure++) check(sizes[s], pattern, failure);
  puts("coroutine pin sort contracts passed");
  return 0;
}
