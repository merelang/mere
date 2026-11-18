/* Compare the cached index with the independently walked live registries. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
static _Thread_local size_t full_sorts;
static void tracked_qsort(void *p, size_t n, size_t size, int (*cmp)(const void *, const void *)) {
  full_sorts++;
  qsort(p, n, size, cmp);
}
#define qsort tracked_qsort
#define main generated_main
#include "runtime.c"
#undef main
#undef qsort

static void snapshot(void) {
  __lang_scan_spans();
  pthread_mutex_lock(&__lang_blk_dl_lock);
  size_t n = 0;
  for (int pass = 0; pass < 2; pass++)
    for (__lang_region_block *b = pass ? __lang_blk_dl : __lang_blk_tl; b; b = b->gnext) n++;
  __lang_span *expected = calloc(n ? n : 1, sizeof(*expected));
  assert(expected);
  size_t at = 0;
  for (int pass = 0; pass < 2; pass++)
    for (__lang_region_block *b = pass ? __lang_blk_dl : __lang_blk_tl; b; b = b->gnext)
      expected[at++] = (__lang_span){(uintptr_t)(b + 1), (uintptr_t)(b + 1) + b->pad, b};
  pthread_mutex_unlock(&__lang_blk_dl_lock);
  qsort(expected, n, sizeof(*expected), __lang_span_cmp);
  assert(n == __lang_scan_nsp);
  for (size_t i = 0; i < n; i++) {
    assert(expected[i].lo == __lang_scan_sp[i].lo);
    assert(expected[i].hi == __lang_scan_sp[i].hi);
    assert(expected[i].b == __lang_scan_sp[i].b);
  }
  assert(__lang_scan_tlgen == __lang_blk_tl_gen);
  assert(!__lang_scan_nchanges && !__lang_scan_overflow);
  free(expected);
}

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready = PTHREAD_COND_INITIALIZER;
static int phase;

static void wait_for(int value) {
  pthread_mutex_lock(&gate);
  while (phase < value) pthread_cond_wait(&ready, &gate);
  pthread_mutex_unlock(&gate);
}
static void publish(int value) {
  pthread_mutex_lock(&gate);
  phase = value;
  pthread_cond_broadcast(&ready);
  pthread_mutex_unlock(&gate);
}

static void *worker(void *unused) {
  (void)unused;
  __lang_region private_region, shared;
  __lang_region_init(&private_region, 256);
  snapshot();
  __lang_region_init_x(&shared, 512, 1);
  publish(1);
  wait_for(2);
  __lang_region_free(&shared);
  publish(3);
  wait_for(4);
  snapshot();
  __lang_region_free(&private_region);
  snapshot();
  return NULL;
}

int main(void) {
  __lang_region a, b;
  __lang_region_init(&a, 128);
  __lang_region_init(&b, 256);
  snapshot();
  size_t sorts = full_sorts;
  for (int i = 0; i < 300; i++) {
    __lang_region r;
    __lang_region_init(&r, 128 + 16 * (i % 17));
    snapshot();
    __lang_region_free(&r);
    snapshot();
    assert(full_sorts == sorts); /* additions/removals must use the fast path */
  }
  for (int round = 0; round < 50; round++) {
    /* The queued add may already refer to freed/reused storage at scan time.
       Applying the log must use its captured bounds, never that old header. */
    for (int i = 0; i < 8; i++) {
      __lang_region r;
      __lang_region_init(&r, 160 + 16 * i);
      __lang_region_free(&r);
    }
    snapshot();
    assert(full_sorts == sorts);
  }
  void *large = __lang_region_alloc(&a, 2000);
  snapshot();
  large = __lang_region_grow(&a, large, 2000, 9000);
  assert(large);
  snapshot();
  assert(full_sorts == sorts); /* relocated or in-place dedicated-block growth */

  __lang_region burst[__LANG_SCAN_CHANGE_CAP + 10];
  for (size_t i = 0; i < sizeof(burst) / sizeof(*burst); i++) __lang_region_init(&burst[i], 128);
  snapshot();
  assert(full_sorts > sorts); /* bounded log overflow rebuilds the real list */
  for (size_t i = 0; i < sizeof(burst) / sizeof(*burst); i++) __lang_region_free(&burst[i]);
  snapshot();

  pthread_t thread;
  sorts = full_sorts;
  assert(!pthread_create(&thread, NULL, worker, NULL));
  wait_for(1);
  snapshot();
  assert(full_sorts > sorts); /* shared allocation invalidates this thread */
  sorts = full_sorts;
  publish(2);
  wait_for(3);
  snapshot();
  assert(full_sorts > sorts); /* another thread's shared removal also invalidates */
  publish(4);
  assert(!pthread_join(thread, NULL));
  __lang_region_free(&a);
  __lang_region_free(&b);
  snapshot();
  puts("coroutine scan index contracts passed");
  return 0;
}
