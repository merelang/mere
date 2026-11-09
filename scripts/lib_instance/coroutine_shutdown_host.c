#include "coroutine_shutdown.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void *request_shutdown(void *unused) {
 (void)unused; mere_lib_shutdown(); return NULL;
}
int main(void) {
 for(int cycle=0; cycle<4; cycle++) {
  mere_buf input={(const unsigned char *)"saved coroutine input",21},output={0},error={0};
  long long count=-1;
  if(mere_coroutine_shutdown_park(input,&error)!=MERE_OK) abort();
  mere_lib_shutdown();
  pthread_t other;
  if(pthread_create(&other,NULL,request_shutdown,NULL) || pthread_join(other,NULL)) return 2;
  if(mere_coroutine_shutdown_count(&count,&error)!=MERE_OK || count!=1) {
   fputs("shutdown discarded an unfinished coroutine\n",stderr);abort();
  }
  if(mere_coroutine_shutdown_finish(&output,&error)!=MERE_OK || output.len!=21 || memcmp(output.ptr,input.ptr,21)) abort();
  mere_lib_free((void *)output.ptr);mere_lib_free((void *)error.ptr);
  mere_lib_shutdown(); mere_lib_shutdown();
  if(mere_coroutine_shutdown_count(&count,&error)!=MERE_OK || count!=0) abort();
  mere_lib_shutdown();
 }
 puts("unfinished coroutines defer shutdown until their owner finishes them");
 return 0;
}
