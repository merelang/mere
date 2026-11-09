#ifdef MERE_REGION_TEST_SOURCE
#include MERE_REGION_TEST_SOURCE
#else
#include "thread_regions.h"
#endif
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static void *worker(void *number) {
 long long n=(long long)(intptr_t)number,actual=0;mere_buf error={0};
 for(int i=0;i<8;i++) {
  if(mere_thread_regions_update(n,&actual,&error)!=MERE_OK || actual!=n*2) abort();
  mere_lib_free((void *)error.ptr);
 }
 return NULL;
}
int main(void) {
 for(int cycle=0;cycle<4;cycle++) {
  for(int n=1;n<=8;n++) {
   pthread_t thread;
   if(pthread_create(&thread,NULL,worker,(void *)(intptr_t)n)||pthread_join(thread,NULL))return 2;
  }
  mere_lib_shutdown();mere_lib_shutdown();
#ifdef MERE_REGION_TEST_SOURCE
  if(__lang_blk_dl || __lang_blk_tl) {
   fputs("library block registry not empty after shutdown\n",stderr);abort();
  }
#endif
 }
 puts("module arenas and retired generations survive thread handoff and are released");
 return 0;
}
