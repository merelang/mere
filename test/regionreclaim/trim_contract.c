/* Trimming must preserve active data and the retained cache prefix. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <sched.h>
#include <stdatomic.h>
#define main generated_main
#include "runtime.c"
#undef main

static void drain(void) {
  while (__lang_region_cache_n) {
    __lang_region *r = __lang_region_cache[--__lang_region_cache_n];
    __lang_region_free(r);
    free(r);
  }
}
static void cycle(int grown, int quiet) {
  assert(__lang_region_cache_n == 0);
  __lang_region *live = __lang_region_block_acquire("live during trim");
  unsigned char *bytes = __lang_region_alloc(live, 256);
  memset(bytes, 0x5A, 256);
  __lang_region *regions[80], *keep[8];
  for (int i = 0; i < 80; i++) {
    regions[i] = __lang_region_block_acquire("trim burst");
    if (grown && i >= 72) *(volatile char *)__lang_region_alloc(regions[i], 4u << 20) = 1;
  }
  for (int i = 79; i >= 0; i--) __lang_region_block_release(regions[i]);
  int count = __LANG_REGION_CACHE_CAP;
  assert(__lang_region_cache_n == count && __lang_region_active_n == 1);
  int retained = count < 8 ? count : 8;
  for (int i = 0; i < retained; i++) keep[i] = __lang_region_cache[i];
  __lang_mem_trim();
  __lang_mem_trim();
  assert(__lang_region_cache_n == retained && __lang_region_active_n == 1);
  for (int i = 0; i < retained; i++) assert(keep[i] == __lang_region_cache[i]);
  for (int i = 0; i < 256; i++) assert(bytes[i] == 0x5A);
#ifdef __APPLE__
  if (quiet) assert(__lang_blk_keep_len == 0 && __lang_blk_keep_bytes == 0);
#else
  (void)quiet;
#endif
  for (int i = 0; i < retained; i++) {
    regions[i] = __lang_region_block_acquire("reuse trimmed cache");
    assert(regions[i] == keep[retained - i - 1]);
  }
  for (int i = retained - 1; i >= 0; i--) __lang_region_block_release(regions[i]);
  for (int i = 0; i < 256; i++) assert(bytes[i] == 0x5A);
  __lang_region_block_release(live);
  assert(__lang_region_active_n == 0);
  drain();
  __lang_mem_trim();
}
/* A trim after real work (__LANG_MEM_TRIM_WORK acquisitions since the last
   trim) releases the whole cache, grown blocks included, and still keeps the
   active region and its bytes; the trim right after it is a quiet one. The
   work is stood for by moving this thread's trim mark back. */
static void cycle_after_work(int grown) {
  assert(__lang_region_cache_n == 0);
  __lang_region *live = __lang_region_block_acquire("live during trim after work");
  unsigned char *bytes = __lang_region_alloc(live, 256);
  memset(bytes, 0xA5, 256);
  __lang_region *regions[80];
  for (int i = 0; i < 80; i++) {
    regions[i] = __lang_region_block_acquire("work burst");
    if (grown && i >= 72) *(volatile char *)__lang_region_alloc(regions[i], 4u << 20) = 1;
  }
  for (int i = 79; i >= 0; i--) __lang_region_block_release(regions[i]);
  assert(__lang_region_cache_n == __LANG_REGION_CACHE_CAP && __lang_region_active_n == 1);
  __lang_mem_trim_seq = __lang_region_seq_ctr - __LANG_MEM_TRIM_WORK;
  __lang_mem_trim();
  assert(__lang_region_cache_n == 0 && __lang_region_active_n == 1);
  for (int i = 0; i < 256; i++) assert(bytes[i] == (unsigned char)0xA5);
  /* ...the very next trim follows no work: nothing to release, nothing lost */
  __lang_region *again = __lang_region_block_acquire("after the release");
  __lang_region_block_release(again);
  __lang_mem_trim();
  assert(__lang_region_cache_n == 1 && __lang_region_active_n == 1);
  drain();
  __lang_region_block_release(live);
  assert(__lang_region_active_n == 0);
  drain();
}
/* ...and the work done for real: __LANG_MEM_TRIM_WORK acquisitions, nearly
   all of them from the cache, move the counter far enough that the next trim
   releases the cache -- so the counting is tested, not only the release. */
static void cycle_real_work(void) {
  assert(__lang_region_cache_n == 0);
  __lang_mem_trim();
  for (int i = 0; i < __LANG_MEM_TRIM_WORK; i++)
    __lang_region_block_release(__lang_region_block_acquire("real work"));
  __lang_region *regions[10];
  for (int i = 0; i < 10; i++) regions[i] = __lang_region_block_acquire("fill after work");
  for (int i = 9; i >= 0; i--) __lang_region_block_release(regions[i]);
  assert(__lang_region_cache_n == (__LANG_REGION_CACHE_CAP < 10 ? __LANG_REGION_CACHE_CAP : 10));
  __lang_mem_trim();
  assert(__lang_region_cache_n == 0 && __lang_region_active_n == 0);
}
/* Another thread's trim after work leaves this thread's cache as it was. */
static _Atomic int side_filled, side_trimmed;
static void *side(void *unused) {
  (void)unused;
  __lang_region *regions[12];
  for (int i = 0; i < 12; i++) regions[i] = __lang_region_block_acquire("side cache");
  for (int i = 11; i >= 0; i--) __lang_region_block_release(regions[i]);
  int n = __lang_region_cache_n;
  assert(n == (__LANG_REGION_CACHE_CAP < 12 ? __LANG_REGION_CACHE_CAP : 12));
  atomic_store(&side_filled, 1);
  while (!atomic_load(&side_trimmed)) sched_yield();
  assert(__lang_region_cache_n == n);
  drain();
  return NULL;
}
static void *worker(void *unused) {
  (void)unused;
  for (int i = 0; i < 4; i++) cycle(i % 2, 0);
  cycle_after_work(1);
  cycle_real_work();
  return NULL;
}
int main(void) {
  __lang_malloc_tune();
  __lang_mem_trim();
  cycle(0, 1);
  cycle(1, 1);
  cycle_after_work(0);
  cycle_after_work(1);
  cycle_real_work();
  pthread_t threads[2];
  for (int i = 0; i < 2; i++) assert(!pthread_create(&threads[i], NULL, worker, NULL));
  for (int i = 0; i < 2; i++) cycle(i % 2, 0);
  for (int i = 0; i < 2; i++) assert(!pthread_join(threads[i], NULL));
  pthread_t s;
  assert(!pthread_create(&s, NULL, side, NULL));
  while (!atomic_load(&side_filled)) sched_yield();
  cycle_after_work(1);
  atomic_store(&side_trimmed, 1);
  assert(!pthread_join(s, NULL));
  __lang_mem_trim();
#ifdef __APPLE__
  assert(__lang_blk_keep_len == 0 && __lang_blk_keep_bytes == 0);
#endif
  puts("region trim contracts passed");
  return 0;
}
