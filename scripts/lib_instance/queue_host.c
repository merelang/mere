#include "queue_pool.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready = PTHREAD_COND_INITIALIZER;
static int entered, released;
void host_hold(void) {
 pthread_mutex_lock(&lock); entered = 1; pthread_cond_broadcast(&ready);
 while (!released) pthread_cond_wait(&ready, &lock);
 pthread_mutex_unlock(&lock);
}
static void check(mere_status status, mere_buf *err) {
 if (status != MERE_OK) { fprintf(stderr, "call failed: %.*s\n", (int)err->len, err->ptr); abort(); }
 mere_lib_free((void *)err->ptr); err->ptr = NULL;
}
#define OK(expr) check((expr), &err)
#define VALUE(expr,want) do { OK(expr); if (value != (want)) abort(); } while(0)
static void *worker(void *unused) {
 (void)unused; mere_buf err = {0}; OK(mere_queue_pool_blocking(&err)); return NULL;
}
int main(void) {
 for (int cycle = 0; cycle < 1000; ++cycle) {
  long long value = -1; mere_buf err = {0};
  mere_lib_init();
  VALUE(mere_queue_pool_pooled(&value,&err),0);
  for (int n = 0; n < 100; ++n) {
   OK(mere_queue_pool_reserve(1,&err));
   VALUE(mere_queue_pool_length(1,&value,&err),0);
   for (int i=0; i<16; ++i) OK(mere_queue_pool_append(1,n+i,&err));
   OK(mere_queue_pool_overwrite(1,4,1234,&err));
   VALUE(mere_queue_pool_read(1,4,&value,&err),1234);
   VALUE(mere_queue_pool_read(1,15,&value,&err),n+15);
   OK(mere_queue_pool_release(1,&err));
   VALUE(mere_queue_pool_quarantined(&value,&err),1);
   VALUE(mere_queue_pool_pooled(&value,&err),0);
   OK(mere_queue_pool_drain(&err));
   VALUE(mere_queue_pool_quarantined(&value,&err),0);
   VALUE(mere_queue_pool_pooled(&value,&err),1);
  }
  if (mere_queue_pool_failing(&err) != MERE_FAIL || !err.ptr || !strstr((char *)err.ptr,"expected failure")) abort();
  mere_lib_free((void *)err.ptr); err.ptr=NULL;
  VALUE(mere_queue_pool_pooled(&value,&err),1);
  mere_lib_shutdown(); mere_lib_shutdown();
 }
 mere_lib_init();
 pthread_t thread; pthread_create(&thread,NULL,worker,NULL);
 pthread_mutex_lock(&lock); while (!entered) pthread_cond_wait(&ready,&lock); pthread_mutex_unlock(&lock);
 mere_buf err={0}; long long value=0;
 if(mere_queue_pool_pooled(&value,&err)!=MERE_FAIL || !err.ptr || !strstr((char *)err.ptr,"another thread")) abort();
 mere_lib_free((void *)err.ptr);err.ptr=NULL;
 pthread_mutex_lock(&lock);released=1;pthread_cond_broadcast(&ready);pthread_mutex_unlock(&lock);
 pthread_join(thread,NULL);
 VALUE(mere_queue_pool_pooled(&value,&err),0);
 mere_lib_shutdown();
 puts("1000 lifecycles, 100000 queue reuses, failure recovery and overlap rejection passed");
 return 0;
}
