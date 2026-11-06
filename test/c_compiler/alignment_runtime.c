/* Exercise the generated allocator with both scalar and SIMD requests.
   The fixture supplies its real runtime, including block growth and locks. */
#define main mere_fixture_main
#include "simd_alignment.c"
#undef main
#include <assert.h>

static void check_vector(void* p, unsigned char value) {
  assert(((uintptr_t)p & 15) == 0);
  mere_u8x16* v = (mere_u8x16*)p;
  *v = mere_u8x16_splat(value);
  for (int i = 0; i < 16; i++) assert((*v)[i] == value);
}

static void blocks(void) {
  __lang_region r;
  __lang_region_init(&r, 128);
  size_t before = r.alloc_total;
  (void)__lang_region_alloc(&r, 8);
  assert(r.alloc_total - before == 8);
  for (int i = 0; i < 1000; i++) {
    if (i % 3 == 0) (void)__lang_region_alloc(&r, 8);
    check_vector(__lang_region_alloc_type(&r, mere_u8x16), (unsigned char)i);
    assert(r.top <= r.base + r.cap);
  }
  __lang_region_free(&r);

  /* Consecutive SIMD requests cross a bump-block boundary directly. */
  __lang_region_init(&r, 128);
  for (int i = 0; i < 100; i++)
    check_vector(__lang_region_alloc_type(&r, mere_u8x16), (unsigned char)i);
  __lang_region_free(&r);
}

static void growth(void) {
  __lang_region r;
  __lang_region_init(&r, 4096);
  (void)__lang_region_alloc(&r, 8);
  unsigned char* p = __lang_region_alloc_aligned(&r, 64, 16);
  memset(p, 0x35, 64);
  unsigned char* q = __lang_region_grow_aligned(&r, p, 64, 128, 16);
  assert(q == p); /* the last allocation still grows in place */
  for (int i = 0; i < 64; i++) assert(q[i] == 0x35);
  long long* marker = __lang_region_alloc_type(&r, long long);
  *marker = 1234567;
  p = __lang_region_grow_aligned(&r, q, 128, 512, 16);
  assert(p != q && *marker == 1234567);
  for (int i = 0; i < 64; i++) assert(p[i] == 0x35);
  check_vector(p, 0x17);
  __lang_region_free(&r);

  /* A dedicated block must stay aligned when realloc moves it. */
  __lang_region_init(&r, 128);
  p = __lang_region_alloc_aligned(&r, 4096, 16);
  check_vector(p, 0x49);
  memset(p + 16, 0x49, 4080);
  q = __lang_region_grow_aligned(&r, p, 4096, 8192, 16);
  assert(((uintptr_t)q & 15) == 0);
  for (int i = 0; i < 4096; i++) assert(q[i] == 0x49);
  assert(r.alloc_total == 8192);
  __lang_region_free(&r);
}

static void forwarding(void) {
  __lang_region r;
  __lang_region_init(&r, 256);
  __lang_region site = {0};
  site.fwd = &r;
  site.site = "aligned allocation";
  (void)__lang_region_alloc(&site, 8);
  check_vector(__lang_region_alloc_type(&site, mere_u8x16), 7);
  assert(site.alloc_total == r.alloc_total);
  assert(site.alloc_total == 32); /* scalar, padding, then SIMD */
  __lang_region_free(&r);
}

enum { WORKERS = 4, ALLOCATIONS = 1000 };
static mere_u8x16* slots[WORKERS][ALLOCATIONS];
static void* worker(void* arg) {
  size_t id = (size_t)arg;
  for (int i = 0; i < ALLOCATIONS; i++) {
    (void)__lang_region_alloc(&__lang_default_region, 8);
    slots[id][i] = __lang_region_alloc_type(&__lang_default_region, mere_u8x16);
    check_vector(slots[id][i], (unsigned char)(id + i));
  }
  return NULL;
}

int main(void) {
  assert(sizeof(__lang_region_block) % 16 == 0);
  blocks();
  growth();
  forwarding();
  __lang_region_init(&__lang_default_region, 256);
  pthread_t threads[WORKERS];
  for (size_t i = 0; i < WORKERS; i++)
    assert(pthread_create(&threads[i], NULL, worker, (void*)i) == 0);
  for (int i = 0; i < WORKERS; i++) assert(pthread_join(threads[i], NULL) == 0);
  for (int i = 0; i < WORKERS; i++)
    for (int j = 0; j < ALLOCATIONS; j++)
      for (int k = 0; k < 16; k++)
        assert((*slots[i][j])[k] == (unsigned char)(i + j));
  __lang_region_free(&__lang_default_region);
  puts("alignment runtime: blocks, growth, forwarding, threads passed");
  return 0;
}
