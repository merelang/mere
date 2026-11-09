/* Include the generated unit to assert default-region allocation directly. */
#include "retained_strings.c"
#include <assert.h>
static mere_buf input(const char *text) { return (mere_buf){(const unsigned char*)text,(long long)strlen(text)}; }
static void checked(mere_status status,mere_buf err) { assert(status==MERE_OK);mere_lib_free((void*)err.ptr); }
static void equal(mere_buf text,const char *expected) { assert(text.len==(long long)strlen(expected));assert(!memcmp(text.ptr,expected,(size_t)text.len));mere_lib_free((void*)text.ptr); }
void host_reenter(void) {
 mere_buf out={0},err={0};mere_status s=mere_retained_strings_roundtrip_text(input("inner"),&out,&err);checked(s,err);equal(out,"inner");
}
int main(void) {
 mere_lib_init();mere_buf err={0},out={0};long long length=0;mere_status status;
 status=mere_retained_strings_measure(input("warmup"),&length,&err);checked(status,err);
 size_t before=__lang_default_region.alloc_total;
 for(int i=0;i<100000;i++) {
  err=(mere_buf){0};status=mere_retained_strings_measure(input("temporary input"),&length,&err);checked(status,err);assert(length==15);
 }
 assert(__lang_default_region.alloc_total==before);
 for(int i=0;i<1000;i++) {
  char text[64];snprintf(text,sizeof text,"retained %d",i);
  err=(mere_buf){0};status=mere_retained_strings_remember(input(text),&err);checked(status,err);
  memset(text,'x',strlen(text));
  err=(mere_buf){0};status=mere_retained_strings_roundtrip_text(input("replacement"),&out,&err);checked(status,err);equal(out,"replacement");
  snprintf(text,sizeof text,"retained %d",i);
  err=(mere_buf){0};status=mere_retained_strings_recall(&out,&err);checked(status,err);equal(out,text);
  err=(mere_buf){0};status=mere_retained_strings_remember_and_fail(input("retained after fail"),&err);assert(status==MERE_FAIL);mere_lib_free((void*)err.ptr);
  err=(mere_buf){0};status=mere_retained_strings_recall(&out,&err);checked(status,err);equal(out,"retained after fail");
  err=(mere_buf){0};status=mere_retained_strings_reenter(input("outer"),&out,&err);checked(status,err);equal(out,"outer");
 }
 mere_lib_shutdown();puts("temporary string inputs, retained copies, failure and reentry passed");return 0;
}
