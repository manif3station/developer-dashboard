use strict;
use warnings;
use utf8;

# Micro-repro for Jenkins build #94: t/05 test 247 stalls on Windows.
# Build #94 (t/05 solo, tip 5ef4c70f): amd64/macOS/ARM64 PASS 1036/1036.
# Windows passed 246/246, then the fail-safe tripped on 3 minutes of no
# test output during test 247, the `d2 restart -o json` step of the
# no-indicators lifecycle (server on a free port, started with
# serve --no-indicator). Zero genuine `not ok` lines. The earlier
# no-editor `d2 restart` (tests 225-227) passes on Windows, so restart
# in general works there.
#
# This micro splits the restart into its phases, logging BEFORE and AFTER
# every step with a wall-clock timestamp, so the console shows exactly
# which phase sticks:
#   Phase B: `d2 stop` alone, then is the port still accepting?
#   Phase C: `d2 serve` alone (the start half of restart).
#   Phase D: the exact `d2 restart -o json` step from t/05.
# If stop is fast but the port stays accepting, the old server survives
# stop_web and the new server can never bind, so _restart_web_with_retry
# burns 20 attempts x up to 30s of readiness polling (> 3 min silence).
# If stop and serve are fast but restart sticks, the stall is in
# restart's own sequencing (start_collectors between stop and start).
# If serve sticks, the stall is in the start/readiness path.
# The fail-safe's 3-minute silence trip bounds any one stuck phase; the
# last BEFORE line in the console names it.

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so
# this process runs the tip's Perl modules exactly like the CLI
# subprocesses already do (same drift fix as t/05, commit cbf9855d).
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(getcwd);
use Developer::Dashboard::JSON qw(json_decode);
use Developer::Dashboard::PerlEnv;
use Encode qw(decode);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use LWP::UserAgent;
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo = getcwd();
my @built_perl_libs = grep { -d $_ } map { File::Spec->catdir( $repo, 'blib', $_ ) } qw(arch lib);
local $ENV{PERL5LIB} = join Developer::Dashboard::PerlEnv::path_separator(), grep { defined && $_ ne '' } ( @built_perl_libs, $ENV{PERL5LIB} || () );
local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

my $T0 = time();

sub _elapsed {
    return sprintf( '%.1fs', time() - $T0 );
}

sub _log {
    my ($msg) = @_;
    diag( '[' . _elapsed() . "] $msg" );
}

# _run_logged($label, $cmd)
# Logs BEFORE and AFTER a shell command with wall-clock times, then
# returns (stdout+stderr decoded, exit code). No TAP assertion inside:
# the caller asserts, so a stuck phase leaves its BEFORE line as the
# last console line. Runtime commands (serve/restart/stop) run with
# PERL5OPT/HARNESS stripped, exactly like t/05's _run().
sub _run_logged {
    my ( $label, $cmd ) = @_;
    _log("BEFORE $label: $cmd");
    my $start = time();
    my %env;
    if ( $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop)\b/ ) {
        $env{PERL5OPT}              = undef;
        $env{HARNESS_PERL_SWITCHES} = undef;
    }
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => \%env } );
    _log( sprintf( 'AFTER %s: exit=%d in %.1fs', $label, $exit_code, time() - $start ) );
    return ( decode( 'UTF-8', $stdout . $stderr ), $exit_code );
}

sub _run_in_home_logged {
    my ( $home, $label, $cmd ) = @_;
    return _run_logged( $label, "cd '$home' && $cmd" );
}

sub _find_free_port {
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Unable to reserve a free local TCP port: $!";
    my $port = $socket->sockport();
    close $socket or die "Unable to release reserved local TCP port $port: $!";
    return $port;
}

# _port_accepting($port)
# True when something answers a TCP connect on the port right now.
sub _port_accepting {
    my ($port) = @_;
    my $socket = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 2,
    );
    return 0 if !$socket;
    close $socket;
    return 1;
}

