# churn reference, Ruby. Hash; delete is O(1).
n = ARGV[0].to_i
live = ARGV[1].to_i
pad = "------------------------------------------"
m = {}
n.times do |i|
  m["s#{i}"] = "#{i}#{pad}"
  m.delete("s#{i - live}") if i >= live
end
acc = 0
(n - live).upto(n - 1) { |j| acc += m["s#{j}"].bytesize }
puts "live #{m.size}"
puts "checksum #{acc}"
