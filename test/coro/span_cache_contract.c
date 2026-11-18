/* Range lookup must agree with a linear oracle, including cache collisions. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static size_t lookup_searches;
#define main generated_main
#include "runtime.c"
#undef main

static void require(int ok, const char *witness) {
  if (!ok) { fprintf(stderr, "%s\n", witness); abort(); }
}
static size_t reference(__lang_scan *st, uintptr_t a) {
  for (size_t i = 0; i < st->nsp; i++)
    if (a >= st->sp[i].lo && a < st->sp[i].hi) return i;
  return SIZE_MAX;
}
static void query(__lang_scan *st, uintptr_t a) {
  size_t expected = reference(st, a);
  require(__lang_scan_span(st, a) == expected, "span cache differs from linear reference");
  if (expected != SIZE_MAX) {
    int own = 0;
    uintptr_t header = st->sp[expected].lo - sizeof(__lang_region_block);
    for (size_t i = 0; i < st->nown; i++) own |= st->ownb[i] == header;
    require(st->last_own == own, "cached ownership differs from linear reference");
  }
}
static uint64_t seed = UINT64_C(0x86d539a1b47ce209);
static uintptr_t random_word(void) {
  seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
  return (uintptr_t)seed;
}
static void traces(uintptr_t base, size_t n, uintptr_t step) {
  __lang_span *spans = calloc(n ? n : 1, sizeof(*spans));
  assert(spans);
  for (size_t i = 0; i < n; i++)
    spans[i] = (__lang_span){base + i * step, base + i * step + step / 3, NULL};
  __lang_scan st;
  memset(&st, 0, sizeof st);
  st.sp = spans; st.nsp = n;
  uintptr_t *owned = calloc(n ? n : 1, sizeof(*owned));
  assert(owned);
  for (size_t i = 0; i < n; i += 3) owned[st.nown++] = spans[i].lo - sizeof(__lang_region_block);
  st.ownb = owned;
  query(&st, 0); query(&st, UINTPTR_MAX);
  for (int repeat = 0; repeat < 4; repeat++)
    for (size_t i = 0; i < n; i++) {
      query(&st, spans[i].lo); query(&st, spans[i].hi - 1);
      query(&st, spans[i].hi); query(&st, spans[i].lo - 1);
    }
  for (size_t i = 0; i < 10000; i++) {
    query(&st, random_word());
    query(&st, base + random_word() % ((n ? n : 1) * step));
  }
  free(owned); free(spans);
}
static void warm_cache(int gaps) {
  __lang_span spans[8];
  for (size_t i = 0; i < 8; i++)
    spans[i] = (__lang_span){0x100000 + i * 0x1000, 0x100100 + i * 0x1000, NULL};
  __lang_scan st;
  memset(&st, 0, sizeof st);
  st.sp = spans; st.nsp = 8;
  size_t n = gaps ? 7 : 8;
  for (int repeat = 0; repeat < 3; repeat++)
    for (size_t i = 0; i < n; i++) query(&st, spans[i].lo + (gaps ? 0x200 : 8));
  size_t searches = lookup_searches;
  for (int repeat = 0; repeat < 100; repeat++)
    for (size_t i = 0; i < n; i++) query(&st, spans[i].lo + (gaps ? 0x200 : 8));
  require(lookup_searches == searches,
          gaps ? "gap cache repeated binary search" : "span cache repeated binary search");
  /* Revisit a cached allocation's exclusive end, then the gap's exclusive end. */
  for (size_t i = 0; i < 7; i++) { query(&st, spans[i].hi); query(&st, spans[i + 1].lo); }
}
static void current_used_limit(void) {
  __lang_region r;
  __lang_region_init(&r, 128);
  void *data = __lang_region_alloc(&r, 64);
  assert(data);
  __lang_span span = {(uintptr_t)r.base, (uintptr_t)r.base + r.blocks->pad, r.blocks};
  __lang_scan st;
  memset(&st, 0, sizeof st);
  st.sp = &span; st.nsp = 1; st.lo = 1; st.hi = 0;
  st.capseen = 16;
  st.seen = calloc(st.capseen, sizeof(*st.seen));
  st.seen_d = calloc(st.capseen, sizeof(*st.seen_d));
  assert(st.seen && st.seen_d);
  uintptr_t word = (uintptr_t)r.base + 32;
  query(&st, word); /* Warm lookup before the bump top changes. */
  r.top = r.base + 16;
  __lang_scan_words(&st, &word, &word + 1, 0);
  require(st.nwork == 0, "scanner followed unused capacity");
  word = (uintptr_t)r.top;
  __lang_scan_words(&st, &word, &word + 1, 0);
  require(st.nwork == 0, "scanner followed unused capacity");
  free(st.work); free(st.seen); free(st.seen_d);
  __lang_region_free(&r);
}
int main(void) {
  warm_cache(0); warm_cache(1);
  const size_t sizes[] = {0, 1, 2, 8, 31, 512};
  for (size_t i = 0; i < sizeof(sizes) / sizeof(*sizes); i++) {
    traces(0x100000, sizes[i], 0x1000);
    traces(0x100000, sizes[i], 0x10000); /* deliberate bucket collisions */
    traces(UINTPTR_MAX - 0x20000, sizes[i], 128);
  }
  current_used_limit();
  puts("coroutine span cache contracts passed");
  return 0;
}
