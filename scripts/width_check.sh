#!/bin/sh
# scripts/width_check.sh — contrib/unicode/width against a named implementation.
#
# The table is derived from the UCD, so comparing it with the UCD would compare
# the generator with itself. This compares it with **Reline** (Ruby's line
# editor, the one a Japanese terminal user's irb actually uses), which arrived
# at its answers independently and is what people's terminals already agree
# with. Two implementations that were not written together.
#
# WHAT A DISAGREEMENT MEANS is not decided in advance. Three outcomes:
#
#   MATCH        both say the same number.
#   KNOWN        they differ for a reason this script NAMES, because the two
#                are answering slightly different questions. Each reason is
#                spelled out, so a new difference in the same range still shows
#                up as DIFF rather than being absorbed into an old excuse.
#   DIFF         neither -- and that is the line to look at, in either
#                direction. The table can be wrong. So can Reline.
#
# Usage:  sh scripts/width_check.sh
# Needs:  ruby (reline ships with it), and a built mere.

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MERE=${MERE:-./_build/default/bin/mere.exe}
[ -x "$MERE" ] || MERE=$(command -v mere || true)
[ -n "$MERE" ] && [ -x "$MERE" ] || { echo "width_check: no mere binary" >&2; exit 1; }
command -v ruby >/dev/null 2>&1 || { echo "width_check: ruby absent" >&2; exit 1; }
ruby -e 'require "reline"' 2>/dev/null || { echo "width_check: reline absent" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$ROOT/.width_check_tmp.mere"' EXIT

# --- the sweep ------------------------------------------------------------
# Every code point would take far longer and find nothing extra: widths come in
# long runs, so what finds a bug is the BOUNDARY of a run, not its middle. This
# takes the dense low planes, the CJK compatibility and fullwidth areas, the
# emoji blocks, and both sides of every boundary anyone has ever got wrong.
cat > "$TMP/points.rb" <<'RUBY'
pts = []
(0x0000..0x3400).each { |c| pts << c }
(0xF900..0x10000).each { |c| pts << c }
[0x1F300..0x1FAFF, 0x20000..0x2000F, 0x2F800..0x2FA1F, 0xE0000..0xE01EF].each do |r|
  r.each { |c| pts << c }
end
[0x1100, 0x115F, 0x2E80, 0x303E, 0x3041, 0x33FF, 0x4E00, 0x9FFF,
 0xA000, 0xA4CF, 0xAC00, 0xD7A3, 0xFE10, 0xFE19, 0xFE30, 0xFE6F,
 0xFF00, 0xFF60, 0xFF61, 0xFFDC, 0xFFE0, 0xFFE6, 0xFFE8, 0xFFEE].each do |c|
  pts << c - 1 << c << c + 1
end
pts.uniq!
pts.sort!
# Surrogates are not characters; no implementation has an answer for them.
pts.reject! { |c| c >= 0xD800 && c <= 0xDFFF }
puts pts.join("\n")
RUBY
ruby "$TMP/points.rb" > "$TMP/points.txt"

N=$(wc -l < "$TMP/points.txt" | tr -d ' ')
RUBY_UNI=$(ruby -e 'print(RbConfig::CONFIG["UNICODE_VERSION"] || "?")')
echo "width_check: $N code points, against Reline (ruby $(ruby -e 'print RUBY_VERSION'), Unicode $RUBY_UNI; table is Unicode 17.0)"

# --- what Reline says -----------------------------------------------------
cat > "$TMP/ask_reline.rb" <<'RUBY'
require "reline"
pts = File.readlines(ARGV[0]).map { |l| Integer(l.strip) }
out = pts.map do |cp|
  w = begin
        Reline::Unicode.get_mbchar_width([cp].pack("U"))
      rescue StandardError
        -99
      end
  "#{cp} #{w}"
end
File.write(ARGV[1], out.join("\n") + "\n")
RUBY
ruby "$TMP/ask_reline.rb" "$TMP/points.txt" "$TMP/reline.txt"

# --- what the table says --------------------------------------------------
# One mere program reading the SAME list, so neither side picks its own input.
cat > "$TMP/ask.mere" <<'MERE'
import "contrib/unicode/width.mere";

let rec go = fn (ls: str list) -> fn (acc: str) ->
  match ls with
  | Nil -> acc
  | Cons (l, rest) ->
    let t = str_trim l in
    if str_eq t "" then go rest acc
    else go rest (acc ++ t ++ " " ++ show (Width.of_cp (int_of_str t)) ++ chr 10);

print_no_nl (go (read_lines "POINTS_FILE") "")
MERE
# The import is resolved against the source file's directory, so the program
# has to live in the repo root next to contrib/.
sed "s|POINTS_FILE|$TMP/points.txt|" "$TMP/ask.mere" > "$ROOT/.width_check_tmp.mere"
"$MERE" "$ROOT/.width_check_tmp.mere" > "$TMP/mere_raw.txt" 2>"$TMP/mere.err" || {
  echo "width_check: the mere side failed" >&2; head -5 "$TMP/mere.err" >&2; exit 1; }
# The interpreter prints the program's final value after the output; drop it.
grep -E '^[0-9]+ -?[0-9]+$' "$TMP/mere_raw.txt" > "$TMP/mere.txt" || true

MINE=$(wc -l < "$TMP/mere.txt" | tr -d ' ')
[ "$MINE" = "$N" ] || {
  echo "width_check: the table answered $MINE of $N points -- not a comparison" >&2; exit 1; }

# --- compare --------------------------------------------------------------
cat > "$TMP/compare.rb" <<'RUBY'
reline = {}
File.foreach(ARGV[0]) { |l| c, w = l.split.map(&:to_i); reline[c] = w }
mine = {}
File.foreach(ARGV[1]) { |l| c, w = l.split.map(&:to_i); mine[c] = w }

# The oracle's own EastAsianWidth, when it could be fetched. Used only to
# EXPLAIN differences, never to create them.
$old_eaw = nil
if ARGV[2] && File.size?(ARGV[2])
  $old_eaw = {}
  File.foreach(ARGV[2]) do |line|
    body = line.split("#").first.to_s.strip
    next if body.empty?
    rng, v = body.split(";").map(&:strip)
    next if v.nil?
    a, b = rng.split("..")
    a = a.to_i(16); b = (b || a.to_s(16)).to_i(16)
    (a..b).each { |c| $old_eaw[c] = v }
  end
end

# A difference is KNOWN only with a reason attached. Anything else is a DIFF,
# in either direction -- the table is not privileged here.
def known(cp, r, m)
  # Reline reports 1 for C0/C1 controls and DEL. The table reports 0 and leaves
  # the rendering to the caller: no single number is right for all of \n, \t
  # and ^X at once, and an editor that draws "^A" counts its own two columns.
  return "control" if (cp < 0x20 || (cp >= 0x7f && cp < 0xa0)) && m == 0
  # Reline gives an unassigned code point 1. The table follows the UCD's
  # @missing lines, which make the unassigned parts of the CJK and Tangut
  # planes 2 -- and a terminal shown one of those draws a two-column box, so
  # the table's answer is the one that matches a screen.
  return "unassigned-wide" if m == 2 && r == 1 &&
    ((0x3400..0x4DBF).cover?(cp) || (0x4E00..0x9FFF).cover?(cp) ||
     (0xF900..0xFAFF).cover?(cp) || (0x20000..0x2FFFD).cover?(cp) ||
     (0x30000..0x3FFFD).cover?(cp))
  # Reline reports 1 for characters that occupy no column at all. This is the
  # one bucket where the TABLE is the one to believe and the oracle is not:
  # U+200B is named ZERO WIDTH SPACE, U+FEFF is a byte-order mark, U+E0020..
  # U+E007F are invisible tag characters, and the conjoining Hangul jamo in
  # U+1160..U+11FF compose onto the leading jamo before them. A terminal
  # advances the cursor for none of them. The membership test is the general
  # category rather than a range list, so a new Cf or Me in a future Unicode
  # lands here instead of appearing as a fresh DIFF.
  if m == 0 && r == 1
    ch = (begin [cp].pack("U") rescue nil end)
    return "zero-width (reline says 1)" if ch && ch.match?(/[\p{Cf}\p{Me}\p{Mn}]/)
    return "conjoining-jamo (reline says 1)" if (0x1160..0x11FF).cover?(cp)
  end
  # THE ORACLE'S VINTAGE IS PART OF THE MEASUREMENT. This ruby implements an
  # older Unicode than the table is generated from, so a code point assigned
  # since then does not exist as far as Reline is concerned and it returns its
  # default. Detected by asking ruby whether the code point is assigned AT ALL,
  # rather than by listing versions -- so this category empties itself when ruby
  # catches up, instead of quietly excusing a real difference forever.
  ch = (begin [cp].pack("U") rescue nil end)
  return "newer-than-this-ruby" if ch && ch.match?(/\p{Cn}/)
  # Same cause, different shape: the code point is old but its
  # EastAsianWidth CHANGED between the oracle's Unicode and the table's, so
  # `\p{Cn}` cannot see it. U+2630 ☰ is N in 15.0 and W in 17.0, and both
  # implementations are right about their own vintage.
  #
  # DERIVED, not listed. A hand-written range list would be correct on the
  # machine it was written on and wrong on a CI runner with a different ruby --
  # and it would go on excusing those ranges long after the reason expired.
  # $OLD_EAW is the oracle's own Unicode, fetched only when there are residual
  # differences to explain; with no network the rows stay DIFF, which is the
  # honest answer for a difference this script cannot account for.
  if $old_eaw && r != m
    old = $old_eaw[cp] || "N"
    old_w = (old == "W" || old == "F") ? 2 : (old == "A" ? 1 : 1)
    return "eaw-changed-since-ruby-unicode" if old_w == r
  end
  nil
end

match = 0
known_counts = Hash.new(0)
diffs = []
reline.each do |cp, r|
  m = mine[cp]
  next if m.nil?
  if r == m then match += 1
  elsif (k = known(cp, r, m)) then known_counts[k] += 1
  else diffs << [cp, r, m]
  end
end

puts "MATCH  #{match}"
known_counts.sort.each { |k, n| puts "KNOWN  #{n}  (#{k})" }
puts "DIFF   #{diffs.size}"
diffs.first(40).each do |cp, r, m|
  ch = (begin [cp].pack("U") rescue "?" end)
  puts format("  U+%04X %-6s reline=%d table=%d", cp, ch.inspect, r, m)
end
puts "  ... #{diffs.size - 40} more" if diffs.size > 40
exit(diffs.empty? ? 0 : 1)
RUBY

# The oracle's Unicode, for explaining version drift. Best effort: no network
# means unexplained rows stay DIFF rather than being waved through.
OLD_EAW="$TMP/eaw_oracle.txt"
if [ -n "$RUBY_UNI" ] && [ "$RUBY_UNI" != "?" ] && [ "$RUBY_UNI" != "17.0.0" ]; then
  curl -sSfL --max-time 20 \
    "https://www.unicode.org/Public/$RUBY_UNI/ucd/EastAsianWidth.txt" \
    -o "$OLD_EAW" 2>/dev/null || : > "$OLD_EAW"
else
  : > "$OLD_EAW"
fi
[ -s "$OLD_EAW" ] || echo "width_check: NOTE -- could not fetch Unicode $RUBY_UNI's EastAsianWidth.txt." \
  "Differences caused by the oracle implementing an older Unicode cannot be explained" \
  "and will be reported as DIFF."

if ruby "$TMP/compare.rb" "$TMP/reline.txt" "$TMP/mere.txt" "$OLD_EAW"; then
  echo "width_check: ok"
  exit 0
fi
echo "width_check: FAILED -- code points where neither answer is accounted for" >&2
exit 1
