/* Exercise the generated C runtime, including its actual spawn cleanup. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <stdlib.h>
static void tracked_free(void *p);
#define free tracked_free
#define main generated_main
#include "runtime.c"
#undef main
#undef free

static _Thread_local void *tracked[64];
static _Thread_local int freed;
static void tracked_free(void *p) {
  for (int i = 0; i < 64; i++)
    if (p && tracked[i] == p) { tracked[i] = NULL; freed++; }
  free(p);
}
static void drain(void) {
  while (__lang_region_cache_n) {
    __lang_region *r = __lang_region_cache[--__lang_region_cache_n];
    __lang_region_free(r); free(r);
  }
}
static void fill(int depth, int grown, size_t bytes, int grown_last) {
  __lang_region *regions[128];
  assert(depth <= 128 && __lang_region_cache_n == 0);
  for (int i = 0; i < depth; i++) {
    regions[i] = __lang_region_block_acquire("cache contract");
    if ((grown_last ? i >= depth - grown : i < grown) && grown)
      *(volatile char *)__lang_region_alloc(regions[i], bytes) = 1;
  }
  for (int i = depth - 1; i >= 0; i--) __lang_region_block_release(regions[i]);
  assert(__lang_region_active_n == 0);
}
static void check(int count, size_t bytes, int grown) {
  assert(__lang_region_cache_n == count);
  size_t total = 0; int large = 0;
  for (int i = 0; i < count; i++) {
    __lang_region *r = __lang_region_cache[i];
    assert(r->blocks && !r->blocks->prev);
    total += __lang_region_bytes(r);
    large += r->cap > (1u << 20);
    assert(r->cap <= (16u << 20));
    if (i >= 8) assert(r->cap <= (1u << 20));
  }
  if (total != bytes || large != grown) fprintf(stderr, "cache mismatch: count=%d bytes=%zu expected=%zu grown=%d expected=%d\n", count, total, bytes, large, grown);
  assert(total == bytes && large == grown);
}
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static int ready, go;
static int worker_body(void *env, int ignored) {
  (void)ignored;
  fill(64, 0, 0, 0); check(64, (size_t)64 << 20, 0);
  for (int i = 0; i < 64; i++) tracked[i] = __lang_region_cache[i];
  pthread_mutex_lock(&lock);
  ready++; pthread_cond_broadcast(&cond);
  while (!go) pthread_cond_wait(&cond, &lock);
  pthread_mutex_unlock(&lock);
  if (*(int *)env) __lang_fail_impl("expected cache cleanup failure path");
  return 0;
}
static void *worker(void *env) {
  __lang_thr state = {0}; state.refs = 2;
  __mere_unit_closure *closure = malloc(sizeof *closure);
  closure->env = env; closure->fn = worker_body; closure->thr = &state;
  __mere_spawn_trampoline(closure);
  assert(state.state == (*(int *)env ? 2 : 1));
  assert(freed == 64 && __lang_region_cache_n == 0);
  assert(!__lang_region_active && __lang_region_active_n == 0);
  assert(!__lang_blk_tl);
  return NULL;
}
int main(void) {
  const int depths[] = {8, 9, 40, 63, 64, 65, 80, 128};
  for (unsigned i = 0; i < sizeof depths / sizeof *depths; i++) {
    int n = depths[i] < 64 ? depths[i] : 64;
    fill(depths[i], 0, 0, 0); check(n, (size_t)n << 20, 0); drain();
  }
  fill(12, 12, (4u << 20), 0); check(8, (size_t)32 << 20, 8); drain();
  fill(80, 12, (4u << 20), 0); check(64, (size_t)64 << 20, 0); drain();
  fill(80, 8, (16u << 20), 1); check(64, (size_t)184 << 20, 8); drain();
  fill(9, 1, (16u << 20) + 1, 1); check(9, (size_t)9 << 20, 0); drain();
  fill(9, 0, 0, 0); check(9, (size_t)9 << 20, 0);
  __lang_threads_started = 1;
  pthread_t threads[2]; int fail[2] = {0, 1};
  for (int i = 0; i < 2; i++) assert(!pthread_create(&threads[i], NULL, worker, &fail[i]));
  pthread_mutex_lock(&lock);
  while (ready != 2) pthread_cond_wait(&cond, &lock);
  check(9, (size_t)9 << 20, 0); go = 1;
  pthread_cond_broadcast(&cond); pthread_mutex_unlock(&lock);
  for (int i = 0; i < 2; i++) assert(!pthread_join(threads[i], NULL));
  check(9, (size_t)9 << 20, 0); drain();
  puts("region cache contracts passed");
  return 0;
}
