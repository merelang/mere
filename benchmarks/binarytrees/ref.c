/* binarytrees reference, C. malloc per node, and the tree is freed after it is
   checked -- which is what a C programmer writes, and is why this row's
   footprint stays flat while Mere's does not. A C version that bump-allocated
   into an arena and never freed would look like the Mere row instead; that is
   the comparison Mere is making, not a different algorithm. */
#include <stdio.h>
#include <stdlib.h>

typedef struct node { struct node *l, *r; } node;

static node *build(int d) {
  if (d == 0) return NULL;
  node *n = malloc(sizeof(node));
  n->l = build(d - 1);
  n->r = build(d - 1);
  return n;
}

static long long check(node *t) {
  if (!t) return 1;
  return 1 + check(t->l) + check(t->r);
}

static void destroy(node *t) {
  if (!t) return;
  destroy(t->l);
  destroy(t->r);
  free(t);
}

int main(int argc, char **argv) {
  int maxdepth = argc > 1 ? atoi(argv[1]) : 14;
  node *longlived = build(maxdepth);
  for (int d = 4; d <= maxdepth; d += 2) {
    long long iters = 1LL << (maxdepth - d + 4);
    long long acc = 0;
    for (long long i = 0; i < iters; i++) {
      node *t = build(d);
      acc += check(t);
      destroy(t);
    }
    printf("%lld trees of depth %d check %lld\n", iters, d, acc);
  }
  printf("long-lived tree of depth %d check %lld\n", maxdepth, check(longlived));
  destroy(longlived);
  return 0;
}
