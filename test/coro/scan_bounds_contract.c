/* A conservative scan reads from a pointer up to the next allocation's start
   and no further (each bump block's map of where its allocations begin).
   These are the cases where that bound could lose a root, and the one it is
   for:
     - next:      a held node's neighbour is dead: its number is not reported
     - held:      the neighbour is held too: both are reported
     - interior:  a pointer into the middle of an allocation reads the rest of
                  it, and not the allocation after it
     - last:      the block's last allocation is read up to the bump pointer
     - big:       an allocation in a block of its own (no map) is read 16
                  words, as before
     - reused:    a region's bytes handed out again (released to the cache and
                  acquired) hold a big node where small ones began: the big
                  node's last word is still reported -- a start left behind
                  would end the read inside it
     - invariant: after each step, no block has a start at or above its bump
                  pointer
   The scan is the runtime's own (__lang_scan_words over the given words, then
   the work it queues), as coro_scan_ints runs it for a stopped stack. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define main generated_main
#include "runtime.c"
#undef main

static int found(uintptr_t* words, size_t nwords, long long probe) {
  __lang_scan st;
  memset(&st, 0, sizeof st);
  st.lo = 5000; st.hi = 6000;
  st.ownb = (uintptr_t*)malloc(sizeof(uintptr_t));
  assert(st.ownb);
  __lang_scan_spans();
  st.sp = __lang_scan_sp; st.nsp = __lang_scan_nsp;
  st.capfound = 64;
  st.found = (long long*)calloc(st.capfound, sizeof(long long));
  st.capseen = 1 << 8;
  st.seen = (uintptr_t*)calloc(st.capseen, sizeof(uintptr_t));
  st.seen_d = (int*)calloc(st.capseen, sizeof(int));
  assert(st.found && st.seen && st.seen_d);
  __lang_scan_words(&st, words, words + nwords, 0);
  for (size_t done = 0; done < st.nwork; done++)
    __lang_scan_words(&st, (uintptr_t*)st.work[3 * done], (uintptr_t*)st.work[3 * done + 1], (int)st.work[3 * done + 2]);
  int hit = 0;
  for (size_t i = 0; i < st.capfound; i++)
    if (st.found[i] == probe + 1) hit = 1;
  free(st.work); free(st.seen); free(st.seen_d); free(st.ownb); free(st.found);
  return hit;
}
#define FOUND(words, probe) found((words), sizeof(words) / sizeof((words)[0]), (probe))

static void no_start_at_or_above_top(void) {
  for (int pass = 0; pass < 2; pass++)
    for (__lang_region_block* b = pass ? __lang_blk_dl : __lang_blk_tl; b; b = b->gnext) {
      if (!b->starts || !b->owner || b->owner->blocks != b || !b->owner->top) continue;
      size_t from = (size_t)(b->owner->top - (char*)(b + 1)) >> 3, units = b->pad >> 3;
      for (size_t i = from; i < units; i++)
        assert(!(b->starts[i >> 3] & (1u << (i & 7))) && "start at or above the bump pointer");
    }
}

static long long* node(__lang_region* r, size_t words, long long first) {
  long long* p = (long long*)__lang_region_alloc(r, words * sizeof(long long));
  for (size_t i = 0; i < words; i++) p[i] = 0;
  p[0] = first;
  return p;
}

int main(void) {
  __lang_region r;
  __lang_region_init(&r, 1 << 16);

  /* next / held: two nodes side by side, 2 and 3 words */
  long long* x = node(&r, 2, 1); x[1] = 5001;
  long long* y = node(&r, 3, 2); y[1] = 5002; y[2] = 5003;
  uintptr_t only_x[] = { (uintptr_t)x };
  assert(FOUND(only_x, 5001) && "held node");
  assert(!FOUND(only_x, 5002) && "read past the allocation into a dead neighbour");
  uintptr_t both[] = { (uintptr_t)x, (uintptr_t)y };
  assert(FOUND(both, 5001) && FOUND(both, 5002) && FOUND(both, 5003) && "a held neighbour");
  no_start_at_or_above_top();

  /* interior: into the middle of a 4-word node, then a neighbour */
  long long* w = node(&r, 4, 3); w[2] = 5011; w[3] = 5012;
  long long* z = node(&r, 2, 4); z[1] = 5013;
  uintptr_t mid[] = { (uintptr_t)(w + 2) };
  assert(FOUND(mid, 5011) && FOUND(mid, 5012) && "the rest of the allocation");
  assert(!FOUND(mid, 5013) && "an interior pointer read into the next allocation");
  (void)z;

  /* last: the block's last allocation, read up to the bump pointer */
  long long* l = node(&r, 3, 5); l[2] = 5021;
  uintptr_t last[] = { (uintptr_t)l };
  assert(FOUND(last, 5021) && "the last allocation");
  no_start_at_or_above_top();

  /* big: a block of its own has no map and is read 16 words */
  long long* g = node(&r, (1 << 16) / 8, 6); g[10] = 5031;
  __lang_region_block* gb = (__lang_region_block*)g - 1;
  assert(gb->starts == NULL && "a dedicated block has no map");
  uintptr_t big[] = { (uintptr_t)g };
  assert(FOUND(big, 5031) && "a dedicated block");

  /* reused: small nodes, released to the cache, acquired again */
  __lang_region* q = __lang_region_block_acquire("scan_bounds");
  for (int i = 0; i < 200; i++) (void)node(q, 2, 7);
  __lang_region_block_release(q);
  no_start_at_or_above_top();
  __lang_region* q2 = __lang_region_block_acquire("scan_bounds");
  assert(q2 == q && "the cached region is handed out again");
  long long* b10 = node(q2, 10, 8); b10[9] = 5041;
  uintptr_t reused[] = { (uintptr_t)b10 };
  assert(FOUND(reused, 5041) && "a start left behind ended the read inside a live node");
  no_start_at_or_above_top();
  __lang_region_block_release(q2);

  __lang_region_free(&r);
  printf("coroutine scan bounds contracts passed\n");
  return 0;
}
