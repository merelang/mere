# churn reference, Python. dict; del is O(1).
import sys

n = int(sys.argv[1])
live = int(sys.argv[2])
pad = "------------------------------------------"
m = {}
for i in range(n):
    m["s%d" % i] = "%d%s" % (i, pad)
    if i >= live:
        del m["s%d" % (i - live)]
acc = 0
for j in range(n - live, n):
    acc += len(m["s%d" % j])
print("live %d" % len(m))
print("checksum %d" % acc)
