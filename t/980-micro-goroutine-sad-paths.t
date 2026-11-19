#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;

use Cwd qw(abs_path);
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use IO::Socket::INET;
use Time::HiRes qw(time);

use lib 'lib';
use Developer::Dashboard::GoRoutine;

# Micro: learn where a dying destructor fires during _ev_invoke_callback,
# and whether the malloc-failure sleep branch in go_ev_wait is reachable.
# Log before and after every step; this file is a probe, not the final test.

diag('micro: start');

# ----------------------------------------------------------------------
# Part A: destructor that dies, returned from a routine callback.
# The return value is a mortal: with G_DISCARD the XSUB leaves it on the
# temps stack, so it should be freed at the XSUB's FREETMPS, AFTER the
# runops restore. A die there must surface through wait_all, and the
# runops must already be restored when it does.
# ----------------------------------------------------------------------
diag('micro: part A: define dying class');
{
    package MicroDying;
    our $DESTROYED = 0;
    sub new { bless {}, shift }
    sub DESTROY { $MicroDying::DESTROYED = 1; die "MICRO_DESTROY_DIED\n"; }
}

diag('micro: part A: schedule routine returning a dying object');
my $routine_a = go sub { return MicroDying->new };
diag('micro: part A: routine scheduled, calling wait_all');
my $wait_died = eval { wait_all(); 1 } ? 0 : 1;
my $wait_err = $@;
diag("micro: part A: after wait_all destroyed=$MicroDying::DESTROYED wait_died=$wait_died");
diag("micro: part A: wait_err=" . (defined $wait_err ? $wait_err : 'undef'));
diag("micro: part A: routine status=" . $routine_a->status);
ok($MicroDying::DESTROYED, 'micro: destructor ran during dispatch cleanup');
ok($wait_died, 'micro: wait_all died with the destructor error');
like($wait_err // '', qr/MICRO_DESTROY_DIED/,
    'micro: destructor error surfaced through wait_all');

