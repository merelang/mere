# binarytrees reference, Python. Tuples for nodes; None is a leaf.
import sys

sys.setrecursionlimit(100000)


def build(d):
    if d == 0:
        return None
    return (build(d - 1), build(d - 1))


def check(t):
    if t is None:
        return 1
    return 1 + check(t[0]) + check(t[1])


maxdepth = int(sys.argv[1]) if len(sys.argv) > 1 else 14
longlived = build(maxdepth)

d = 4
while d <= maxdepth:
    iters = 1 << (maxdepth - d + 4)
    acc = 0
    for _ in range(iters):
        acc += check(build(d))
    print("%d trees of depth %d check %d" % (iters, d, acc))
    d += 2

print("long-lived tree of depth %d check %d" % (maxdepth, check(longlived)))
