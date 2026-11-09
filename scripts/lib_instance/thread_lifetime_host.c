#include "thread_lifetime.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void *worker(void *unused) {
 (void)unused;
 for (int i=0; i<8; i++) {
  mere_buf input={(const unsigned char *)"host input",10}, output={0}, error={0};
  if(mere_thread_lifetime_roundtrip_text(input,&output,&error)!=MERE_OK ||
     output.len!=10 || memcmp(output.ptr,input.ptr,10)) abort();
  mere_lib_free((void *)output.ptr); mere_lib_free((void *)error.ptr);
 }
 return NULL;
}
int main(void) {
 for(int cycle=0; cycle<8; cycle++) {
  pthread_t thread;
  if(pthread_create(&thread,NULL,worker,NULL) || pthread_join(thread,NULL)) return 2;
 }
 mere_lib_shutdown(); mere_lib_shutdown();
 puts("host pthread temporary regions released");
 return 0;
}
