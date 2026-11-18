use strict;
use warnings;

# MICRO for t/240 (build #91: Windows child exits -1073741819, empty output).
# Purpose: pin down WHERE the access violation happens. Each case spawns a
# child via GoRoutine::spawn, waits, and DIAGNOSES the exit code and the
# output file bytes. The child sets $| = 1 and prints markers, so the file
# shows exactly how far it got before dying. Every case is ok(1): this is a
# measurement, not a pass/fail test, so the fail-safe never stops the run
# and all six cases are measured in one build. SCRATCH FILE - never merge.
#
# Case 0: no GoRoutine at all - plain spawn, print, exit. Baseline: does
#         the spawn mechanism itself work?
# Case 1: require GoRoutine, no go call - print, exit. Is the AV at load /
#         atexit registration with zero workers?
# Case 2: go + explicit wait_all() + print + exit. Is the AV in worker
#         spawn/run/destroy without the shutdown drain?
# Case 3: exact t/240 automatic-shutdown (go + print + fall off the end).
#         The failing case, with markers.
# Case 4: go with an immediately-finishing worker + print + fall off the
#         end. Worker is done before shutdown; drain has nothing to wait for.
# Case 5: exact t/240 explicit-exit (go + print + exit 0).

use File::Temp qw(tempdir);
use Test::More;

use Developer::Dashboard::GoRoutine ();

my $dir = tempdir( CLEANUP => 1 );

sub run_case {
    my ( $name, $source ) = @_;
    my $output = "$dir/$name.txt";
    my $script = "$source";
    my $child = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-e', $script ],
        { stdout => $output, stderr => $output },
    );
    my $exit = Developer::Dashboard::GoRoutine::wait_process($child);
    my $bytes = '';
    if ( open my $fh, '<', $output ) {
        local $/;
        $bytes = <$fh>;
        close $fh;
    }
    else {
        $bytes = "<UNREADABLE: $!>";
    }
    $bytes = '' if !defined $bytes;
    my $esc = $bytes;
    $esc =~ s/\r/\\r/g;
    $esc =~ s/\n/\\n/g;
    diag("CASE $name exit=[$exit] len=[" . length($bytes) . "] bytes=[$esc]");
    ok( 1, "case $name measured" );
    return;
}

run_case( 'case0-baseline', q{$| = 1; print "MARK-MAIN\n";} );

run_case( 'case1-load-only',
    q{$| = 1; require Developer::Dashboard::GoRoutine; Developer::Dashboard::GoRoutine->import(); print "MARK-AFTER-LOAD\n";} );

run_case( 'case2-go-waitall',
    q{use Developer::Dashboard::GoRoutine; $| = 1; go sub { select undef, undef, undef, 0.12; print "worker-finished\n"; }; print "MARK-AFTER-GO\n"; wait_all(); print "MARK-AFTER-WAIT\n";} );

run_case( 'case3-auto-shutdown',
    q{use Developer::Dashboard::GoRoutine; $| = 1; go sub { select undef, undef, undef, 0.12; print "worker-finished\n"; }; print "main-finished\n";} );

run_case( 'case4-fast-worker',
    q{use Developer::Dashboard::GoRoutine; $| = 1; go sub { print "worker-fast\n"; }; print "main-fast\n";} );

run_case( 'case5-explicit-exit',
    q{use Developer::Dashboard::GoRoutine; $| = 1; go sub { select undef, undef, undef, 0.12; print "exit-worker-finished\n"; }; print "main-exit\n"; exit 0;} );

done_testing;
