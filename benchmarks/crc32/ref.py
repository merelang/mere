# crc32 reference, Python. Bitwise, no table, not zlib.crc32.
import sys

with open(sys.argv[1], "rb") as f:
    buf = f.read()

crc = 0xFFFFFFFF
for b in buf:
    c = crc ^ b
    for _ in range(8):
        c = ((c >> 1) ^ 0xEDB88320) if (c & 1) else (c >> 1)
    crc = c
crc ^= 0xFFFFFFFF
print("bytes %d" % len(buf))
print("crc32 %d" % crc)
