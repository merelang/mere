// utf8valid reference: the same state machine, 20 passes, same output.
#include <stdio.h>
#include <stdlib.h>
static long long validate(const unsigned char *b, long n) {
  long long cps = 0; long i = 0;
  while (i < n) {
    unsigned c = b[i];
    if (c < 0x80) { i += 1; cps++; continue; }
    if (c < 0xC2) return -1;
    if (c < 0xE0) { if (i + 1 >= n || (b[i+1] & 0xC0) != 0x80) return -1; i += 2; cps++; continue; }
    if (c < 0xF0) {
      unsigned lo = c == 0xE0 ? 0xA0 : 0x80, hi = c == 0xED ? 0x9F : 0xBF;
      if (i + 2 >= n || b[i+1] < lo || b[i+1] > hi || (b[i+2] & 0xC0) != 0x80) return -1;
      i += 3; cps++; continue;
    }
    if (c < 0xF5) {
      unsigned lo = c == 0xF0 ? 0x90 : 0x80, hi = c == 0xF4 ? 0x8F : 0xBF;
      if (i + 3 >= n || b[i+1] < lo || b[i+1] > hi || (b[i+2] & 0xC0) != 0x80 || (b[i+3] & 0xC0) != 0x80) return -1;
      i += 4; cps++; continue;
    }
    return -1;
  }
  return cps;
}
int main(int argc, char **argv) {
  if (argc < 2) { puts("usage: bench <file>"); return 0; }
  FILE *f = fopen(argv[1], "rb"); if (!f) { perror("read_bytes"); return 1; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  unsigned char *b = malloc(n ? n : 1); if (fread(b, 1, n, f) != (size_t)n) return 1; fclose(f);
  long long total = 0;
  for (int p = 0; p < 20; p++) total += validate(b, n);
  printf("bytes %ld\n", n);
  if (total < 0) puts("invalid"); else printf("valid codepoints %lld\n", total / 20);
  return 0;
}
