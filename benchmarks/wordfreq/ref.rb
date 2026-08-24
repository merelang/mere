# wordfreq reference, Ruby. Hash, the idiomatic answer.
text = File.read(ARGV[0])
counts = Hash.new(0)
total = 0
text.split(/[ \n]/).each do |w|
  next if w.empty?
  counts[w] += 1
  total += 1
end
pairs = counts.to_a.sort_by { |w, c| [-c, w] }
puts "words #{total}"
puts "unique #{pairs.size}"
pairs.first(10).each { |w, c| puts "#{w} #{c}" }
