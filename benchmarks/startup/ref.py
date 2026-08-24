# startup reference, Python.
import sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 0
print("startup %d" % (n * n + 1))
