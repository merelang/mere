# binarytrees reference, Ruby. Two-element arrays; nil is a leaf.
def build(d) = d.zero? ? nil : [build(d - 1), build(d - 1)]
def check(t) = t.nil? ? 1 : 1 + check(t[0]) + check(t[1])

maxdepth = (ARGV[0] || "14").to_i
longlived = build(maxdepth)
d = 4
while d <= maxdepth
  iters = 1 << (maxdepth - d + 4)
  acc = 0
  iters.times { acc += check(build(d)) }
  puts "#{iters} trees of depth #{d} check #{acc}"
  d += 2
end
puts "long-lived tree of depth #{maxdepth} check #{check(longlived)}"
