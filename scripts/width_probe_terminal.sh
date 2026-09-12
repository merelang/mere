#!/bin/sh
# scripts/width_probe_terminal.sh — ask THIS terminal how wide a character is.
#
# The third oracle, and the only one that can answer for the ambiguous set.
# EastAsianWidth=A (±, §, ※, the box-drawing characters, much of Greek and
# Cyrillic) is width 1 or 2 depending on how the terminal is configured, and no
# amount of reading the UCD will tell you which -- because there the answer is a
# property of the terminal, not of Unicode.
#
# So this asks the terminal directly: print one character, then send ESC[6n
# (Device Status Report) and read back the cursor column. The difference between
# where the cursor was and where it ended up IS the width, measured rather than
# looked up.
#
# NOT A GATE. It needs a real tty and it answers a question about the machine
# it runs on, so its answer is not portable and must not be checked in as an
# expectation. Run it when the table and a terminal seem to disagree, or to find
# out how your terminal treats the ambiguous set before configuring an editor.
#
# Usage:  sh scripts/width_probe_terminal.sh
#         sh scripts/width_probe_terminal.sh 00B1 203B 65E5   # specific points

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

[ -t 0 ] && [ -t 1 ] || {
  echo "width_probe_terminal: needs a real terminal (stdin and stdout must be a tty)." >&2
  echo "  A pipe has no cursor to report, so there is nothing to measure here." >&2
  exit 2
}

command -v ruby >/dev/null 2>&1 || { echo "width_probe_terminal: ruby absent" >&2; exit 1; }

MERE=${MERE:-./_build/default/bin/mere.exe}
[ -x "$MERE" ] || MERE=$(command -v mere || true)

# Default set: one of each answer the table can give, plus the ambiguous ones
# that motivated the probe.
POINTS="$*"
[ -n "$POINTS" ] || POINTS="0041 00E9 00B1 00A7 203B 2500 65E5 3042 FF8A 1F600 0301"

ruby -e '
require "io/console"

# Read the cursor column with a Device Status Report. In raw mode, because the
# reply comes back on stdin and the line discipline would otherwise swallow it
# until Enter -- which never comes.
def column
  $stdin.raw do
    $stdout.write("\e[6n")
    $stdout.flush
    buf = +""
    # ESC [ rows ; cols R
    while (c = $stdin.getc)
      buf << c
      break if c == "R"
      break if buf.length > 32
    end
    m = buf.match(/\[(\d+);(\d+)R/)
    return m ? m[2].to_i : nil
  end
end

puts "terminal: #{ENV["TERM"]}  #{ENV["TERM_PROGRAM"]}"
puts "each row: print the character, ask where the cursor went"
puts
printf("%-10s %-4s %s\n", "codepoint", "char", "columns")

ARGV.each do |hex|
  cp = Integer(hex, 16)
  ch = [cp].pack("U")
  $stdout.write("\r\e[K")       # start of line, cleared
  $stdout.flush
  before = column
  $stdout.write(ch)
  $stdout.flush
  after = column
  $stdout.write("\r\e[K")
  $stdout.flush
  width = (before && after) ? after - before : nil
  printf("U+%-8s %-4s %s\n", hex.upcase, ch, width.nil? ? "(no reply)" : width)
end
' $POINTS

echo
echo "Compare with the table:  MERE=$MERE sh scripts/width_check.sh"
echo "An ambiguous-width character reading 2 here means this terminal is in"
echo "East Asian mode; tell the editor so, rather than changing the table."
