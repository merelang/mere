/* A backing-array reference must not retain removed Map entries in the
 * production coroutine pin walk. Explicitly borrowed values still survive. */
#define _GNU_SOURCE 1
#include <assert.h>
#include <stdint.h>
#include <string.h>
#define main generated_main
#ifndef RUNTIME_FILE
#define RUNTIME_FILE "runtime.c"
#endif
#include RUNTIME_FILE
#undef main

static int reaches_address(uintptr_t lo, uintptr_t hi, uintptr_t *words, size_t count) {
  __lang_coro_x state; __lang_coro c;
  memset(&state,0,sizeof state);memset(&c,0,sizeof c);
  c.state=2;c.x=&state;state.sp=(char*)words;state.s_hi=(char*)(words+count);
  __lang_pin_gather(&c);
  int found=0;
  for(size_t i=0;i<state.pn;i++)
    if(state.pw[i]>=lo && state.pw[i]<hi) found=1;
  free(state.pw);return found;
}
static int reaches(__lang_region *region, uintptr_t *words, size_t count) {
  for(__lang_region_block *b=region->blocks;b;b=b->prev)
    if(reaches_address((uintptr_t)(b+1),(uintptr_t)(b+1)+b->pad,words,count)) return 1;
  return 0;
}
static void require(int condition, const char *message) {
  if (!condition) { fprintf(stderr,"%s\n",message); abort(); }
}
static mere_vec_int *target(__lang_region **region, long long value) {
  *region=__lang_region_block_acquire("map slot target");
  mere_vec_int *v=mere_vec_int_new(*region);mere_vec_int_push(v,value);return v;
}
int main(void) {
  __lang_stack_bounds();__lang_tid_v=1;
  __lang_region_init(&__lang_default_region,1<<22);
  __lang_region *dead_region,*live_region;
  mere_vec_int *dead=target(&dead_region,42),*live=target(&live_region,99);
  mere_map_str_Vec_int *map=mere_map_str_Vec_int_new(&__lang_default_region);
  __lang_region_alloc(&__lang_default_region,4096);
  const char *dead_key=__lang_str_of_cstr("dead"),*live_key=__lang_str_of_cstr("live");
  mere_map_str_Vec_int_set(map,dead_key,dead);
  mere_map_str_Vec_int_set(map,live_key,live);
  uintptr_t stack[2]={(uintptr_t)map->values,0};
  assert(reaches(dead_region,stack,1));assert(reaches(live_region,stack,1));
  const char *stored_dead_key=map->keys[0],*stored_live_key=map->keys[1];
  uintptr_t key_stack=(uintptr_t)map->keys;
  assert(reaches_address((uintptr_t)stored_dead_key,(uintptr_t)stored_dead_key+1,&key_stack,1));
  mere_vec_int *borrowed=mere_map_str_Vec_int_get(map,dead_key);
  mere_map_str_Vec_int_delete(map,dead_key);
  assert(mere_map_str_Vec_int_len(map)==1);
  assert(!mere_map_str_Vec_int_has(map,dead_key));
  assert(mere_map_str_Vec_int_get(map,live_key)==live);
  require(!reaches(dead_region,stack,1),"deleted value remains reachable");
  require(!reaches_address((uintptr_t)stored_dead_key,(uintptr_t)stored_dead_key+1,&key_stack,1),"deleted key remains reachable");
  assert(reaches(live_region,stack,1));
  stack[1]=(uintptr_t)borrowed;
  assert(reaches(dead_region,stack,2));
  assert(mere_vec_int_get(borrowed,0)==42);
  mere_map_str_Vec_int_clear(map);
  assert(mere_map_str_Vec_int_len(map)==0);
  require(!reaches(live_region,stack,1),"cleared value remains reachable");
  require(!reaches_address((uintptr_t)stored_live_key,(uintptr_t)stored_live_key+1,&key_stack,1),"cleared key remains reachable");
  assert(reaches(dead_region,stack,2));
  assert(mere_vec_int_get(borrowed,0)==42);
  mere_map_str_Vec_int_clear(mere_map_str_Vec_int_new(&__lang_default_region));
  mere_map_str_Vec_int_set(map,live_key,live);
  assert(mere_map_str_Vec_int_get(map,live_key)==live);
  puts("removed Map slots drop pin reachability; live and borrowed values survive");
  return 0;
}
