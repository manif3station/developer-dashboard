use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(getcwd);
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Encode qw(decode encode);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $UNDER_COVER = exists $INC{'Devel/Cover.pm'};
my $repo        = getcwd();

my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

my $runtime_dd_cli_root;

# _run, _run_in_dir, _run_in_home and _find_free_port are copied verbatim
# from t/05-cli-smoke.t so the micro drives the CLI exactly the way the
# failing test does. _run_quiet is the same runner without the assertion,
# for diagnostics that must never trip the FAIL-SAFE watchdog themselves.
sub _run {
    my ($cmd) = @_;
    my $child_perl5opt = join ' ', grep { defined $_ && $_ ne '' } ( $ENV{PERL5OPT}, $ENV{HARNESS_PERL_SWITCHES} );
    my $runtime_command = (
        defined $dashboard
          && $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop)\b/
    ) || (
        defined $runtime_dd_cli_root
          && $cmd =~ /\Q'$runtime_dd_cli_root\E\/(?:_dashboard-core|doctor|serve|restart|stop)\b/
    );
    my %env;
    if ($runtime_command) {
        $env{PERL5OPT}              = undef;
        $env{HARNESS_PERL_SWITCHES} = undef;
    }
    elsif ( _coverage_requested() ) {
        $env{PERL5OPT} = $child_perl5opt;
    }
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => \%env } );
    is( $exit_code, 0, "command succeeded: $cmd" );
    return decode( 'UTF-8', $stdout . $stderr );
}

sub _coverage_requested {
    my $perl5opt = join ' ', grep { defined && $_ ne '' } @ENV{qw(PERL5OPT HARNESS_PERL_SWITCHES)};
    return $perl5opt =~ /Devel::Cover/ || exists $INC{'Devel/Cover.pm'};
}

sub _run_quiet {
    my ($cmd) = @_;
    my $child_perl5opt = join ' ', grep { defined $_ && $_ ne '' } ( $ENV{PERL5OPT}, $ENV{HARNESS_PERL_SWITCHES} );
    my $runtime_command = (
        defined $dashboard
          && $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop)\b/
    );
    my %env;
    if ($runtime_command) {
        $env{PERL5OPT}              = undef;
        $env{HARNESS_PERL_SWITCHES} = undef;
    }
    elsif ( _coverage_requested() ) {
        $env{PERL5OPT} = $child_perl5opt;
    }
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => \%env } );
    return ( decode( 'UTF-8', $stdout . $stderr ), $exit_code );
}

sub _run_in_dir {
    my ( $dir, $cmd ) = @_;
    die "run directory is required\n" if !defined $dir || $dir eq '';
    die "command is required\n" if !defined $cmd || $cmd eq '';
    return _run("cd '$dir' && $cmd");
}

sub _run_in_home {
    my ( $home, $cmd ) = @_;
    die "home directory is required\n" if !defined $home || $home eq '';
    return _run_in_dir( $home, $cmd );
}

