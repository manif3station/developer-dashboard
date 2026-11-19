# t/999-micro-hang-repro.t — MICRO, DO NOT SHIP. Reproduces the t/17
# Windows post-plan hang in miniature, nothing more.
#
# Shape (mirrors t/17 test 15 exactly): the test spawns a "frontend" perl
# fixture through GoRoutine::spawn with NO stdio options, so the frontend
# inherits prove's pipes. The frontend spawns a "backend" perl fixture the
# same way (no stdio options, exactly like _serve_ssl_frontend), installs a
# TERM handler that stops the backend (like _ssl_term_handler), then blocks.
# The test kills the frontend with GoRoutine::terminate_process — SIGTERM on
# POSIX, TerminateProcess on Windows — and measures whether the backend
# survives. The backend sleeps 60s (bounded) then exits, so the micro can
# never hang forever: on Windows prove waits up to ~60s for the orphaned
# backend to exit before it sees EOF.
#
# Expected outcome, by design: on POSIX the TERM handler runs, the backend
# dies, prove finishes at once. On Windows TerminateProcess gives the
# frontend no chance to run its handler, the backend survives holding
# prove's pipes, and prove finishes only when the backend exits ~60s later.
# The log file (path printed in a diag) records test-exit vs backend-exit
# epochs so the delay is measured, not guessed.
use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);

diag '[' . time() . '] micro-hang-repro: start';
my $have_xs = eval {
    require Developer::Dashboard::GoRoutine;
    Developer::Dashboard::GoRoutine->import();
    1;
};
plan skip_all => 'GoRoutine XS unavailable' if !$have_xs;
diag '[' . time() . '] micro-hang-repro: GoRoutine loaded';

my $is_windows = $^O eq 'MSWin32' ? 1 : 0;
my $dir = tempdir( 'micro-hang-repro-XXXXXX', TMPDIR => 1, CLEANUP => 0 );
my $log     = File::Spec->catfile( $dir, 'hang.log' );
my $pidfile = File::Spec->catfile( $dir, 'backend.pid' );
diag "micro-hang-repro: log=$log pidfile=$pidfile";
my $backend_sleep = 60;

my $frontend_program = <<'FRONTEND_PERL';
use strict;
use warnings;
use Developer::Dashboard::GoRoutine ();
my ( $pidfile, $log, $backend_sleep ) = @ARGV;
my $backend_program = <<'BACKEND_PERL';
use strict;
use warnings;
my ( $log, $sleep ) = @ARGV;
open my $fh, '>>', $log or die "backend cannot open log: $!";
print {$fh} "backend started " . time() . "\n";
close $fh or die "backend cannot close log: $!";
sleep $sleep;
open $fh, '>>', $log or die "backend cannot reopen log: $!";
print {$fh} "backend exiting " . time() . "\n";
close $fh or die "backend cannot close log: $!";
exit 0;
BACKEND_PERL
my @library_args = map { ( '-I', $_ ) } grep { defined && -d $_ } @INC;
my $backend_pid = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, @library_args, '-e', $backend_program, $log, $backend_sleep ],
    {},
);
open my $fh, '>', $pidfile or die "frontend cannot write pidfile: $!";
print {$fh} $backend_pid;
close $fh or die "frontend cannot close pidfile: $!";
open $fh, '>>', $log or die "frontend cannot open log: $!";
print {$fh} "frontend started backend=$backend_pid " . time() . "\n";
close $fh or die "frontend cannot close log: $!";
$SIG{TERM} = sub {
    Developer::Dashboard::GoRoutine::terminate_process($backend_pid);
    Developer::Dashboard::GoRoutine::wait_process($backend_pid);
    exit 0;
};
for ( 1 .. 300 ) { sleep 1; }
exit 0;
FRONTEND_PERL

diag '[' . time() . '] micro-hang-repro: spawning frontend';
my @library_args = map { ( '-I', $_ ) } grep { defined && -d $_ } @INC;
my $frontend_pid = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, @library_args, '-e', $frontend_program, $pidfile, $log, $backend_sleep ],
    {},
);
ok( defined $frontend_pid && $frontend_pid > 0, 'frontend spawned' );
diag '[' . time() . "] micro-hang-repro: frontend pid=$frontend_pid";

diag '[' . time() . '] micro-hang-repro: waiting for backend pid file';
my $backend_pid;
for ( 1 .. 30 ) {
    if ( -e $pidfile ) {
        open my $fh, '<', $pidfile or die "cannot read pidfile: $!";
        $backend_pid = <$fh>;
        close $fh or die "cannot close pidfile: $!";
        chomp $backend_pid if defined $backend_pid;
        last;
    }
    sleep 1;
}
ok( defined $backend_pid && $backend_pid > 0, 'backend pid file appeared' );
diag '[' . time() . "] micro-hang-repro: backend pid=$backend_pid";
ok(
    Developer::Dashboard::GoRoutine::process_running($backend_pid),
    'backend running before frontend kill',
);

diag '[' . time() . "] micro-hang-repro: terminating frontend pid=$frontend_pid";
Developer::Dashboard::GoRoutine::terminate_process($frontend_pid);
my $status = Developer::Dashboard::GoRoutine::wait_process($frontend_pid);
diag '[' . time() . "] micro-hang-repro: frontend reaped status=$status";
ok(
    !Developer::Dashboard::GoRoutine::process_running($frontend_pid),
    'frontend reaped after termination',
);

my $backend_alive = Developer::Dashboard::GoRoutine::process_running($backend_pid) ? 1 : 0;
diag '[' . time() . "] micro-hang-repro: backend alive after frontend kill: $backend_alive (is_windows=$is_windows)";
is(
    $backend_alive,
    $is_windows ? 1 : 0,
    'backend survives frontend TerminateProcess on Windows only; POSIX TERM handler stops it',
);

open my $lfh, '>>', $log or die "test cannot open log: $!";
print {$lfh} "test exiting " . time() . " backend_alive=$backend_alive\n";
close $lfh or die "test cannot close log: $!";
diag '[' . time() . "] micro-hang-repro: test exiting; log=$log";
done_testing();
