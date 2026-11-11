/* Compile this against the actual generated runtime with a selected cap. */
#define _GNU_SOURCE 1
#include <assert.h>
#define main generated_main
#include "runtime.c"
#undef main

static void drain(void) {
  while (__lang_region_cache_n) {
    __lang_region *region = __lang_region_cache[--__lang_region_cache_n];
    __lang_region_free(region);
    free(region);
  }
}
static void exercise(int grown) {
  __lang_region *regions[80];
  for (int i = 0; i < 80; i++) {
    regions[i] = __lang_region_block_acquire("configured cache");
    if (grown) *(volatile char *)__lang_region_alloc(regions[i], 4u << 20) = 1;
  }
  for (int i = 79; i >= 0; i--) {
    __lang_region_block_release(regions[i]);
    assert(__lang_region_cache_n <= MERE_REGION_CACHE_CAP);
  }
  int expected = grown && MERE_REGION_CACHE_CAP > 8 ? 8 : MERE_REGION_CACHE_CAP;
  assert(__lang_region_cache_n == expected);
  assert(__lang_region_active_n == 0);
  for (int i = 0; i < expected; i++) {
    __lang_region *region = __lang_region_cache[i];
    assert(region->blocks && !region->blocks->prev);
    assert(region->cap <= (grown ? 4u << 20 : 1u << 20));
  }
  drain();
}
int main(void) {
  exercise(0);
  exercise(1);
  exercise(0);
  puts("configured region cache contracts passed");
  return 0;
}
