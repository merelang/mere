/* The pool must publish zeroed mappings before reuse can omit a second clear. */
#define _GNU_SOURCE 1
#include <assert.h>
#define main generated_main
#include "runtime.c"
#undef main

#if defined(__APPLE__)
static void zero_bytes(const unsigned char *p, size_t n) {
  for (size_t i = 0; i < n; i++) assert(p[i] == 0);
}

static void cycle(size_t total, int exclusive) {
  unsigned char *p = __lang_blk_raw_alloc(total);
  assert(p);
  memset(p, 0xA5, total);
  uintptr_t address = (uintptr_t)p;
  __lang_blk_raw_free(p, total);
  pthread_mutex_lock(&__lang_blk_keep_lock);
  for (int i = 0; i < __lang_blk_keep_len; i++) {
    zero_bytes(__lang_blk_keep[i].p, __lang_blk_keep[i].n);
  }
  pthread_mutex_unlock(&__lang_blk_keep_lock);
  unsigned char *q = __lang_blk_raw_alloc(total);
  assert(q);
  if (exclusive) assert((uintptr_t)q == address);
  zero_bytes(q, total);
  /* Short writes must not leave dirt in the rest of a later mapping. */
  memset(q, 0xBC, total / 3);
  __lang_blk_raw_free(q, total);
}

static void *worker(void *unused) {
  (void)unused;
  for (int i = 0; i < 20; i++) {
    cycle(__LANG_BLK_MAP_MIN, 0);
    cycle(1u << 20, 0);
  }
  return NULL;
}
#endif

int main(void) {
#if defined(__APPLE__)
  cycle(__LANG_BLK_MAP_MIN, 1);
  cycle(1u << 20, 1);
  pthread_t threads[2];
  for (int i = 0; i < 2; i++) assert(!pthread_create(&threads[i], NULL, worker, NULL));
  for (int i = 0; i < 2; i++) assert(!pthread_join(threads[i], NULL));
  __lang_mem_trim();
  assert(__lang_blk_keep_len == 0 && __lang_blk_keep_bytes == 0);
#endif
  puts("mapped pool zeroing contracts passed");
  return 0;
}
