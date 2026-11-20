/* Exercise the generated clearing routine on owned private-anonymous pages.
 * Keep both canaries around the payload and the caller's errno intact. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#ifdef __linux__
static int reject_discard, discard_calls;
static uintptr_t payload_lo, payload_hi;
static int checked_discard(void *p, size_t n, int advice) {
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  assert((uintptr_t)p % page == 0 && n % page == 0);
  assert((uintptr_t)p >= payload_lo && (uintptr_t)p + n <= payload_hi);
  assert(advice == MADV_DONTNEED);
  discard_calls++;
  if (reject_discard) { errno = EAGAIN; return -1; }
  return madvise(p, n, advice);
}
#define madvise checked_discard
#endif
#define main generated_main
#include "runtime.c"
#undef main
#ifdef __linux__
#undef madvise
#endif

static void cycle(size_t offset, size_t length, int fail) {
  size_t page = (size_t)sysconf(_SC_PAGESIZE), size = 8 * page;
  unsigned char *base = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  assert(base != MAP_FAILED && offset + length <= size);
  memset(base, 0xA5, size);
#ifdef __linux__
  payload_lo = (uintptr_t)base + offset;
  payload_hi = payload_lo + length;
  reject_discard = fail;
  discard_calls = 0;
#else
  (void)fail;
#endif
  errno = E2BIG;
  __lang_region_clear_cached((char *)base + offset, length);
  assert(errno == E2BIG);
#ifdef __linux__
  uintptr_t lo = (payload_lo + page - 1) / page * page;
  uintptr_t hi = payload_hi / page * page;
  if (lo < hi) {
    if (!fail) {
      /* Check before reading the bytes faults zero pages back in. A memset
         implementation can satisfy every byte check but fails this one. */
      unsigned char resident[8];
      assert(mincore(base, size, resident) == 0);
      for (uintptr_t p = lo; p < hi; p += page)
        assert((resident[(p - (uintptr_t)base) / page] & 1) == 0);
    }
    assert(discard_calls == 1);
  } else assert(discard_calls == 0);
#endif
  for (size_t i = 0; i < size; i++)
    assert(base[i] == (i >= offset && i < offset + length ? 0 : 0xA5));
  assert(munmap(base, size) == 0);
}

int main(void) {
  size_t page = (size_t)sysconf(_SC_PAGESIZE);
  cycle(13, 0, 0);
  cycle(13, page / 2, 0);
  cycle(page, 2 * page, 0);
  cycle(13, 3 * page + 37, 0);
  cycle(page - 7, page + 13, 0);
  cycle(13, 3 * page + 37, 1);
  puts("cached region clearing contracts passed");
  return 0;
}
