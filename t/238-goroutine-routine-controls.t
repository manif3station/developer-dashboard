use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time sleep);
use File::Spec;
use FindBin;

use Developer::Dashboard::GoRoutine;

my $go_native_path = File::Spec->catfile( $FindBin::Bin, '..', 'GoRoutine012Native.h' );
open my $go_native_fh, '<', $go_native_path
    or die "Could not read GoRoutine native header '$go_native_path': $!";
local $/;
my $go_native = <$go_native_fh>;
close $go_native_fh
    or die "Could not close GoRoutine native header '$go_native_path': $!";
like( $go_native, qr/perl_clone\(owner,\s*go_clone_flags\(\)\)/,
    'worker interpreter cloning uses the platform-aware flag helper' );
unlike( $go_native, qr/perl_clone\(owner,\s*CLONEf_KEEP_PTR_TABLE\)/,
    'worker cloning does not bypass platform-specific clone flags' );
my $native_header_path = $go_native_path;
open my $native_header_fh, '<', $native_header_path
    or die "Could not read GoRoutine native header '$native_header_path': $!";
my $native_header = do { local $/; <$native_header_fh> };
close $native_header_fh
    or die "Could not close GoRoutine native header '$native_header_path': $!";
like( $native_header, qr/#ifdef _WIN32\s+#\s*ifdef CLONEf_CLONE_HOST/s,
    'Windows clone-host flag is guarded for Perl builds that expose it' );
like( $native_header, qr/flags\s*\|=\s*CLONEf_CLONE_HOST/,
    'Windows workers request host cloning when the Perl flag is available' );

my $normal = go sub {
    sleep 0.15;
};

isa_ok($normal, 'Developer::Dashboard::GoRoutine::Routine',
    'go returns a controllable routine handle');

{
    ok($normal->is_running, 'new routine reports running');
    cmp_ok($normal->age, '>=', 0, 'routine age is non-negative');
    is($normal->status, 'running', 'new routine status is running');

    wait_all();

    ok(!$normal->is_running, 'completed routine is not running');
    is($normal->status, 'done', 'normal completion status is done');
    cmp_ok($normal->age, '>=', 0.10, 'completed routine age includes runtime');
    my $finished_age = $normal->age;
    sleep 0.03;
    cmp_ok(abs($normal->age - $finished_age), '<', 0.02,
        'routine age freezes when the routine completes');

    my $started = time;
    my $killed = $^O eq 'MSWin32'
        ? go sub { 1 while 1 }
        : go sub { sleep 20 };
    ok($killed->kill, 'kill request is accepted for a running routine');
    wait_all();
    cmp_ok(time - $started, '<', 3, 'kill interrupts a blocking sleep promptly');
    is($killed->status, 'killed', 'killed routine reports killed');
    ok($killed->is_killed, 'is_killed recognises killed status');
    ok(!$killed->is_running, 'killed routine is no longer running');
    ok(!$killed->kill, 'kill after completion is a no-op');

    $started = time;
    my $timed = $^O eq 'MSWin32'
        ? go sub { 1 while 1 }
        : go sub { sleep 20 };
    is($timed->timeout(0.15), $timed,
        'timeout returns the same routine handle for chaining');
    wait_all();
    cmp_ok(time - $started, '<', 3, 'timeout interrupts a blocking sleep promptly');
    is($timed->status, 'timed_out', 'expired timeout reports timed_out');
    ok($timed->is_killed, 'is_killed recognises timeout status');

    my $replaced = $^O eq 'MSWin32'
        ? go sub { 1 while 1 }
        : go sub { sleep 20 };
    $replaced->timeout(10)->timeout(0.15);
    wait_all();
    is($replaced->status, 'timed_out', 'new timeout replaces the old timeout');

    my $disabled = go sub {
        sleep 0.15;
    };
    $disabled->timeout(0.02)->timeout(0);
    wait_all();
    is($disabled->status, 'done', 'timeout zero disables the active timeout');

    my $exited = go sub {
        exit 42;
    };
    wait_all();
    is($exited->status, 'exited', 'exit ends only the routine');
    pass('main interpreter continues after routine-local exit');

    my $invalid = go sub {
        sleep 0.05;
    };
    for my $bad (undef, -1, 'abc', 'Inf') {
        my $ok = eval { $invalid->timeout($bad); 1 };
        ok(!$ok, 'timeout rejects invalid value');
        like($@, qr/timeout\(\) requires a non-negative number/,
            'invalid timeout reports the documented error');
    }
    my $too_large = eval { $invalid->timeout('1e999'); 1 };
    ok(!$too_large, 'timeout rejects a non-finite value');
    like($@, qr/timeout\(\) requires a non-negative number/,
        'non-finite timeout reports the documented error');
    my $scientific = go sub { sleep 0.05 };
    is($scientific->timeout('1e3'), $scientific,
        'timeout accepts a valid exponent-form number');
    $scientific->timeout(0);
    wait_all();

    {
        my $unreferenced = go sub { sleep 0.05 };
        undef $unreferenced;
    }
    wait_all();
    pass('worker reference keeps native control alive after handle release');
}

done_testing;

__END__

=head1 NAME

t/238-goroutine-routine-controls.t - tests for GoRoutine routine handles

=head1 PURPOSE

This test verifies the public routine-handle controls introduced by
Developer::Dashboard::GoRoutine 0.05 after they are integrated into the
Developer Dashboard XS extension.

=head1 WHEN TO USE

Run this contract after building the XS extension and whenever the GoRoutine
worker lifecycle, routine-handle API, cancellation, timeout or shutdown code
changes. It is part of the normal package suite and should also be run alone
while debugging those behaviors.

=head1 WHY IT EXISTS

The earlier Dashboard integration returned no routine handle, so callers
could not inspect, cancel, or time-limit one asynchronous routine. The supplied
GoRoutine 0.05 contract adds those controls. This test keeps that contract
visible and guards the timeout, cancellation, completion, and exit behavior
against regressions.

=head1 WHAT IT COVERS

    The test checks normal completion, running state, elapsed age, frozen
completion age, kill requests, cancellation latency, status values, timeout
creation and replacement, timeout disabling, routine-local C<exit>, and clear
validation errors for invalid timeout values. It uses the shared C<wait_all>
barrier so every worker has finished before the assertions complete.

On Windows, cancellation uses a Perl opcode loop because a native blocking
sleep is not safely force-interruptible there. POSIX runs also verify that a
worker can be woken from a blocking sleep.

=head1 HOW TO USE

Run this test through the project development container after building the XS
extension:

    d2 docker compose exec dev prove -lv t/238-goroutine-routine-controls.t

The test fails if C<go> does not return a routine handle or if any GoRoutine
0.05 control is absent. No control assertions are conditionally skipped.

=head1 WHAT USES IT

The distribution's Perl test suite runs this file to verify the public
C<Developer::Dashboard::GoRoutine> routine-handle contract. Developers use it
to validate changes to the XS routine controls and their Perl-facing wrapper.

=head1 EXAMPLES

The tested normal-completion usage is equivalent to:

    my $routine = go sub { perform_work(); };
    print $routine->status;
    wait_all();

Timeout and cancellation usage is equivalent to:

    my $routine = go sub { perform_work(); };
    $routine->timeout(10);
    $routine->kill if $should_cancel;
    wait_all();

=head1 SEE ALSO

L<Developer::Dashboard::GoRoutine>, L<Time::HiRes>, L<Test::More>.

=cut