# ----------------------------------------------------------------------
# Part A2: child-process probe of PL_runops after the dying destructor.
# exit() at top level goes through PL_runops: if the custom runops leaked,
# exit(42) croaks __GOROUTINE_EXIT__ and the child dies with 255; if it
# was restored, the child exits 42.
# ----------------------------------------------------------------------
diag('micro: part A2: build child program');
my $lib_dir = abs_path("$Bin/../lib");
my @blib_inc = grep { /blib/ } @INC;
if (!@blib_inc) {
    my $blib_lib  = abs_path("$Bin/../blib/lib");
    my $blib_arch = abs_path("$Bin/../blib/arch");
    @blib_inc = grep { -d $_ } ($blib_lib, $blib_arch);
}
my $child_program = <<'CHILD';
use strict;
use warnings;
use lib 'LIBDIR';
use Developer::Dashboard::GoRoutine;
our $DESTROYED = 0;
{
    package MicroDying;
    sub new { bless {}, shift }
    sub DESTROY { $main::DESTROYED = 1; die "MICRO_DESTROY_DIED\n"; }
}
my $r = go sub { return MicroDying->new };
my $died = eval { wait_all(); 1 } ? 0 : 1;
print "destroyed=$main::DESTROYED died=$died\n";
exit(42);
CHILD
$child_program =~ s/LIBDIR/$lib_dir/;
my ($child_fh, $child_file) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print {$child_fh} $child_program;
close $child_fh;
diag("micro: part A2: child file=$child_file lib=$lib_dir blib=@blib_inc");
my @child_args = ($^X, '-I' . $lib_dir, map { '-I' . $_ } @blib_inc, $child_file);
diag('micro: part A2: spawn child');
open my $pipe, '-|', @child_args or die "cannot spawn child: $!";
my $child_out = do { local $/; <$pipe> };
close $pipe;
my $child_rc = $? >> 8;
diag("micro: part A2: child rc=$child_rc out=" . (defined $child_out ? $child_out : 'undef'));
is($child_rc, 42, 'micro: child exit(42) works after a dying destructor (runops restored)');
like($child_out // '', qr/destroyed=1/, 'micro: child destructor ran during dispatch cleanup');

# ----------------------------------------------------------------------
# Part B: malloc failure in go_ev_wait. Needs the test-only hook
# _ev_fail_malloc_once (does not exist yet: this part goes RED first).
# With the hook set, a wait over a never-ready IO trigger must sleep the
# full wait period (not return at once, not spin) and return no due ids,
# and the engine must recover on the next wait.
# ----------------------------------------------------------------------
diag('micro: part B: malloc failure');
SKIP: {
    skip 'malloc-failure branch is Unix-only (Windows select path allocates nothing)', 5
        if $^O eq 'MSWin32';
    diag('micro: part B: call _ev_fail_malloc_once');
    my $has_hook = eval { Developer::Dashboard::GoRoutine::_ev_fail_malloc_once(); 1 };
    diag('micro: part B: hook present=' . ($has_hook ? 'yes' : 'no: ' . ($@ // '')));
    ok($has_hook, 'micro: _ev_fail_malloc_once exists');
    skip 'malloc hook missing, cannot exercise the failure branch', 4
        unless $has_hook;

    diag('micro: part B: build socket pair');
    my $server = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0,
        Proto => 'tcp', ReuseAddr => 1,
    ) or die "cannot listen: $!";
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $server->sockport, Proto => 'tcp',
    ) or die "cannot connect: $!";
    my $accepted = $server->accept or die "cannot accept: $!";
    my $ran = 0;
    my $routine_b = go sub { $ran++ }, { readable => $accepted };
    diag('micro: part B: routine scheduled on never-ready socket, arm the hook');
    Developer::Dashboard::GoRoutine::_ev_fail_malloc_once();
    my $t0 = time();
    my ($u0, $s0) = times();
    diag('micro: part B: call _ev_wait(200)');
    my @due = Developer::Dashboard::GoRoutine::_ev_wait(200);
    my ($u1, $s1) = times();
    my $elapsed = time() - $t0;
    my $cpu = ($u1 - $u0) + ($s1 - $s0);
    diag("micro: part B: after _ev_wait elapsed=$elapsed cpu=$cpu due=@due");
    is(scalar(@due), 0, 'micro: forced malloc failure returns no due ids');
    ok($elapsed >= 0.15, 'micro: forced malloc failure still sleeps the wait period');
    ok($cpu < 0.05, 'micro: forced malloc failure does not busy-loop (low CPU)');
    diag('micro: part B: make the socket readable and wait again');
    print $client "x";
    my @due2 = Developer::Dashboard::GoRoutine::_ev_wait(200);
    diag("micro: part B: after recovery wait due=@due2 ran=$ran");
    is(scalar(@due2), 1, 'micro: engine recovers after a failed malloc');
    is($due2[0], $routine_b->{id}, 'micro: recovery wait returns the waiting routine');
    $routine_b->kill;
    diag('micro: part B: routine killed, cleanup done');
}

diag('micro: done');
done_testing;

__END__

=head1 NAME

t/980-micro-goroutine-sad-paths.t - micro probe for the GoRoutine sad paths

=head1 PURPOSE

Micro-repro probe for the two C-code sad paths in the GoRoutine redesign
that have no regression tests: the malloc-failure sleep branch in
C<go_ev_wait> (GoRoutineEvent.h) and the destructor-dies-during-cleanup
ordering in C<_ev_invoke_callback> (GoRoutine012.xs). It logs what actually
happens at each step so the final test can assert the proven mechanism
instead of a guessed one.

=head1 WHEN TO USE

Run this micro when working on either sad path. It is a probe: remove it
in a cleanup commit once the final regression test (t/254) is green.

=head1 WHY IT EXISTS

A test that asserts a guessed mechanism proves nothing when the guess is
wrong. The destructor path in particular has two candidate timings (the
object freed during the callback's own cleanup, caught by G_EVAL, versus
freed at the XSUB's FREETMPS, after the runops restore) with different
observables. This micro prints which one actually happens before the
final test pins it.

=head1 WHAT IT COVERS

Part A drives a routine whose callback returns an object whose DESTROY
dies, and records whether the destructor ran, whether wait_all died with
its error, and the routine status. Part A2 repeats the same dance in a
child process and exits 42 afterwards, which only works when PL_runops
was restored. Part B arms the test-only malloc-failure hook (when it
exists) and measures a wait over a never-ready socket for sleep time,
CPU use, and recovery.

=head1 HOW TO USE

Run it as a Jenkins solo on goroutine-c-async:

    python3 ~/workspace/jenkins-cli/trigger.py goroutine-c-async t/980-micro-goroutine-sad-paths.t 1

Read the diag lines in the console: they state the observed mechanism.

=head1 WHAT USES IT

Nothing ships on this micro. The final regression test t/254 is built
from what it proves.

=head1 EXAMPLES

The destructor probe is equivalent to:

    my $r = go sub { return Dying->new };
    eval { wait_all() };

The malloc probe is equivalent to:

    Developer::Dashboard::GoRoutine::_ev_fail_malloc_once();
    my @due = Developer::Dashboard::GoRoutine::_ev_wait(200);

=head1 SEE ALSO

L<Developer::Dashboard::GoRoutine>.

=cut
