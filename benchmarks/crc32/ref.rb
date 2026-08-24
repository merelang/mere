# crc32 reference, Ruby. Bitwise, no table, not Zlib.crc32.
buf = File.binread(ARGV[0])
crc = 0xFFFFFFFF
buf.each_byte do |b|
  c = crc ^ b
  8.times { c = (c & 1) == 1 ? ((c >> 1) ^ 0xEDB88320) : (c >> 1) }
  crc = c
end
crc ^= 0xFFFFFFFF
puts "bytes #{buf.bytesize}"
puts "crc32 #{crc}"
