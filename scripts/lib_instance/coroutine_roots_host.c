#include "coroutine_roots.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void *run(void *unused) {
 (void)unused;
 mere_lib_init();
 for (long long i=1; i<=4; i++) {
  long long expected=281474976710656LL+i, actual=0;
  mere_buf error={0};
  mere_status status=mere_coroutine_roots_probe(expected,&actual,&error);
  if(status!=MERE_OK || actual!=expected) {
   fprintf(stderr,"root handle missing: status=%d expected=%lld actual=%lld\n",status,expected,actual);
   exit(1);
  }
  mere_lib_free((void *)error.ptr);
 }
 mere_lib_shutdown();
 return NULL;
}
int main(int argc,char **argv) {
 if(argc>1 && !strcmp(argv[1],"worker")) {
  /* Each worker must release its idle scan/slot caches at thread exit. */
  for(int cycle=0; cycle<8; cycle++) {
   pthread_t thread;
   if(pthread_create(&thread,NULL,run,NULL) || pthread_join(thread,NULL)) return 2;
  }
 } else for(int cycle=0; cycle<4; cycle++) run(NULL);
 puts("host root handles survive coroutine scans");
 return 0;
}
