/* crc32 reference, C. Same bitwise algorithm as every other implementation
   here: no lookup table and no library CRC. A table-driven or zlib version
   would make this a comparison of algorithms and of who has the better
   vendored C, which is not what the suite is measuring. */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: ref <file>\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror("open"); return 2; }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *buf = malloc((size_t)n);
  if (fread(buf, 1, (size_t)n, f) != (size_t)n) { perror("read"); return 2; }
  fclose(f);

  unsigned int crc = 0xFFFFFFFFu;
  for (long i = 0; i < n; i++) {
    unsigned int c = crc ^ buf[i];
    for (int k = 0; k < 8; k++)
      c = (c & 1u) ? ((c >> 1) ^ 0xEDB88320u) : (c >> 1);
    crc = c;
  }
  crc ^= 0xFFFFFFFFu;
  printf("bytes %ld\n", n);
  printf("crc32 %u\n", crc);
  free(buf);
  return 0;
}
