/* Native process controls for the runner, independent of either backend. */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) return 99;
  if (!strcmp(argv[1], "hang")) { sleep(5); return 0; }
  if (!strcmp(argv[1], "descendant")) {
    if (argc != 4) return 99;
    pid_t child = fork();
    if (child < 0) return 99;
    if (!child) {
      FILE *ready = fopen(argv[3], "w");
      if (!ready) return 99;
      fputs("ready", ready); fclose(ready);
      usleep(1000000);
      FILE *out = fopen(argv[2], "w");
      if (out) { fputs("descendant survived", out); fclose(out); }
      return 0;
    }
    sleep(5);
    return 0;
  }
  if (!strcmp(argv[1], "signal")) { raise(SIGTERM); return 99; }
  if (!strcmp(argv[1], "silent")) return 0;
  puts(!strcmp(argv[1], "wrong") ? "wrong" : "ok");
  if (!strcmp(argv[1], "extra")) puts("");
  if (!strcmp(argv[1], "stderr")) fputs("unexpected diagnostic\n", stderr);
  return !strcmp(argv[1], "exit") ? 17 : 0;
}
