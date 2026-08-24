# json reference, Ruby. The bundled JSON library.
require "json"

tree = JSON.parse(File.read(ARGV[0]))

def walk(v)
  case v
  when nil then [1, 0, 0]
  when true then [1, 1, 0]
  when false then [1, 0, 0]
  when Integer then [1, v, 0]
  when String then [1, 0, v.bytesize]
  when Array
    n = 1; i = 0; l = 0
    v.each { |x| a, b, c = walk(x); n += a; i += b; l += c }
    [n, i, l]
  else
    n = 1; i = 0; l = 0
    v.each { |k, x| a, b, c = walk(x); n += a; i += b; l += c + k.bytesize }
    [n, i, l]
  end
end

nodes, ints, chars = walk(tree)
puts "nodes #{nodes}"
puts "ints #{ints}"
puts "strlen #{chars}"
