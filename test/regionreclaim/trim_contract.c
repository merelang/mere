/* Trimming must preserve active data and the retained cache prefix. */
#define _GNU_SOURCE 1
#include <assert.h>
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
static void *worker(void *unused) {
  (void)unused;
  for (int i = 0; i < 4; i++) cycle(i % 2, 0);
  return NULL;
}
int main(void) {
  __lang_malloc_tune();
  __lang_mem_trim();
  cycle(0, 1);
  cycle(1, 1);
  pthread_t threads[2];
  for (int i = 0; i < 2; i++) assert(!pthread_create(&threads[i], NULL, worker, NULL));
  for (int i = 0; i < 2; i++) cycle(i % 2, 0);
  for (int i = 0; i < 2; i++) assert(!pthread_join(threads[i], NULL));
  __lang_mem_trim();
#ifdef __APPLE__
  assert(__lang_blk_keep_len == 0 && __lang_blk_keep_bytes == 0);
#endif
  puts("region trim contracts passed");
  return 0;
}
