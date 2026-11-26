use strict;
use warnings FATAL => 'all';

use Capture::Tiny qw(capture);
use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

# GoRoutine deadlock (Michael, 25 Nov 2026): a `go` worker that loops
# receiving from an unbuffered channel, while the main thread sends 0..9,
# prints the first value and then hangs forever. Ryan reproduced it
# (timeout 5, prints the first value, exit 124). The engine is cooperative
# and single-threaded: send() parks the value and pumps to let the worker
# run; the pump dispatches the worker, which takes the value and prints it,
# then calls receive again and blocks pumping for the next value; but the
# main thread is stuck inside send()'s pump waiting for the worker to
# return, so the next send never runs and no more values ever arrive. The
# receiver starves the sender - a re-entrancy deadlock in the cooperative
# scheduler.
#
# This test runs Michael's script as a subprocess under the `timeout`
# command, so a hang fails the test (exit 124) instead of hanging the
# suite. Without a `timeout` binary the test cannot bound the hang, so it
# skips. The script is written to a temp dir by the test, so the test file
# itself stays self-contained.

my $repo_root = abs_path('.');
my $blib_lib  = File::Spec->catdir( $repo_root, 'blib', 'lib' );
my $blib_arch = File::Spec->catdir( $repo_root, 'blib', 'arch' );

my $timeout_bin = _find_command( qw(timeout gtimeout) );
plan skip_all => 'GoRoutine deadlock test requires a timeout binary (timeout or gtimeout) on PATH'
  if !$timeout_bin;

my $tmp = tempdir( 'dd-goroutine-deadlock-XXXXXX', CLEANUP => 1, TMPDIR => 1 );

# The buffered control proves the script shape works: with a buffer that
# holds all ten values the sends never block, so the worker receives them
# all and the script completes. If this fails, the script itself is broken,
# not the engine. The control worker is bounded (ten receives, then it
# returns) so wait_all can finish it; the deadlock worker below is
# Michael's unbounded loop, which is the shape that deadlocks.
my $buffered_script = _write_script( capacity => 10, worker => 'ten' );
my $buffered = _run_script($buffered_script);
is( $buffered->{exit}, 0, 'buffered channel script completes' );
is( $buffered->{stdout}, "0123456789done\n", 'buffered channel worker receives all ten values in order' );
is( $buffered->{stderr}, '', 'buffered channel script prints nothing to stderr' );

# Michael's script, unchanged in shape: an unbuffered channel, a worker
# looping receive-and-print, ten sends from the main thread, then kill and
# wait. Pre-fix this hangs after the first value and `timeout` kills it
# (exit 124); fixed, it completes and prints all ten values plus done.
my $deadlock_script = _write_script( capacity => 0, worker => 'loop' );
my $deadlock = _run_script($deadlock_script);
is( $deadlock->{exit}, 0, 'unbuffered channel script completes instead of hanging' );
is( $deadlock->{stdout}, "0123456789done\n",
    'unbuffered channel worker receives all ten values in order' );

done_testing();

sub _write_script {
    my (%args) = @_;
    my $capacity = $args{capacity};
    my $worker_body = $args{worker} eq 'ten'
        ? "for (1..10) {\n        my \$v = \$ch->receive;\n        print \$v;\n    }"
        : "while (1) {\n        my \$v = \$ch->receive;\n        print \$v;\n    }";
    # Buffered sends never pump, so the worker is never dispatched before
    # the kill; the control waits for its bounded worker to drain the
    # buffer and finish first. Michael's unbounded worker keeps the exact
    # kill-then-wait shape, which is the shape that deadlocks.
    my $tail = $args{worker} eq 'ten'
        ? "wait_all();\n\$worker->kill;\nwait_all();"
        : "\$worker->kill;\nwait_all();";
    my $script = File::Spec->catfile( $tmp, "deadlock-capacity-$capacity.pl" );
    open my $fh, '>', $script or die "Unable to write $script: $!";
    print {$fh} <<"PERL";
use strict;
use warnings;
\$| = 1;
use Developer::Dashboard::GoRoutine qw(go share wait_all channel);
my \$ch = channel($capacity);
my \$worker = go sub {
    $worker_body
};
for my \$i (0..9) {
    \$ch->send(\$i);
}
$tail
print "done\\n";
PERL
    close $fh or die "Unable to close $script: $!";
    return $script;
}

sub _run_script {
    my ($script) = @_;
    my ( $stdout, $stderr, $raw_exit ) = capture {
        system( $timeout_bin, '5s', $^X, "-I$blib_lib", "-I$blib_arch", $script );
    };
    # Capture::Tiny returns the raw wait status, so shift it to the exit
    # code: `timeout` reports 124 when it has to kill the hanging script.
    return {
        stdout => $stdout,
        stderr => $stderr,
        exit   => $raw_exit >> 8,
    };
}

