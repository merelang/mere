#!/usr/bin/env python3
"""Recover containers after each reachable native allocation failure."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MERE = os.environ.get("MERE", str(ROOT / "_build/default/bin/mere.exe"))
SOURCE = r'''let m = map_new (); let _ = map_set m 1 1; let v = vec_new (); let _ = vec_push v 1; let _ = print_int (map_get m 1 + vec_get v 0); let ms = map_new (); let _ = map_set ms 0 "hello"; let vs = vec_new (); let _ = vec_push vs "world"; let _ = print (map_get ms 0); print (vec_get vs 0)
'''
PREFIX = r'''#define _GNU_SOURCE 1
#include <stdlib.h>
#include <sys/mman.h>
static void* audit_malloc(size_t);
static void* audit_realloc(void*,size_t);
static void audit_free(void*);
static void* audit_mmap(void*,size_t,int,int,int,off_t);
#define malloc audit_malloc
#define realloc audit_realloc
#define free audit_free
#define mmap audit_mmap
'''
NATIVE = r'''
#undef malloc
#undef realloc
#undef free
#undef mmap
#include <assert.h>
static int countdown, tripped, live_malloc;
static void* tracked[4096];
static void track(void* p) { if(!p) return;for(int i=0;i<4096;i++)if(!tracked[i]){tracked[i]=p;live_malloc++;return;}abort(); }
static void untrack(void* p) { if(!p)return;for(int i=0;i<4096;i++)if(tracked[i]==p){tracked[i]=0;live_malloc--;return;} }
static void audit_free(void* p) {untrack(p);free(p);}
static int fail_now(void) { if(countdown>0 && --countdown==0) { tripped=1;return 1; } return 0; }
static void* audit_malloc(size_t n) { if(fail_now())return NULL; void* p=malloc(n);track(p);return p; }
static void* audit_realloc(void* p,size_t n) { if(fail_now())return NULL;untrack(p);void* q=realloc(p,n);track(q?q:p);return q; }
static void* audit_mmap(void* p,size_t n,int prot,int flags,int fd,off_t o) { return fail_now()?MAP_FAILED:mmap(p,n,prot,flags,fd,o); }
int main(int argc,char** argv) {
 __lang_tid_v=1;__lang_stack_bounds();
 __lang_region_init(&__lang_default_region,4096);
 mere_map_int_int* m=mere_map_int_int_new(&__lang_default_region);
 mere_vec_int* v=mere_vec_int_new(&__lang_default_region);
 int n=strstr(argv[1],"map_compact")!=NULL ? 500 : strcmp(argv[1],"map_reindex")==0 ? 5 : strcmp(argv[1],"map_growth_large")==0 ? 512 : 4;
 for(int i=0;i<n;i++) mere_map_int_int_set(m,i,i+100);
 int vn=strstr(argv[1],"vec_compact")!=NULL ? 1000 : strcmp(argv[1],"vec_growth_large")==0 ? 512 : 4;
 for(int i=0;i<vn;i++) mere_vec_int_push(v,i+100);
 if(strcmp(argv[1],"map_compact_owned")==0) mere_map_int_int_compact(m);
 if(strcmp(argv[1],"vec_compact_owned")==0) mere_vec_int_compact(v);
 char buf[8193];memset(buf,'x',8192);buf[8192]=0;
 const char* text=__lang_str_of_cstr(buf);
 mere_map_int_str* ms=mere_map_int_str_new(&__lang_default_region);
 mere_vec_str* vs=mere_vec_str_new(&__lang_default_region);
 for(int i=0;i<3;i++){mere_map_int_str_set(ms,i,text);mere_vec_str_push(vs,text);}
 if(strcmp(argv[1],"map_strings_owned")==0) mere_map_int_str_compact(ms);
 if(strcmp(argv[1],"vec_strings_owned")==0) {mere_vec_str_compact(vs);mere_vec_str_set(vs,0,text);}
 __lang_region* oldms=ms->region;__lang_region* oldvs=vs->region;
 __lang_region* oldm=m->region;__lang_region* oldv=v->region;
 if(strstr(argv[1],"map_growth")!=NULL || strstr(argv[1],"vec_growth")!=NULL || strcmp(argv[1],"map_reindex")==0) {
  __lang_region* r=&__lang_default_region;
  (void)__lang_region_alloc(r,(size_t)(r->base+r->cap-r->top));
 }
 int before=live_malloc;countdown=atoi(argv[2]);__lang_fail_jmpbuf_set=1;
 if(_setjmp(__lang_fail_jmpbuf)==0) {
  if(strstr(argv[1],"map_strings")!=NULL) mere_map_int_str_compact(ms);
  else if(strstr(argv[1],"vec_strings")!=NULL) mere_vec_str_compact(vs);
  else if(strstr(argv[1],"map_compact")!=NULL) mere_map_int_int_compact(m);
  else if(strcmp(argv[1],"map_recycle")==0) mere_map_int_int_recycle(m);
  else if(strstr(argv[1],"map_growth")!=NULL) mere_map_int_int_set(m,n,n+100);
  else if(strcmp(argv[1],"map_reindex")==0) { mere_map_int_int_set(m,5,105); }
  else if(strstr(argv[1],"vec_compact")!=NULL) mere_vec_int_compact(v);
  else if(strcmp(argv[1],"vec_recycle")==0) mere_vec_int_recycle(v);
  else if(strstr(argv[1],"vec_growth")!=NULL) mere_vec_int_push(v,104);
 } else {
  assert(strcmp(__lang_fail_msg,"out of memory")==0);
  if(strstr(argv[1],"map_strings")!=NULL){assert(ms->region==oldms);assert(live_malloc==before);}
  if(strstr(argv[1],"vec_strings")!=NULL){assert(vs->region==oldvs);assert(live_malloc==before);}
  if(strstr(argv[1],"map_compact")!=NULL || strcmp(argv[1],"map_recycle")==0) {assert(m->region==oldm);assert(live_malloc==before);}
  if(strstr(argv[1],"vec_compact")!=NULL || strcmp(argv[1],"vec_recycle")==0) {assert(v->region==oldv);assert(live_malloc==before);}
 }
 countdown=0;__lang_fail_jmpbuf_set=0;
 if(strcmp(argv[1],"map_recycle")!=0 || tripped) for(int i=0;i<n;i++) assert(mere_map_int_int_get(m,i)==i+100);
 if(strcmp(argv[1],"vec_recycle")!=0 || tripped) for(int i=0;i<vn;i++) assert(mere_vec_int_get(v,i)==i+100);
 mere_map_int_int_set(m,10000,42);assert(mere_map_int_int_get(m,10000)==42);
 mere_map_int_int_compact(m);assert(mere_map_int_int_get(m,10000)==42);
 mere_vec_int_push(v,42);mere_vec_int_compact(v);assert(mere_vec_int_get(v,v->len-1)==42);
 for(int i=0;i<3;i++){assert(strcmp(mere_map_int_str_get(ms,i),text)==0);assert(strcmp(mere_vec_str_get(vs,i),text)==0);}
 mere_map_int_str_compact(ms);mere_vec_str_compact(vs);
 for(int i=0;i<3;i++){assert(strcmp(mere_map_int_str_get(ms,i),text)==0);assert(strcmp(mere_vec_str_get(vs,i),text)==0);}
 printf("ok %d\n",tripped);
 return 0;
}
'''

CASES = ("map_growth", "map_growth_large", "map_reindex", "map_compact",
         "map_compact_owned", "map_recycle", "vec_growth", "vec_growth_large",
         "vec_recycle", "vec_compact", "vec_compact_owned", "map_strings",
         "vec_strings", "map_strings_owned", "vec_strings_owned")
checks = failures = 0
with tempfile.TemporaryDirectory(prefix="mere-container-failure-") as directory:
    directory = Path(directory)
    source = directory / "main.mere"
    source.write_text(SOURCE)
    emitted = subprocess.run([MERE, "-c", str(source)], capture_output=True, check=True)
    generated = emitted.stdout.decode().replace("int main(", "int unused_main(", 1)
    cfile = directory / "probe.c"
    cfile.write_text(PREFIX + generated + NATIVE)
    for mode, flags in [("O2", ["-O2"]), ("ASanUBSan", ["-O1", "-g",
            "-fsanitize=address,undefined", "-fno-sanitize-recover=all"])]:
        binary = directory / mode
        subprocess.run(["clang", *flags, "-w", str(cfile), "-lm", "-pthread",
                        "-o", str(binary)], check=True)
        for case in CASES:
            for step in range(1, 33):
                result = subprocess.run([str(binary), case, str(step)],
                    capture_output=True, timeout=30,
                    env=dict(os.environ, ASAN_OPTIONS="detect_leaks=0"))
                assert result.returncode == 0 and result.stdout in (b"ok 0\n", b"ok 1\n"), (
                    mode, case, step, result.returncode, result.stdout, result.stderr)
                checks += 1
                if result.stdout == b"ok 0\n":
                    assert step > 1, (mode, case, "no failure was injected")
                    break
                failures += 1
            else:
                raise AssertionError((mode, case, "allocation bound exceeded"))
print(f"Container recovery: {checks} checks / {failures} injected failures across {len(CASES)} workloads (O2/ASan/UBSan)")
