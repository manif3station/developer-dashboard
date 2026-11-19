# t/982-micro-ssl-watchdog.t — MICRO, DO NOT SHIP. Proves the product
# watchdog in _serve_ssl_frontend (lib/Developer/Dashboard/Web/Server.pm):
# after the frontend is killed with GoRoutine::terminate_process, the
# backend dies and prove does NOT hang. Before the fix, solo #150 showed
# the Windows leg printing all 152 t/17 tests then hanging after the
# plan, and repro solo #181 proved the orphaned backend holds prove's
# pipes (61 wallclock seconds for a 2-second test). The watchdog is a
# separate process spawned by the frontend; it polls the frontend pid
# and kills the backend when the frontend disappears.
#
# Expected outcome, by design: on ALL legs the backend's internal port
# stops accepting within 10s of the frontend kill, and prove finishes
# in seconds (read the wallclock from the Jenkins console: the repro
# took 61s on Windows, this must be ~seconds). On POSIX the frontend
# TERM handler stops the backend; on Windows only the watchdog can, so
# the Windows leg is the decisive one. The backend sleep is unbounded
# in production (it is a real server), so the solo wallclock is the
# proof: a surviving backend would hold prove's pipes until the
# per-test silence timeout kills the run.
use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use IO::Socket::INET;

diag '[' . time() . '] micro-ssl-watchdog: start';
my $have_xs = eval {
    require Developer::Dashboard::GoRoutine;
    1;
};
# Require-only, on purpose: a runtime no-args import() after File::Temp is
# loaded dies with "Out of memory in perl:util:safesysrealloc" (proven 10/10
# on macOS, and it segfaults non-deterministically on ARM64). t/17 loads
# GoRoutine the same require-only way and is clean.
plan skip_all => 'GoRoutine XS unavailable' if !$have_xs;
diag '[' . time() . '] micro-ssl-watchdog: GoRoutine loaded';

my $is_windows = $^O eq 'MSWin32' ? 1 : 0;
my $dir = tempdir( 'micro-ssl-watchdog-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $temp_home = tempdir( 'micro-ssl-watchdog-home-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $portfile = File::Spec->catfile( $dir, 'internal.port' );
diag "micro-ssl-watchdog: portfile=$portfile";

my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    ReuseAddr => 1,
    Listen    => 5,
) or die "Unable to reserve live SSL test port: $!";
my $port = $listener->sockport;
close $listener or die "Unable to close reserved live SSL test port: $!";

my $frontend_program = <<'FRONTEND_PERL';
use strict;
use warnings;
use Developer::Dashboard::GoRoutine ();
use Developer::Dashboard::Web::Server;
{
    package Local::SSLTestApp;
    sub new { bless {}, shift }
    sub authorize_request { return; }
    sub root_response { return [ 200, 'text/plain; charset=utf-8', 'OK', {} ]; }
}
my ( $port, $home, $portfile ) = @ARGV;
$ENV{HOME} = $home;
my $server = Developer::Dashboard::Web::Server->new(
    app     => Local::SSLTestApp->new,
    host    => '127.0.0.1',
    port    => $port,
    workers => 1,
    ssl     => 1,
    ssl_backend_command_builder => sub {
        my ( $backend_host, $backend_port, $workers ) = @_;
        my $backend_program = <<'BACKEND_PERL';
use strict;
use warnings;
use Developer::Dashboard::GoRoutine ();
use Developer::Dashboard::Web::Server;
{
    package Local::SSLTestApp;
    sub new { bless {}, shift }
    sub authorize_request { return; }
    sub root_response { return [ 200, 'text/plain; charset=utf-8', 'OK', {} ]; }
}
my ( $host, $port, $workers ) = @ARGV;
my $server = Developer::Dashboard::Web::Server->new(
    app => Local::SSLTestApp->new, host => $host, port => $port,
    workers => $workers, ssl => 1,
);
my $daemon = Developer::Dashboard::Web::Server::Daemon->new(
    host => $host, port => $port, internal_host => $host, internal_port => $port,
);
exit $server->_run_ssl_backend_process($daemon);
BACKEND_PERL
        my @library_args = map { ( '-I', $_ ) } grep { defined && -d $_ } @INC;
        return [ $^X, @library_args, '-e', $backend_program, $backend_host, $backend_port, $workers ];
    },
);
my $daemon = $server->start_daemon;
open my $fh, '>', $portfile or die "frontend cannot write port file: $!";
print {$fh} $daemon->internal_sockport;
close $fh or die "frontend cannot close port file: $!";
exit $server->serve_daemon($daemon);
FRONTEND_PERL

diag '[' . time() . '] micro-ssl-watchdog: spawning frontend';
my @library_args = map { ( '-I', $_ ) } grep { defined && -d $_ } @INC;
my $frontend_pid = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, @library_args, '-e', $frontend_program, $port, $temp_home, $portfile ],
    {},
);
ok( defined $frontend_pid && $frontend_pid > 0, 'frontend spawned' );
diag '[' . time() . "] micro-ssl-watchdog: frontend pid=$frontend_pid port=$port";