sub _find_command {
    my @candidates = @_;
    # On Windows, also try the .exe names. Git's usr/bin/timeout.exe is
    # GNU coreutils, but system32 has a Windows timeout.exe earlier in
    # PATH, so a .exe candidate is only accepted when `--version`
    # reports GNU (see _is_gnu_timeout). A file named exactly `timeout`
    # (no extension) can never be found on Windows: Perl's -x is false
    # for it, as Peter verified by copying timeout.exe to a file named
    # `timeout` ( -f true, -x false). On Linux and macOS the .exe names
    # are never added, so behaviour there is unchanged.
    my @names = @candidates;
    if ( $^O eq 'MSWin32' ) {
        push @names, map { "$_.exe" } @candidates;
    }
    for my $candidate (@names) {
        next if !defined $candidate || $candidate eq '';
        for my $dir ( File::Spec->path() ) {
            my $path = File::Spec->catfile( $dir, $candidate );
            next if !-f $path || !-x $path;
            next if $candidate =~ /\.exe\z/i && !_is_gnu_timeout($path);
            return $path;
        }
    }
    return undef;
}

sub _is_gnu_timeout {
    my ($path) = @_;
    my ( $stdout, $stderr, $raw_exit ) = capture {
        system( $path, '--version' );
    };
    # Capture::Tiny returns the raw wait status, so shift it to the exit
    # code. GNU --version prints "timeout (GNU coreutils) ..." and exits
    # 0; the Windows timeout.exe rejects --version at once (invalid
    # argument) and exits non-zero without "GNU" in its output.
    return ( $raw_exit >> 8 ) == 0 && $stdout =~ /GNU/;
}

__END__

=head1 NAME

t/1002-goroutine-deadlock.t - failing tests for the GoRoutine re-entrancy deadlock (Michael's script)

=head1 PURPOSE

Pin that Michael's GoRoutine script (a channel, a worker that loops
receiving and printing, sends 1..10, then kill and wait_all) completes
and prints every value instead of hanging after the first one. The
engine is cooperative and single-threaded: send parks the value and
pumps, the worker takes it and blocks receiving again, and the main
thread is stuck inside send's pump, so send never runs again - a
re-entrancy deadlock in the cooperative scheduler. The test runs the
script as a subprocess under a timeout so a hang fails instead of
blocking the suite.

=head1 WHY IT EXISTS

Michael's script printed 01 and hung forever, and the hang was in the
scheduler, not in his script. Without a regression test the deadlock
could come back with any change to the GoRoutine engine, and a hang in
the suite blocks every other test behind it. The test bounds the script
with a timeout (GNU timeout or gtimeout, found the same way on Windows
via the .exe names) so a future hang fails loudly in seconds instead of
stalling the run.

=head1 WHEN TO USE

When a GoRoutine script hangs, when the GoRoutine engine (send, receive,
pump, dispatch) changes, or when the timeout lookup changes for a
platform. Also when a new cooperative-scheduling bug is suspected and a
minimal repro is needed.

=head1 HOW TO USE

Run it directly with C<prove -lv t/1002-goroutine-deadlock.t> while
iterating, then keep it green under C<prove -lr t> before release. It
runs Michael's script as a subprocess under C<timeout 5s> (or
C<gtimeout>, with C<timeout.exe>/C<gtimeout.exe> tried on Windows and
only a GNU timeout accepted, so the Windows system32 timeout is
skipped), and asserts the exit code and the full output
C<0123456789done>. Without a timeout binary the test skips with a
reason. The script sends 0..9 with plain print, which exercises the
same deadlock as Michael's 1..10 with C<%02d> (the values differ, the
stall is identical).

=head1 WHAT USES IT

It is used by the GoRoutine test family (the goroutine regression files
that run alongside it), by the full C<prove -lr t> suite, and by anyone
changing the GoRoutine scheduler who needs a fast check that the
re-entrancy deadlock is still gone.

=head1 EXAMPLES

Example 1:

  prove -lv t/1002-goroutine-deadlock.t

Run the deadlock regression by itself while changing the GoRoutine
engine or the timeout lookup.

Example 2:

  timeout 5s perl -Ilib -Iblib/lib -Iblib/arch t/1002-goroutine-deadlock.t

Run the same check outside the harness to see the script's own output
and exit code directly.

Example 3:

  prove -lr t

Run the whole suite after the focused check to keep the deadlock
regression aligned with the GoRoutine test family.

=cut
