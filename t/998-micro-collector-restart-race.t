use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). See t/05 for the full note.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Developer::Dashboard::JSON qw(json_decode json_encode);
use Developer::Dashboard::PathRegistry;
use Cwd qw(getcwd);
use Encode qw(decode encode);
use File::Temp qw(tempdir);
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

sub _coverage_requested {
    return 1 if $UNDER_COVER;
    my $perl5opt = join ' ', grep { defined $_ && $_ ne '' } ( $ENV{PERL5OPT}, $ENV{HARNESS_PERL_SWITCHES} );
    return $perl5opt =~ /Devel::Cover/ ? 1 : 0;
}

# _run($cmd) - copied from t/05: runs one shell command, asserting exit 0.
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

# _quiet_run($home, $cmd) - like _run_in_home but with no Test::More
# assertions, so the END cleanup cannot corrupt the plan.
sub _quiet_run {
    my ( $home, $cmd ) = @_;
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( "cd '$home' && $cmd", { env => {} } );
    return decode( 'UTF-8', ( $stdout // '' ) . ( $stderr // '' ) );
}

sub _slurp {
    my ($path) = @_;
    return if !defined $path || !-f $path;
    open my $fh, '<', $path or return;
    local $/;
    my $content = scalar <$fh>;
    close $fh;
    return $content;
}

sub _proc_cmdline {
    my ($pid) = @_;
    return if $^O eq 'MSWin32';
    return if !defined $pid || $pid !~ /^\d+$/;
    my $raw = _slurp("/proc/$pid/cmdline");
    return if !defined $raw;
    $raw =~ s/\0/ /g;
    $raw =~ s/\s+$//;
    return $raw;
}

# _supervisor_pids() - pids whose command line mentions the collector
# supervisor, by a /proc scan. Unix only; the supervisor title is
# 'd2 collector supervisor', and before its $0 assignment the spawn argv
# still carries the word supervisor.
sub _supervisor_pids {
    return () if $^O eq 'MSWin32';
    return () if !-d '/proc';
    opendir my $dh, '/proc' or return ();
    my @found;
    while ( my $entry = readdir $dh ) {
        next if $entry !~ /^\d+$/;
        my $cmdline = _proc_cmdline($entry);
        next if !defined $cmdline || $cmdline eq '';
        push @found, $entry + 0 if $cmdline =~ /supervisor/i;
    }
    closedir $dh;
    return sort { $a <=> $b } @found;
}

# _loop_snapshot($home, $pid) - the observable registration state for one
# collector loop: pidfile, loop.json, liveness, title, supervisor state.
# No CLI call is made here, so sampling cannot disturb the window.
sub _loop_snapshot {
    my ( $home, $pid ) = @_;
    my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
    my $pidfile = File::Spec->catfile( $paths->collectors_root, 'cli.collector.pid' );
    my $statefile = File::Spec->catfile( $paths->collector_dir('cli.collector'), 'loop.json' );
    my $pidfile_content = _slurp($pidfile);
    chomp $pidfile_content if defined $pidfile_content;
    my $state_raw  = _slurp($statefile);
    my $state      = defined $state_raw && $state_raw ne '' ? eval { json_decode($state_raw) } : undef;
    my $sup_state_raw = _slurp( File::Spec->catfile( $paths->state_root, 'collector-supervisor.json' ) );
    my $sup_state = defined $sup_state_raw && $sup_state_raw ne '' ? eval { json_decode($sup_state_raw) } : undef;
    return {
        pidfile       => defined $pidfile_content ? $pidfile_content : undef,
        state         => ( ref($state) eq 'HASH' ? $state : undef ),
        state_raw     => $state_raw,
        alive         => ( defined $pid && $pid =~ /^\d+$/ ) ? ( kill( 0, $pid ) ? 1 : 0 ) : undef,
        cmdline       => _proc_cmdline($pid),
        supervisors   => [ _supervisor_pids() ],
        sup_state_pid => ( ref($sup_state) eq 'HASH' ? $sup_state->{pid} : undef ),
        sup_watched   => ( ref($sup_state) eq 'HASH' ? $sup_state->{watched_names} : undef ),
        sup_status    => ( ref($sup_state) eq 'HASH' ? $sup_state->{status} : undef ),
    };
}

sub _snapshot_line {
    my ( $label, $snap, $pid ) = @_;
    my $state = $snap->{state};
    my $state_desc = !defined $state ? 'no-state'
      : sprintf 'state pid=%s status=%s', ( $state->{pid} // '?' ), ( $state->{status} // '?' );
    my $sup = @{ $snap->{supervisors} }
      ? 'supervisors=[' . join( ',', @{ $snap->{supervisors} } ) . ']'
      : 'supervisors=[]';
    my $sup_state = defined $snap->{sup_state_pid}
      ? sprintf 'sup-state pid=%s status=%s watched=[%s]', $snap->{sup_state_pid}, ( $snap->{sup_status} // '?' ),
      join( ',', @{ $snap->{sup_watched} || [] } )
      : 'sup-state=none';
    my $title = defined $snap->{cmdline} ? sprintf 'cmdline=[%s]', $snap->{cmdline} : 'cmdline=?';
    diag(
        sprintf '%s: pidfile=%s %s alive=%s %s %s %s',
        $label, ( defined $snap->{pidfile} ? $snap->{pidfile} : 'absent' ),
        $state_desc, ( $snap->{alive} // '?' ), $title, $sup, $sup_state
    );
    return;
}

sub _table_row {
    my ($table) = @_;
    return 'stopped'     if $table =~ /collector\s+cli\.collector\s+stopped/;
    return 'not running' if $table =~ /collector\s+cli\.collector\s+not running/;
    return 'no-row'      if $table !~ /cli\.collector/;
    return 'other';
}

sub _fresh_home {
    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
    my $init = _run_in_home( $home, "$perl -I'$lib' '$dashboard' init" );
    like( $init, qr/runtime_root/, 'isolated micro home initializes a runtime' );
    my $config_file = File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' );
    open my $fh, '>:raw', $config_file or die "Unable to write $config_file: $!";
    my $config_json = json_encode(
        {
            collectors => [
                {
                    name    => 'cli.collector',
                    command => q{perl -e "print qq(cli stdout\n); print STDERR qq(cli stderr\n)"},
                    cwd     => 'home',
                },
            ],
        }
    );
    $config_json = encode( 'UTF-8', $config_json ) if utf8::is_utf8($config_json);
    print {$fh} $config_json;
    close $fh;
    return $home;
}

my @homes;

# PHASE A: registration timeline. Start one loop, then poll ONLY files, the
# pid and /proc every 0.1s for up to 10s - no CLI call inside the window, so
# nothing disturbs the state the stop path will read.
{
    diag('PHASE A: registration timeline (files + pid + /proc only, no CLI call in the window)');
    my $home = _fresh_home();
    push @homes, $home;
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

    my $start_out = _run_in_home( $home, "$perl -I'$lib' '$dashboard' collector start cli.collector" );
    like( $start_out, qr/\A\d+\n\z/, 'PHASE A: collector start prints the loop pid' );
    my ($pid) = $start_out =~ /(\d+)/;
    diag("PHASE A: start returned pid $pid");

    my $t0            = time();
    my $visible_ms    = undef;
    my $visible_snap  = undef;
    my $last_snap     = undef;
    my $iterations    = 0;
    for my $i ( 0 .. 99 ) {
        $iterations = $i + 1;
        my $snap = _loop_snapshot( $home, $pid );
        $last_snap = $snap;
        my $state = $snap->{state};
        if ( defined $snap->{pidfile} && $snap->{pidfile} eq "$pid"
            && ref($state) eq 'HASH' && ( $state->{pid} || 0 ) == $pid
            && ( $state->{status} || '' ) =~ /^(?:starting|running|error)$/
            && $snap->{alive} )
        {
            $visible_ms   = int( ( time() - $t0 ) * 1000 );
            $visible_snap = $snap;
            _snapshot_line( "PHASE A: first visible at ${visible_ms}ms", $snap, $pid );
            last;
        }
        if ( $i % 10 == 9 ) {
            _snapshot_line( sprintf( 'PHASE A: poll heartbeat %.1fs', time() - $t0 ), $snap, $pid );
        }
        sleep 0.1;
    }
    if ( !defined $visible_ms ) {
        _snapshot_line( 'PHASE A: NEVER visible after 10s', $last_snap, $pid );
    }
    ok( defined $visible_ms,
        defined $visible_ms
        ? "PHASE A: loop became visible ${visible_ms}ms after start"
        : 'PHASE A: loop NEVER became visible within 10s of start' );
    if ( defined $visible_snap ) {
        diag( 'PHASE A: title at first-visible: [' . ( $visible_snap->{cmdline} // '?' ) . ']' );
    }

    my $status = json_decode( _run_in_home( $home, "$perl -I'$lib' '$dashboard' collector status cli.collector" ) );
    ok( 1, 'PHASE A: collector status after visible: running=[' . ( $status->{running} ? '1' : '0' ) . ']' );

    my $stop_table = _run_in_home( $home, "$perl -I'$lib' '$dashboard' stop collector cli.collector" );
    my $row = _table_row($stop_table);
    ok( 1, "PHASE A: stop table row after visible: [$row]" );
    _snapshot_line( 'PHASE A: snapshot after stop', _loop_snapshot( $home, $pid ), $pid );
}

# PHASE B: delay sweep. Re-start, wait a fixed delay, stop, record the row.
# Measurement only: the outcome is in the test name, so a slow leg cannot
# trip fail-fast mid-sweep and truncate the window map.
{
    diag('PHASE B: delay sweep (stop at +0.5s, +2s, +5s after re-start)');
    my $home = _fresh_home();
    push @homes, $home;
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

    for my $delay ( 0.5, 2, 5 ) {
        my $start_out = _run_in_home( $home, "$perl -I'$lib' '$dashboard' collector start cli.collector" );
        my ($pid) = $start_out =~ /(\d+)/;
        diag("PHASE B: +${delay}s round: start returned pid " . ( defined $pid ? $pid : '?' ));
        sleep $delay;
        my $stop_table = _run_in_home( $home, "$perl -I'$lib' '$dashboard' stop collector cli.collector" );
        my $row = _table_row($stop_table);
        ok( 1, "PHASE B: stop at +${delay}s row: [$row]" );
        _snapshot_line( "PHASE B: snapshot after +${delay}s stop", _loop_snapshot( $home, $pid ), $pid );
    }
}

# PHASE C: the exact t/05 shape (fresh home): start, subcommand stop,
# status not running, re-start, IMMEDIATELY stop. The row assertion is the
# last test in the file, so every measurement above is already collected
# even if this leg reproduces the race and goes red here.
{
    diag('PHASE C: exact t/05 shape (start, subcommand stop, status, re-start, immediate stop)');
    my $home = _fresh_home();
    push @homes, $home;
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

    my $collector_start_pid = _run_in_home( $home, "$perl -I'$lib' '$dashboard' collector start cli.collector" );
    like( $collector_start_pid, qr/\A\d+\n\z/, 'PHASE C: d2 collector start still starts one named collector loop directly' );

    my $collector_subcmd_stop = _run_in_home( $home, "$perl -I'$lib' '$dashboard' collector stop cli.collector" );
    like( $collector_subcmd_stop, qr/\A(?:\d+\n)?\z/, 'PHASE C: d2 collector stop <name> prints the stopped loop pid (or nothing when already stopped)' );
    my $collector_subcmd_stopped_status = json_decode( _run_in_home( $home, "$perl -I'$lib' '$dashboard' collector status cli.collector" ) );
    ok( !$collector_subcmd_stopped_status->{running}, 'PHASE C: d2 collector stop <name> leaves the collector not running so the supervisor cannot respawn it' );

    my $restart_out = _run_in_home( $home, "$perl -I'$lib' '$dashboard' collector start cli.collector" );
    like( $restart_out, qr/\A\d+\n\z/, 'PHASE C: re-start prints the loop pid' );
    my ($pid) = $restart_out =~ /(\d+)/;
    diag("PHASE C: re-start returned pid " . ( defined $pid ? $pid : '?' ));
    _snapshot_line( 'PHASE C: snapshot immediately after re-start, before stop', _loop_snapshot( $home, $pid ), $pid );

    my $top_level_stop_named_collector = _run_in_home( $home, "$perl -I'$lib' '$dashboard' stop collector cli.collector" );
    like( $top_level_stop_named_collector, qr/Component\s+Target\s+Status/, 'PHASE C: d2 stop collector <name> prints a table summary by default' );
    _snapshot_line( 'PHASE C: snapshot immediately after stop', _loop_snapshot( $home, $pid ), $pid );
    like( $top_level_stop_named_collector, qr/collector\s+cli\.collector\s+stopped/, 'PHASE C: d2 stop collector <name> reports the named collector row' );
}

# Best-effort cleanup with no Test::More assertions, so the plan is not
# corrupted: stop everything (collectors, web, supervisor) in every home
# this micro created, leaving no live loop behind for the orphan detector.
END {
    for my $home (@homes) {
        next if !defined $home || $home eq '' || !-d $home;
        local $ENV{HOME} = $home;
        eval { _quiet_run( $home, "$perl -I'$lib' '$dashboard' stop" ); };
    }
}

done_testing();

__END__

=head1 NAME

t/998-micro-collector-restart-race.t - micro-probe for the round-36 t/05 test 323 race

=head1 DESCRIPTION

Reproduces the exact t/05 collector start/stop sequence that failed once on
ARM64 in round 36 (build #353) and measures, instead of assuming, why the
top-level stop table said "not running" instead of "stopped". It samples the
pidfile, loop.json, process liveness, process title and supervisor state
around the re-start, and maps the stop-table outcome against the delay after
the re-start.

=head1 PURPOSE

Prove which of the candidate mechanisms explains the round-36 failure:
(a) the re-started loop is alive but slow to register as running, so the
stop runs inside the invisible window; (b) the re-started loop dies or never
registers; or (c) a stale supervisor interferes between the re-start and the
stop. The measurements - registration delay, pid liveness over time, state
content, supervisor pids - distinguish them.

=head1 WHY IT EXISTS

Round 36 failed on exactly one test, ARM64 t/05 test 323: the stop table
showed "collector cli.collector not running / no running collectors" right
after a re-start that had returned a pid and passed its own readiness check.
The same test passed on the other legs and on ARM64 in solo #348, so the
failure is intermittent and timing-shaped. Guessing the fix without measuring
the window would be a second guess on top of the first failure.

=head1 WHEN TO USE

Run as a Jenkins solo (TEST_FILE=t/998-micro-collector-restart-race.t) when
adjudicating the round-36 t/05 test 323 failure. Remove in a cleanup commit
once the mechanism is proven and the real fix is decided.

=head1 HOW TO USE

Trigger through Jenkins only, never by hand over SSH: the job runs it on all
four platforms at once. Read the diag lines: the Phase A first-visible
millisecond count, the Phase B stop-row outcomes at +0.5s/+2s/+5s, and the
Phase C snapshots around the immediate stop. The Phase C row assertion is
the last test, so a reproducing leg goes red only after every measurement
has printed.

=head1 WHAT USES IT

Nothing in the product uses this file. The testing-v1 loop uses it once, as
the micro-probe for the round-36 failure, and then it is removed.

=head1 EXAMPLES

Jenkins solo: TEST_FILE=t/998-micro-collector-restart-race.t, BRANCH=windows/loop6-combined, ROUNDS=1.

=cut
