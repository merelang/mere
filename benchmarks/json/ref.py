# json reference, Python. The stdlib json module.
import json
import sys

with open(sys.argv[1]) as f:
    tree = json.load(f)


def walk(v):
    if v is None or v is True or v is False:
        return (1, 1 if v is True else 0, 0)
    if isinstance(v, int):
        return (1, v, 0)
    if isinstance(v, str):
        return (1, 0, len(v))
    if isinstance(v, list):
        n, i, l = 1, 0, 0
        for x in v:
            a, b, c = walk(x)
            n += a; i += b; l += c
        return (n, i, l)
    n, i, l = 1, 0, 0
    for k, x in v.items():
        a, b, c = walk(x)
        n += a; i += b; l += c + len(k)
    return (n, i, l)


nodes, ints, chars = walk(tree)
print("nodes %d" % nodes)
print("ints %d" % ints)
print("strlen %d" % chars)
