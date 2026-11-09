#include "stateless.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition=PTHREAD_COND_INITIALIZER;
static int entered,released;
void host_hold(void) {
 long long n=0; mere_buf error={0};
 if(mere_stateless_roundtrip_number(42,&n,&error)!=MERE_OK || n!=42) abort();
 pthread_mutex_lock(&lock);entered=1;pthread_cond_broadcast(&condition);
 while(!released) pthread_cond_wait(&condition,&lock);
 pthread_mutex_unlock(&lock);
}
static void *worker(void *unused) {
 (void)unused;mere_buf error={0};
 if(mere_stateless_blocking(&error)!=MERE_OK) abort();
 return NULL;
}
int main(void) {
 mere_lib_init();pthread_t thread;
 if(pthread_create(&thread,NULL,worker,NULL)) abort();
 pthread_mutex_lock(&lock);while(!entered) pthread_cond_wait(&condition,&lock);pthread_mutex_unlock(&lock);
 long long n=0;mere_buf error={0};
 if(mere_stateless_roundtrip_number(1,&n,&error)!=MERE_FAIL || !error.ptr || !strstr((char *)error.ptr,"another thread")) abort();
 mere_lib_free((void *)error.ptr);error.ptr=NULL;
 pthread_mutex_lock(&lock);released=1;pthread_cond_broadcast(&condition);pthread_mutex_unlock(&lock);
 pthread_join(thread,NULL);
 if(mere_stateless_roundtrip_number(2,&n,&error)!=MERE_OK || n!=2) abort();
 mere_lib_shutdown();puts("stateless overlap rejection and same-thread reentry passed");return 0;
}
