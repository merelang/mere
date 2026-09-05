// bytecount reference: same twenty passes, same per-pass value, same output.
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc < 2) { puts("usage: bench <file>"); return 0; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror("read_bytes"); return 1; }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  unsigned char *b = malloc(n);
  if (fread(b, 1, n, f) != (size_t)n) return 1;
  fclose(f);
  long long total = 0;
  for (int p = 0; p < 20; p++) {
    int t = (p * 13) % 256;
    long long acc = 0;
    for (long i = 0; i < n; i++) if (b[i] == t) acc++;
    total += acc;
  }
  printf("bytes %ld\n", n);
  printf("count %lld\n", total);
  return 0;
}
