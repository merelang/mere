#include "coroutine_roots.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
static void *run(void *path) {
 for(int cycle=0; cycle<4; cycle++) {
  void *library=dlopen((const char *)path,RTLD_NOW|RTLD_LOCAL);
  if(!library) { fprintf(stderr,"dlopen: %s\n",dlerror()); exit(1); }
  void (*initialize)(void)=dlsym(library,"mere_lib_init");
  void (*shutdown)(void)=dlsym(library,"mere_lib_shutdown");
  void (*release)(void *)=dlsym(library,"mere_lib_free");
  mere_status (*probe)(long long,long long *,mere_buf *)=dlsym(library,"mere_coroutine_roots_probe");
  if(!initialize || !shutdown || !release || !probe) exit(2);
  initialize();
  long long expected=281474976710657LL, actual=0;
  mere_buf error={0};
  if(probe(expected,&actual,&error)!=MERE_OK || actual!=expected) exit(3);
  release((void *)error.ptr);
  shutdown();
  if(dlclose(library)) exit(4);
 }
 return NULL;
}
int main(int argc,char **argv) {
 if(argc!=2) return 5;
 pthread_t thread;
 if(pthread_create(&thread,NULL,run,argv[1]) || pthread_join(thread,NULL)) return 6;
 puts("host roots can shut down and unload before worker exit");
 return 0;
}
