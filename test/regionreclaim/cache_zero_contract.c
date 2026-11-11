/* Check each retained-block path against the actual generated runtime. */
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
static void clean(__lang_region *r) {
  for (size_t i = 0; i < r->cap; i++) assert(r->base[i] == 0);
}
static void cycle(int mode) {
  __lang_region *r = __lang_region_block_acquire("zeroing contract");
  if (mode == 0) memset(__lang_region_alloc(r, 65536), 0xA5, 65536);
  if (mode == 1) {
    memset(__lang_region_alloc(r, 4096), 0xA5, 4096);
    memset(__lang_region_alloc(r, 4u << 20), 0xBC, 4u << 20);
    assert(r->blocks->prev && r->blocks->pad == (1u << 20));
  }
  if (mode == 2) {
    for (int i = 0; i < 300; i++) memset(__lang_region_alloc(r, 4096), 0xDE, 4096);
    assert(r->blocks->prev && r->blocks->pad == (2u << 20));
  }
  if (mode == 3) {
    memset(__lang_region_alloc(r, 4096), 0xA5, 4096);
    memset(__lang_region_alloc(r, (16u << 20) + 1), 0xBC, (16u << 20) + 1);
  }
  __lang_region_block_release(r);
  assert(__lang_region_cache_n == 1);
  assert(__lang_region_block_acquire("reuse") == r);
  clean(r);
  memset(__lang_region_alloc(r, 4096), 0xCD, 4096);
  __lang_region_block_release(r);
  assert(__lang_region_block_acquire("shorter reuse") == r);
  clean(r);
  __lang_region_block_release(r);
  drain();
}
static void adopted(void) {
  __lang_region *parent = __lang_region_block_acquire("parent");
  __lang_region *child = __lang_region_block_acquire("child");
  unsigned char *value = __lang_region_alloc(child, 128);
  memset(value, 0xBA, 128);
  __lang_region_keep(child, parent);
  __lang_region_block_release(child);
  assert(child->fwd == parent && __lang_region_active_n == 1);
  for (int i = 0; i < 128; i++) assert(value[i] == 0xBA);
  __lang_region_block_release(parent);
  free(child);
  drain();
}
static void *worker(void *unused) {
  (void)unused;
  for (int mode = 0; mode < 4; mode++) cycle(mode);
  adopted();
  return NULL;
}
int main(void) {
  __lang_malloc_tune();
  worker(NULL);
  pthread_t threads[2];
  for (int i = 0; i < 2; i++) assert(!pthread_create(&threads[i], NULL, worker, NULL));
  for (int i = 0; i < 2; i++) assert(!pthread_join(threads[i], NULL));
  puts("region zeroing paths passed");
  return 0;
}