diag '[' . time() . '] micro-ssl-watchdog: waiting for internal port file';
my $internal_port;
for ( 1 .. 100 ) {
    if ( -e $portfile ) {
        open my $fh, '<', $portfile or die "cannot read port file: $!";
        $internal_port = <$fh>;
        close $fh or die "cannot close port file: $!";
        chomp $internal_port if defined $internal_port;
        last;
    }
    select undef, undef, undef, 0.1;
}
ok( defined $internal_port && $internal_port > 0, 'frontend reserved an internal backend port' );
diag '[' . time() . "] micro-ssl-watchdog: internal port=$internal_port";

my $backend_up = 0;
for ( 1 .. 100 ) {
    my $probe = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $internal_port,
        Proto    => 'tcp',
        Timeout  => 1,
    );
    if ($probe) {
        close $probe;
        $backend_up = 1;
        last;
    }
    select undef, undef, undef, 0.1;
}
ok( $backend_up, 'backend accepts on the internal port before the frontend is killed' );

my $frontend_up = 0;
for ( 1 .. 100 ) {
    my $probe = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    );
    if ($probe) {
        close $probe;
        $frontend_up = 1;
        last;
    }
    select undef, undef, undef, 0.1;
}
ok( $frontend_up, 'frontend accepts on the public port before the kill' );

my $t0 = time();
diag '[' . time() . "] micro-ssl-watchdog: terminating frontend pid=$frontend_pid";
Developer::Dashboard::GoRoutine::terminate_process($frontend_pid);
my $status = Developer::Dashboard::GoRoutine::wait_process($frontend_pid);
diag '[' . time() . "] micro-ssl-watchdog: frontend reaped status=$status";
ok(
    !Developer::Dashboard::GoRoutine::process_running($frontend_pid),
    'frontend reaped after termination',
);
ok( defined $status, 'frontend termination status is collected' );

my $backend_dead = 0;
for ( 1 .. 40 ) {
    my $probe = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $internal_port,
        Proto    => 'tcp',
        Timeout  => 1,
    );
    if ( !$probe ) {
        $backend_dead = 1;
        last;
    }
    close $probe;
    select undef, undef, undef, 0.25;
}
my $t1 = time();
diag '[' . time() . "] micro-ssl-watchdog: backend dead after frontend kill: $backend_dead (is_windows=$is_windows) after " . ( $t1 - $t0 ) . "s";
is(
    $backend_dead,
    1,
    'watchdog killed the backend after the frontend died',
);

diag '[' . time() . '] micro-ssl-watchdog: test exiting';
done_testing();

__END__

=head1 NAME

t/982-micro-ssl-watchdog.t - Micro test of the product SSL backend watchdog

=head1 PURPOSE

Prove that the watchdog _serve_ssl_frontend spawns actually ends the
t/17 Windows post-plan hang in the shipped code: after the frontend is
killed with GoRoutine::terminate_process, the backend dies (its
internal port stops accepting) and prove finishes in seconds instead
of holding the harness pipes open until the per-test silence timeout
kills the run.

=head1 WHY IT EXISTS

Solo #150 proved the hang in t/17 on Windows, and repro solo #181
proved the mechanism: the orphaned backend holds prove's pipes. The
fix-tester micro-proved the watchdog design in miniature (solo #182,
2 wallclock seconds on Windows). This micro proves the design as
implemented in the product, before the full t/17 solo runs, so a
regression in the real _serve_ssl_frontend path is caught here and not
in the 152-test file.

=head1 WHEN TO USE

Use this file only while verifying the SSL backend watchdog on the
redesign branch. Run it as a Jenkins solo against the redesign
branch, never by hand and never as part of a release check. It is a
throwaway diagnostic: remove it from the branch in a cleanup commit
as soon as the investigation reports back, and never ship it.

=head1 HOW TO USE

Trigger it as a Jenkins solo on branch goroutine-c-async with the test
file set to t/982-micro-ssl-watchdog.t, then read the per-leg verdicts
from the saved console and compare the prove wallclock against the
repro micro's 61 seconds on Windows. The test prints the frontend pid,
the public and internal ports, and the backend-dead reading after the
frontend is killed. On every leg the backend must read dead within
10s of the kill; the wallclock must be seconds, not minutes. The
frontend block and the port polls are all bounded, so the micro
itself can never hang forever. Do not run it on a machine where stray
perl processes would matter: a crashed run can orphan a frontend and
backend, so check the node is clean afterwards.

=head1 WHAT USES IT

Nothing in the product uses this file. It is run only by the Jenkins
solo trigger during the shutdown-hang verification, and its verdicts
are read by the investigating agent from the saved build console. The
full test suite does not depend on it, and no other test file loads
it.

=head1 EXAMPLES

Run it as a Jenkins solo on the redesign branch:

  TEST_FILE=t/982-micro-ssl-watchdog.t, branch goroutine-c-async

Read the measured outcome from the diag lines after a run:

  micro-ssl-watchdog: frontend pid=1234 port=18001
  micro-ssl-watchdog: internal port=18002
  micro-ssl-watchdog: backend dead after frontend kill: 1 (is_windows=1) after 1s

On every leg the backend must be dead when the test exits; on Windows
that is the proof the product watchdog ends the hang.

=cut
