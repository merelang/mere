# wordfreq reference, Python. dict, the idiomatic answer.
import sys

with open(sys.argv[1]) as f:
    text = f.read()

counts = {}
total = 0
for w in text.replace("\n", " ").split(" "):
    if not w:
        continue
    counts[w] = counts.get(w, 0) + 1
    total += 1

pairs = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
print("words %d" % total)
print("unique %d" % len(pairs))
for w, c in pairs[:10]:
    print("%s %d" % (w, c))
