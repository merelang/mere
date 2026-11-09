#include "coroutine_roots.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
static void *worker(void *path) {
 for(int i=0; i<64; i++) {
  void *module=dlopen((const char *)path,RTLD_NOW|RTLD_LOCAL);
  if(!module) { fprintf(stderr,"dlopen: %s\n",dlerror()); abort(); }
  mere_status (*probe)(long long,long long *,mere_buf *)=
    (mere_status (*)(long long,long long *,mere_buf *))dlsym(module,"mere_coroutine_roots_probe");
  void (*shutdown)(void)=(void (*)(void))dlsym(module,"mere_lib_shutdown");
  void (*release)(void *)=(void (*)(void *))dlsym(module,"mere_lib_free");
  if(!probe || !shutdown || !release) abort();
  long long value=281474976710657LL,actual=0;mere_buf error={0};
  if(probe(value,&actual,&error)!=MERE_OK || actual!=value) abort();
  release((void *)error.ptr);shutdown();shutdown();
  if(dlclose(module)) abort();
 }
 return NULL;
}
int main(int argc,char **argv) {
 if(argc!=2) return 2;
 pthread_t thread;
 if(pthread_create(&thread,NULL,worker,argv[1]) || pthread_join(thread,NULL)) return 2;
 puts("module unload unregisters thread cleanup callbacks");
 return 0;
}
