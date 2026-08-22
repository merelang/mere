#!/bin/sh
# scripts/bounded.sh — run a command with a wall-clock limit.
#
#   sh scripts/bounded.sh <seconds> <command> [args...]
#
# Exits 201 if the command outlived the limit, otherwise passes its status
# through (a signalled child reports 128+signal, as a shell would).
#
# WHY NOT timeout(1): it is not on macOS, where this project is developed.
# WHY NOT ulimit -t: that bounds CPU time, and a thread parked on a condition
# variable spends none -- the exact case these gates need to bound. perl's alarm
# measures the clock and perl is present wherever this runs.
#
# One copy, because two gates need it: scripts/parity.sh runs whole programs and
# scripts/thread_leak_check.sh runs programs that deliberately leave a thread
# blocked. A bounded runner defined once per gate is a bounded runner that drifts.
exec perl -e '
  my $secs = shift @ARGV;
  my $pid = fork();
  defined $pid or exit 202;
  if ($pid == 0) { exec { $ARGV[0] } @ARGV or exit 127 }
  $SIG{ALRM} = sub { kill "KILL", $pid; waitpid($pid, 0); exit 201 };
  alarm $secs;
  waitpid($pid, 0);
  alarm 0;
  exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
' "$@"
