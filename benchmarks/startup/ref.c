/* startup reference, C. */
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  long long n = argc > 1 ? atoll(argv[1]) : 0;
  printf("startup %lld\n", n * n + 1);
  return 0;
}