# _wait_ready($ua, $port, $label)
# Same readiness loop as t/05 (240 x 0.25s). Logs when ready and how
# many polls it took, or that it never became ready.
sub _wait_ready {
    my ( $ua, $port, $label ) = @_;
    my $response;
    for my $poll ( 1 .. 240 ) {
        $response = $ua->get("http://127.0.0.1:$port/system/status");
        if ( $response->is_success ) {
            _log("$label: ready after $poll polls");
            return $response;
        }
        sleep 0.25;
    }
    _log("$label: NOT ready after 240 polls");
    return $response;
}

{
    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

    my ( $out, $rc );

    ( $out, $rc ) = _run_in_home_logged( $home, 'init', "$perl -I'$lib' '$dashboard' init" );
    like( $out, qr/runtime_root/, 'micro init initializes a runtime' );

    ( $out, $rc ) = _run_in_home_logged( $home, 'page-new', "$perl -I'$lib' '$dashboard' page new noind 'No Indicators'" );
    my $source_file = File::Spec->catfile( $home, 'noind.page' );
    open my $source_fh, '>:raw', $source_file or die "Unable to write $source_file: $!";
    print {$source_fh} $out;
    close $source_fh;
    ( $out, $rc ) = _run_in_home_logged( $home, 'page-save', "$perl -I'$lib' '$dashboard' page save noind < '$source_file'" );

    my $port = _find_free_port();
    _log("using port $port");
    ( $out, $rc ) = _run_in_home_logged( $home, 'serve-noind', "$perl -I'$lib' '$dashboard' serve --host 127.0.0.1 --port $port --no-indicator" );
    my $serve = eval { json_decode($out) };
    ok( $serve && $serve->{pid}, 'micro serve --no-indicator starts the web service' );
    _log( 'serve pid: ' . ( $serve && $serve->{pid} ? $serve->{pid} : '(none)' ) );

    my $ua = LWP::UserAgent->new( timeout => 5 );
    my $ready = _wait_ready( $ua, $port, 'serve-noind readiness' );
    ok( $ready && $ready->is_success, 'micro no-indicators server answers before restart phases' );
    _log( 'pre-stop port accepting: ' . ( _port_accepting($port) ? 'yes' : 'no' ) );

    # Phase B: stop alone, timed. Then is the port really free?
    ( $out, $rc ) = _run_in_home_logged( $home, 'stop-alone', "$perl -I'$lib' '$dashboard' stop -o json" );
    my $stop = eval { json_decode($out) };
    ok( $stop && ref( $stop->{collectors} ) eq 'ARRAY', 'micro stop alone returns collectors' );
    _log( 'post-stop port accepting: ' . ( _port_accepting($port) ? 'YES - old server still listening' : 'no' ) );
    ok( !_port_accepting($port), 'micro port is free after stop alone' );

    # Phase C: serve alone (the start half of restart), timed.
    ( $out, $rc ) = _run_in_home_logged( $home, 'serve-again', "$perl -I'$lib' '$dashboard' serve --host 127.0.0.1 --port $port --no-indicator" );
    my $serve2 = eval { json_decode($out) };
    ok( $serve2 && $serve2->{pid}, 'micro serve alone restarts the web service' );
    _log( 'serve-again pid: ' . ( $serve2 && $serve2->{pid} ? $serve2->{pid} : '(none)' ) );
    my $ready2 = _wait_ready( $ua, $port, 'serve-again readiness' );
    ok( $ready2 && $ready2->is_success, 'micro server answers after serve alone' );

    # Phase D: the exact t/05 step 247, timed.
    ( $out, $rc ) = _run_in_home_logged( $home, 'restart-exact', "$perl -I'$lib' '$dashboard' restart -o json --host 127.0.0.1 --port $port" );
    my $restart = eval { json_decode($out) };
    ok( $restart && $restart->{web_pid}, 'micro restart keeps managing the no-indicators web service' );
    my $ready3 = _wait_ready( $ua, $port, 'post-restart readiness' );
    ok( $ready3 && $ready3->is_success, 'micro server answers after restart' );

    # Cleanup: stop everything we started.
    ( $out, $rc ) = _run_in_home_logged( $home, 'stop-cleanup', "$perl -I'$lib' '$dashboard' stop -o json" );
    _log( 'post-cleanup port accepting: ' . ( _port_accepting($port) ? 'YES' : 'no' ) );
}

done_testing;