sub _run_quiet_in_home {
    my ( $home, $cmd ) = @_;
    die "home directory is required\n" if !defined $home || $home eq '';
    die "command is required\n" if !defined $cmd || $cmd eq '';
    my ( $out, $exit ) = _run_quiet("cd '$home' && $cmd");
    return $out;
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

# Reproduce the t/05 test-360 scenario with instrumentation: the same
# temp home, the same tick.collector config (interval 1), the same serve,
# and the same poll loop, but only 40 iterations (the healthy case shows
# output within about 3 polls, so 40 is ample) and with a log line before
# and after every poll. The post-mortem diagnostics run BEFORE the final
# assertion: the FAIL-SAFE watchdog kills prove on the first failure line,
# so anything after the like would never run if the bug reproduces.
if ( !$UNDER_COVER ) {
    my $serve_home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $serve_home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
    my $serve_init = _run_in_home( $serve_home, "$perl -I'$lib' '$dashboard' init" );
    like( $serve_init, qr/runtime_root/, 'micro: isolated lifecycle smoke home initializes a runtime for serve/restart collector checks' );
    my $serve_config_file = File::Spec->catfile( $serve_home, '.developer-dashboard', 'config', 'config.json' );
    open my $serve_config_fh, '>:raw', $serve_config_file or die "Unable to write $serve_config_file: $!";
    my $serve_config_json = json_encode(
        {
            collectors => [
                {
                    name     => 'tick.collector',
                    command  => q{perl -MTime::HiRes=time -e 'printf qq{%.6f\n}, time'},
                    cwd      => 'home',
                    interval => 1,
                },
            ],
        }
    );
    $serve_config_json = encode( 'UTF-8', $serve_config_json ) if utf8::is_utf8($serve_config_json);
    print {$serve_config_fh} $serve_config_json;
    close $serve_config_fh;
    my $serve_port = _find_free_port();
    my $serve_json = json_decode( _run_in_home( $serve_home, "$perl -I'$lib' '$dashboard' serve --host 127.0.0.1 --port $serve_port" ) );
    ok( $serve_json->{pid}, 'micro: d2 serve returns a managed web pid for the collector lifecycle smoke test' );
    note( sprintf 'micro: serve pid=%s port=%s', $serve_json->{pid} // '(undef)', $serve_port );

    my $t0           = time();
    my $first_stdout = '';
    my $poll_count   = 0;
    for my $i ( 1 .. 40 ) {
        my $poll_start = time();
        my $output     = json_decode( _run_in_home( $serve_home, "$perl -I'$lib' '$dashboard' collector output tick.collector" ) );
        my $poll_secs  = time() - $poll_start;
        $poll_count   = $i;
        $first_stdout = $output->{stdout} || '';
        my $shown = $first_stdout eq '' ? '(empty)' : $first_stdout;
        $shown =~ s/\n/\\n/g;
        note( sprintf 'micro: poll %d elapsed=%.2fs poll=%.2fs stdout=%s', $i, time() - $t0, $poll_secs, $shown );
        last if $first_stdout =~ /^\d+\.\d+\n$/;
        if ( $i % 10 == 0 ) {
            my $status_raw = _run_quiet_in_home( $serve_home, "$perl -I'$lib' '$dashboard' collector status tick.collector" );
            $status_raw =~ s/\n/\\n/g;
            note("micro: status at poll $i: $status_raw");
        }
        sleep 0.25;
    }
    note( sprintf 'micro: polls=%d total_elapsed=%.2fs', $poll_count, time() - $t0 );

    # Post-mortem diagnostics, before the assertion that may fail.
    my $status_raw = _run_quiet_in_home( $serve_home, "$perl -I'$lib' '$dashboard' collector status tick.collector" );
    diag("micro: final collector status:\n$status_raw");
    # Prefer the JSON "pid" key (the loop pid). Fall back to a bare pid
    # field, but never the web pid: "web pid" is the serve process, not
    # the loop, and reporting it alive would misattribute liveness.
    my ($loop_pid) = $status_raw =~ /"pid"\s*:\s*(\d+)/;
    if ( !$loop_pid ) {
        my @pids = $status_raw =~ /(?<!web\s)\bpid\b\s*[:=]\s*(\d+)/gi;
        $loop_pid = $pids[0] if @pids;
    }
    if ($loop_pid) {
        diag( sprintf 'micro: loop pid %s alive=%d', $loop_pid, kill( 0, $loop_pid ) ? 1 : 0 );
    }
    else {
        diag('micro: no loop pid parsed from collector status');
    }
    my $inspect_raw = _run_quiet_in_home( $serve_home, "$perl -I'$lib' '$dashboard' collector inspect tick.collector" );
    diag("micro: collector inspect:\n$inspect_raw");
    my $log_raw = _run_quiet_in_home( $serve_home, "$perl -I'$lib' '$dashboard' collector log tick.collector" );
    my @log_lines = split /\n/, $log_raw;
    my $tail_from = @log_lines > 30 ? @log_lines - 30 : 0;
    my $log_tail  = join "\n", @log_lines[ $tail_from .. $#log_lines ];
    diag("micro: collector log tail (last 30 lines):\n$log_tail");

    # Stop everything so no orphan loop or web server lingers. The like
    # below reads the already-captured $first_stdout, so stopping first
    # cannot change its outcome.
    _run_quiet_in_home( $serve_home, "$perl -I'$lib' '$dashboard' stop -o json" );

    like( $first_stdout, qr/^\d+\.\d+\n$/, 'micro: serve-started interval collector output appears' );
}

done_testing();

__END__

=head1 NAME

t/997-micro-t05-360.t - Micro-repro for the round-25 ARM64 t/05 test 360 failure

=head1 PURPOSE

Reproduce the exact t/05 test-360 scenario (serve starts a 1-second
interval tick.collector, then poll `collector output` until its stdout
matches a timestamp) with per-poll instrumentation, on the Jenkins nodes,
to measure whether the serve-started collector ever ticks on ARM64 and how
long each poll iteration takes.

=head1 WHY IT EXISTS

Round 25 (Jenkins build #211) failed on ARM64 t/05 test 360 only: the
poll loop ran all 160 iterations and the collector output stayed empty.
The same test passed on ARM64 in round 14 and in solo #176, and passed on
amd64 and macOS in round 25. No loop-branch change since #176 touches
serve or collectors, so the cause is unproven: slow-machine timing on the
Pi, or a real serve/collector regression. This micro reproduces the exact
scenario with logs before and after every poll so the mechanism can be
read off the console instead of guessed.

=head1 WHEN TO USE

Run as a Jenkins solo (TEST_FILE=t/997-micro-t05-360.t) when diagnosing
the t/05 test 360 failure. Remove it in a cleanup commit once the
investigation ends: it is a diagnostic, not a regression test.

=head1 HOW TO USE

Trigger with the durable helper:
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/997-micro-t05-360.t 1
Read the console: each poll logs its index, elapsed time, poll duration
and stdout value; every tenth poll logs the collector status; after the
loop the micro prints the final collector status, the loop pid liveness,
the collector inspect output and the last 30 lines of the collector log,
then asserts the output appeared.

=head1 WHAT USES IT

Nothing in the product uses this file. It is run by hand (via Jenkins
solos) during the t/05-360 investigation only.

=head1 EXAMPLES

Jenkins solo on the loop branch:
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/997-micro-t05-360.t 1
Healthy run: the output appears within about 3 polls and the final like
passes. Sick run (the round-25 signature): 40 polls, every stdout empty,
and the post-mortem shows whether the loop is alive, what its status is,
and what the collector log says about the missing ticks.

=cut
