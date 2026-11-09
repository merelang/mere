#!/usr/bin/env perl
# Run one or two independent RISC-V fixtures with their original wall limits.
# Each job supplies width, fixture name, directory, runner and virtual RAM.
use strict;
use warnings;
use POSIX qw(setpgid sigprocmask SIG_BLOCK SIG_SETMASK SIGINT SIGTERM SIGHUP);
use Fcntl qw(F_SETFD FD_CLOEXEC);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my $limit = shift @ARGV;
die "usage: coro_rv_runner.pl LIMIT (WIDTH CASE DIRECTORY RUNNER RAM){1,2}\n"
  unless defined($limit) && $limit =~ /^\d+$/ && (@ARGV == 5 || @ARGV == 10);
my @jobs;
my %widths;
while (@ARGV) {
  my ($width, $name, $dir, $runner, $ram) = splice(@ARGV, 0, 5);
  die "invalid coroutine runner job\n" unless ($width eq '32' || $width eq '64')
    && !$widths{$width}++ && $name !~ /[\t\r\n]/ && -d $dir && -x $runner && $ram =~ /^\d+$/;
  push @jobs, { width => $width, name => $name, dir => $dir, runner => $runner, ram => $ram };
}
my %live;
sub stop_children {
  # A child has its own process group, including anything it starts.
  kill 'KILL', -$_ for keys %live;
  kill 'KILL', keys %live if %live;
  waitpid($_, 0) for keys %live;
  %live = ();
}
for my $signal (qw(INT TERM HUP)) {
  my $status = $signal eq 'INT' ? 130 : $signal eq 'TERM' ? 143 : 129;
  $SIG{$signal} = sub { stop_children(); exit $status };
}
my $ok = eval {
  for my $job (@jobs) {
    my $dir = $job->{dir};
    unlink "$dir/status";
    pipe(my $errors, my $report) or die "cannot create runner launch pipe: $!\n";
    fcntl($report, F_SETFD, FD_CLOEXEC) or die "cannot protect runner launch pipe: $!\n";
    my $blocked = POSIX::SigSet->new(SIGINT, SIGTERM, SIGHUP);
    my $previous = POSIX::SigSet->new();
    sigprocmask(SIG_BLOCK, $blocked, $previous) or die "cannot block runner signals: $!\n";
    my $start = clock_gettime(CLOCK_MONOTONIC);
    my $pid = fork();
    die "cannot fork coroutine runner: $!\n" unless defined $pid;
    if ($pid == 0) {
      $SIG{INT} = $SIG{TERM} = $SIG{HUP} = $SIG{ALRM} = 'DEFAULT';
      close $errors;
      eval {
        setpgid(0, 0) == 0 or die "cannot isolate runner: $!\n";
        sigprocmask(SIG_SETMASK, $previous) or die "cannot restore runner signals: $!\n";
        chdir $dir or die "cannot enter runner directory: $!\n";
        open STDOUT, '>', 'out' or die "cannot capture runner output: $!\n";
        open STDERR, '>&', STDOUT or die "cannot capture runner errors: $!\n";
        alarm $limit;
        exec { $job->{runner} } $job->{runner}, $job->{ram};
        die "cannot execute runner: $!\n";
      };
      my $error = $@ || "runner setup failed\n";
      print {$report} $error;
      close $report;
      exit 127;
    }
    close $report;
    $live{$pid} = { %$job, start => $start, errors => $errors };
    # Register and isolate the child before delivering a pending cancellation.
    setpgid($pid, $pid);
    sigprocmask(SIG_SETMASK, $previous) or die "cannot restore runner signals: $!\n";
  }
  while (%live) {
    my $pid = wait();
    die "cannot wait for coroutine runner: $!\n" if $pid < 0;
    my $raw = $?;
    my $job = delete $live{$pid};
    next unless $job;
    kill 'KILL', -$pid;
    my $status = ($raw & 127) ? 128 + ($raw & 127) : $raw >> 8;
    my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $job->{start};
    my $errors = do { local $/; readline($job->{errors}) };
    close $job->{errors};
    open my $result, '>', "$job->{dir}/status" or die "cannot save runner status: $!\n";
    print {$result} "$status\n" or die "cannot save runner status: $!\n";
    close $result or die "cannot save runner status: $!\n";
    die "coroutine runner did not launch: $errors" if length($errors // '');
    if (length($ENV{CORO_TIMINGS} // '')) {
      open my $log, '>>', $ENV{CORO_TIMINGS} or die "cannot open coroutine timings: $!\n";
      printf {$log} "execute-rv%s\t%s\t%.6f\t%d\n", $job->{width}, $job->{name}, $elapsed, $status
        or die "cannot save coroutine timings: $!\n";
      close $log or die "cannot save coroutine timings: $!\n";
    }
  }
  1;
};
if (!$ok) {
  my $error = $@;
  stop_children();
  print STDERR $error;
  exit 2;
}
