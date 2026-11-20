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

# The title a live loop child carries once it has done its $0 assignment.
# Used only to classify sampled process names; the stop path itself compares
# against _process_title, and probe #355 observed this exact string live.
my $EXPECTED_TITLE = 'd2 collector: cli.collector';

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

# _cmd($home, $cmd) - like _run_in_home but with NO Test::More assertion:
# returns (combined output, exit code) so one bad iteration cannot trip the
# fail-fast watchdog and truncate the repetition. A failing CLI call is
# recorded in the iteration summary instead of failing the file.
sub _cmd {
    my ( $home, $cmd ) = @_;
    die "home directory is required\n" if !defined $home || $home eq '';
    die "command is required\n" if !defined $cmd || $cmd eq '';
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
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( "cd '$home' && $cmd", { env => \%env } );
    return ( decode( 'UTF-8', ( $stdout // '' ) . ( $stderr // '' ) ), $exit_code );
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
    return undef if !defined $path || !-f $path;
    open my $fh, '<', $path or return undef;
    local $/;
    my $content = scalar <$fh>;
    close $fh;
    return $content;
}

sub _proc_cmdline {
    my ($pid) = @_;
    return undef if $^O eq 'MSWin32';
    return undef if !defined $pid || $pid !~ /^\d+$/;
    my $raw = _slurp("/proc/$pid/cmdline");
    return undef if !defined $raw;
    $raw =~ s/\0/ /g;
    $raw =~ s/\s+$//;
    return $raw;
}

# _loop_snapshot($paths, $pid) - the observable registration state for one
# collector loop: pidfile, loop.json, liveness, title, supervisor state.
# No CLI call is made here, so sampling cannot disturb the window. The
# supervisor is reported only through this home's own supervisor state
# (pid + liveness + title), never through a node-wide process scan: the
# Jenkins nodes run other tests' supervisors too, and those are noise.
sub _loop_snapshot {
    my ( $paths, $pid ) = @_;
    my $pidfile = File::Spec->catfile( $paths->collectors_root, 'cli.collector.pid' );
    my $statefile = File::Spec->catfile( $paths->collector_dir('cli.collector'), 'loop.json' );
    my $pidfile_content = _slurp($pidfile);
    chomp $pidfile_content if defined $pidfile_content;
    my $state_raw  = _slurp($statefile);
    my $state      = defined $state_raw && $state_raw ne '' ? eval { json_decode($state_raw) } : undef;
    my $sup_state_raw = _slurp( File::Spec->catfile( $paths->state_root, 'collector-supervisor.json' ) );
    my $sup_state = defined $sup_state_raw && $sup_state_raw ne '' ? eval { json_decode($sup_state_raw) } : undef;
    my $sup_pid = ( ref($sup_state) eq 'HASH' ? $sup_state->{pid} : undef );
    return {
        pidfile       => defined $pidfile_content ? $pidfile_content : undef,
        state         => ( ref($state) eq 'HASH' ? $state : undef ),
        state_raw     => $state_raw,
        alive         => ( defined $pid && $pid =~ /^\d+$/ ) ? ( kill( 0, $pid ) ? 1 : 0 ) : undef,
        cmdline       => _proc_cmdline($pid),
        sup_pid       => $sup_pid,
        sup_alive     => ( defined $sup_pid && $sup_pid =~ /^\d+$/ ) ? ( kill( 0, $sup_pid ) ? 1 : 0 ) : undef,
        sup_cmdline   => _proc_cmdline($sup_pid),
        sup_watched   => ( ref($sup_state) eq 'HASH' ? $sup_state->{watched_names} : undef ),
        sup_status    => ( ref($sup_state) eq 'HASH' ? $sup_state->{status} : undef ),
    };
}

sub _snapshot_line {
    my ( $label, $snap, $pid ) = @_;
    my $state = $snap->{state};
    my $state_desc = !defined $state ? 'no-state'
      : sprintf 'state pid=%s status=%s', ( $state->{pid} // '?' ), ( $state->{status} // '?' );
    my $sup = defined $snap->{sup_pid}
      ? sprintf 'sup pid=%s alive=%s cmdline=[%s] status=%s watched=[%s]',
      $snap->{sup_pid}, ( $snap->{sup_alive} // '?' ), ( $snap->{sup_cmdline} // '?' ),
      ( $snap->{sup_status} // '?' ), join( ',', @{ $snap->{sup_watched} || [] } )
      : 'sup=none';
    my $title = defined $snap->{cmdline} ? sprintf 'cmdline=[%s]', $snap->{cmdline} : 'cmdline=?';
    diag(
        sprintf '%s: pidfile=%s %s alive=%s %s %s',
        $label, ( defined $snap->{pidfile} ? $snap->{pidfile} : 'absent' ),
        $state_desc, ( $snap->{alive} // '?' ), $title, $sup
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

# _sample_once($paths, $pid2, $pid1) - one tight in-process sample of the
# state the stop path will read: pidfile, loop.json (raw bytes + decode
# attempt), the new loop child's title, and the old loop's liveness/title.
# No CLI call, no Test::More call, so it can run hundreds of times inside
# the race window without disturbing it or tripping fail-fast.
sub _sample_once {
    my ( $paths, $pid2, $pid1 ) = @_;
    my $pidfile = File::Spec->catfile( $paths->collectors_root, 'cli.collector.pid' );
    my $statefile = File::Spec->catfile( $paths->collector_dir('cli.collector'), 'loop.json' );
    my $pf = _slurp($pidfile);
    chomp $pf if defined $pf;
    my $raw = _slurp($statefile);
    my $valid;
    my $st;
    if ( !defined $raw ) {
        $valid = 'missing';
    }
    elsif ( $raw eq '' ) {
        $valid = 'empty';
    }
    else {
        $st = eval { json_decode($raw) };
        $valid = ( defined $st && ref($st) eq 'HASH' ) ? 'ok' : 'invalid';
    }
    return {
        pidfile      => $pf,
        loop_valid   => $valid,
        loop_pid     => ( $valid eq 'ok' ? $st->{pid} : undef ),
        loop_status  => ( $valid eq 'ok' ? $st->{status} : undef ),
        loop_pname   => ( $valid eq 'ok' ? $st->{process_name} : undef ),
        loop_raw_len => ( defined $raw ? length($raw) : undef ),
        loop_raw     => $raw,
        cmdline2     => _proc_cmdline($pid2),
        alive1       => ( defined $pid1 && $pid1 =~ /^\d+$/ ) ? ( kill( 0, $pid1 ) ? 1 : 0 ) : undef,
        cmdline1     => _proc_cmdline($pid1),
    };
}

# _sample_sig($sample) - a compact signature of one sample: anything that
# changes it is a state transition worth logging. The new child's title is
# reduced to D (the expected `d2 collector:` title), S (still the spawn
# argv), W (Windows, no /proc title) or ? (unreadable).
sub _sample_sig {
    my ($s) = @_;
    my $title_flag = '?';
    if ( $^O eq 'MSWin32' ) {
        $title_flag = 'W';
    }
    elsif ( defined $s->{cmdline2} ) {
        $title_flag = ( $s->{cmdline2} eq $EXPECTED_TITLE ) ? 'D' : 'S';
    }
    return join '|',
      ( defined $s->{pidfile} ? $s->{pidfile} : '-' ),
      $s->{loop_valid},
      ( defined $s->{loop_pid} ? $s->{loop_pid} : '-' ),
      ( defined $s->{loop_status} ? $s->{loop_status} : '-' ),
      ( defined $s->{loop_pname} ? $s->{loop_pname} : '-' ),
      $title_flag,
      ( defined $s->{alive1} ? $s->{alive1} : '?' );
}

# _sample_window($paths, $pid2, $pid1, $budget_s, $label) - samples the
# state every ~5ms for up to $budget_s seconds (capped at 800 samples) and
# returns (samples taken, transition/anomaly event lines, anomaly counts).
# Only transitions and anomalies are logged, plus a heartbeat every 0.5s,
# so a quiet window stays quiet and a flapping one is fully visible.
# An anomaly is any sample in which the stop path could fail to confirm
# the new loop: loop.json missing/empty/invalid, loop.json naming a pid
# other than the re-started one, status 'stopped', a process_name other
# than the expected title, or a pidfile that is missing or names another
# pid. The first sample showing each anomaly class keeps its raw bytes.
sub _sample_window {
    my ( $paths, $pid2, $pid1, $budget_s, $label ) = @_;
    my $t0          = time();
    my @events;
    my %counts = (
        torn           => 0,
        pid_mismatch   => 0,
        stopped        => 0,
        pname_mismatch => 0,
        pidfile_mismatch => 0,
        pidfile_missing  => 0,
    );
    my %first_raw;
    my $prev_sig  = undef;
    my $n         = 0;
    my $last_beat = $t0;
    while ( ( time() - $t0 ) < $budget_s && $n < 800 ) {
        my $s  = _sample_once( $paths, $pid2, $pid1 );
        my $ms = int( ( time() - $t0 ) * 1000 );
        $n++;
        my @anom;
        if ( $s->{loop_valid} ne 'ok' ) {
            push @anom, 'torn:' . $s->{loop_valid};
            $counts{torn}++;
            if ( !exists $first_raw{torn} ) {
                $first_raw{torn} = defined $s->{loop_raw} ? substr( $s->{loop_raw}, 0, 200 ) : '<undef>';
            }
        }
        if ( defined $s->{loop_pid} && defined $pid2 && $s->{loop_pid} != $pid2 ) {
            push @anom, 'loop_pid=' . $s->{loop_pid};
            $counts{pid_mismatch}++;
            $first_raw{pid_mismatch} = substr( $s->{loop_raw} // '', 0, 200 ) if !exists $first_raw{pid_mismatch};
        }
        if ( defined $s->{loop_status} && $s->{loop_status} eq 'stopped' ) {
            push @anom, 'status=stopped';
            $counts{stopped}++;
            $first_raw{stopped} = substr( $s->{loop_raw} // '', 0, 200 ) if !exists $first_raw{stopped};
        }
        if ( defined $s->{loop_pname} && $s->{loop_pname} ne $EXPECTED_TITLE ) {
            push @anom, 'pname=[' . $s->{loop_pname} . ']';
            $counts{pname_mismatch}++;
            $first_raw{pname_mismatch} = substr( $s->{loop_raw} // '', 0, 200 ) if !exists $first_raw{pname_mismatch};
        }
        if ( defined $s->{pidfile} && defined $pid2 && $s->{pidfile} ne "$pid2" ) {
            push @anom, 'pidfile=[' . $s->{pidfile} . ']';
            $counts{pidfile_mismatch}++;
        }
        if ( !defined $s->{pidfile} ) {
            push @anom, 'pidfile-missing';
            $counts{pidfile_missing}++;
        }
        my $sig = _sample_sig($s);
        if ( !defined $prev_sig || $sig ne $prev_sig ) {
            push @events, sprintf '+%dms sig=[%s]%s', $ms, $sig, @anom ? ' ANOMALY: ' . join( ',', @anom ) : '';
            $prev_sig = $sig;
        }
        if ( time() - $last_beat >= 0.5 ) {
            diag( sprintf '%s: sampling heartbeat %.1fs samples=%d', $label, time() - $t0, $n );
            $last_beat = time();
        }
        sleep 0.005;
    }
    return ( $n, \@events, \%counts, \%first_raw );
}

my @homes;
my $phase1_repro   = 0;
my $phase1_broken  = 0;
my $phase1_adopted = 0;
my $phase1_old_alive = 0;
my $phase2_repro   = 0;
my $phase2_broken  = 0;
my $sample_torn_total         = 0;
my $sample_pid_mismatch_total = 0;
my $sample_stopped_total      = 0;
my $sample_pname_mismatch_total = 0;

# PHASE 1: repetition. The exact t/05 shape, 15 times, fresh home each
# time, no sampling between the re-start and the stop - the stop fires as
# soon as the re-start returns, exactly as t/05 does. Every outcome is a
# measurement-only ok(1) test, so one reproducing iteration cannot trip
# fail-fast and truncate the count; the real assertion is the summary test
# at the end of the file.
{
    diag('PHASE 1: repetition (exact t/05 shape x15, fresh home each time)');
    for my $i ( 1 .. 15 ) {
        diag("PHASE 1 ITER $i: start");
        my $home = _fresh_home();
        push @homes, $home;
        local $ENV{HOME} = $home;
        local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
        local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
        local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
        my $paths = Developer::Dashboard::PathRegistry->new( home => $home );

        my ( $start1_out, $start1_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' collector start cli.collector" );
        my ($pid1) = $start1_out =~ /(\d+)/;
        diag("PHASE 1 ITER $i: start returned pid " . ( defined $pid1 ? $pid1 : '?' ) . " exit=$start1_exit");

        my ( $sub_stop_out, $sub_stop_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' collector stop cli.collector" );
        my ( $status_out, $status_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' collector status cli.collector" );
        my $status = eval { json_decode($status_out) };
        my $s0 = _loop_snapshot( $paths, $pid1 );
        _snapshot_line( "PHASE 1 ITER $i: after subcommand stop", $s0, $pid1 );

        my ( $restart_out, $restart_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' collector start cli.collector" );
        my ($pid2) = $restart_out =~ /(\d+)/;
        my $adopted = ( defined $pid1 && defined $pid2 && $pid1 == $pid2 ) ? 1 : 0;
        $phase1_adopted++ if $adopted;
        $phase1_old_alive++ if $s0->{alive};
        diag("PHASE 1 ITER $i: re-start returned pid " . ( defined $pid2 ? $pid2 : '?' ) . " adopted=$adopted exit=$restart_exit");

        my $t_stop0 = time();
        my ( $stop_out, $stop_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' stop collector cli.collector" );
        my $stop_ms = int( ( time() - $t_stop0 ) * 1000 );
        my $row = _table_row($stop_out);
        my $s1 = _loop_snapshot( $paths, $pid2 );
        my $clean = ( $start1_exit == 0 && $sub_stop_exit == 0 && $status_exit == 0 && $restart_exit == 0 && $stop_exit == 0 );
        if ( $row eq 'not running' && $clean ) {
            $phase1_repro++;
            diag("PHASE 1 ITER $i: REPRODUCED the round-36 row");
            diag("PHASE 1 ITER $i: stop table was:\n$stop_out");
            _snapshot_line( "PHASE 1 ITER $i: snapshot after reproducing stop", $s1, $pid2 );
        }
        elsif ( !$clean ) {
            $phase1_broken++;
            diag("PHASE 1 ITER $i: BROKEN iteration (a CLI call failed, exits start=$start1_exit substop=$sub_stop_exit status=$status_exit restart=$restart_exit stop=$stop_exit)");
        }
        ok( 1,
            sprintf 'PHASE 1 ITER %d: pid1=%s pid2=%s adopted=%d old_alive_after_substop=%s status_running=[%s] stop_ms=%d row=[%s] post pid2 alive=%s pidfile=%s',
            $i, ( defined $pid1 ? $pid1 : '?' ), ( defined $pid2 ? $pid2 : '?' ), $adopted,
            ( defined $s0->{alive} ? $s0->{alive} : '?' ),
            ( ref($status) eq 'HASH' ? ( $status->{running} ? '1' : '0' ) : '?' ),
            $stop_ms, $row, ( defined $s1->{alive} ? $s1->{alive} : '?' ),
            ( defined $s1->{pidfile} ? $s1->{pidfile} : 'absent' ) );
    }
    diag("PHASE 1 done: repro=$phase1_repro broken=$phase1_broken adopted=$phase1_adopted old_alive=$phase1_old_alive");
}

# PHASE 2: trajectory sampling. Same shape, 5 times, but after the re-start
# the state the stop path will read is sampled every ~5ms for up to 4s
# before the stop fires: pidfile, loop.json validity and contents, the new
# child's title, and the old loop's liveness. If the stop ever sees "not
# running", the sample log shows exactly what it saw; if it always sees
# "stopped", the log shows how long any inconsistent window lasts.
{
    diag('PHASE 2: trajectory sampling (re-start, sample ~5ms for up to 4s, then stop) x5');
    for my $i ( 1 .. 5 ) {
        diag("PHASE 2 ITER $i: start");
        my $home = _fresh_home();
        push @homes, $home;
        local $ENV{HOME} = $home;
        local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
        local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
        local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
        my $paths = Developer::Dashboard::PathRegistry->new( home => $home );

        my ( $start1_out, $start1_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' collector start cli.collector" );
        my ($pid1) = $start1_out =~ /(\d+)/;
        my ( $sub_stop_out, $sub_stop_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' collector stop cli.collector" );
        my ( $status_out, $status_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' collector status cli.collector" );
        my $s0 = _loop_snapshot( $paths, $pid1 );
        _snapshot_line( "PHASE 2 ITER $i: after subcommand stop", $s0, $pid1 );

        my ( $restart_out, $restart_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' collector start cli.collector" );
        my ($pid2) = $restart_out =~ /(\d+)/;
        my $adopted = ( defined $pid1 && defined $pid2 && $pid1 == $pid2 ) ? 1 : 0;
        diag("PHASE 2 ITER $i: re-start returned pid " . ( defined $pid2 ? $pid2 : '?' ) . " adopted=$adopted exit=$restart_exit");

        my ( $n_samples, $events, $counts, $first_raw ) = _sample_window( $paths, $pid2, $pid1, 4.0, "PHASE 2 ITER $i" );
        $sample_torn_total          += $counts->{torn};
        $sample_pid_mismatch_total  += $counts->{pid_mismatch};
        $sample_stopped_total       += $counts->{stopped};
        $sample_pname_mismatch_total += $counts->{pname_mismatch};
        diag("PHASE 2 ITER $i: sampled $n_samples times: torn=$counts->{torn} pid_mismatch=$counts->{pid_mismatch} stopped=$counts->{stopped} pname_mismatch=$counts->{pname_mismatch} pidfile_mismatch=$counts->{pidfile_mismatch} pidfile_missing=$counts->{pidfile_missing}");
        my $shown = 0;
        for my $event (@$events) {
            last if $shown >= 20;
            diag("PHASE 2 ITER $i: event $event");
            $shown++;
        }
        diag("PHASE 2 ITER $i: ... " . ( scalar(@$events) - $shown ) . " further events not shown") if @$events > $shown;
        for my $kind ( sort keys %$first_raw ) {
            diag("PHASE 2 ITER $i: first $kind raw bytes: [" . $first_raw->{$kind} . "]");
        }

        my $t_stop0 = time();
        my ( $stop_out, $stop_exit ) = _cmd( $home, "$perl -I'$lib' '$dashboard' stop collector cli.collector" );
        my $stop_ms = int( ( time() - $t_stop0 ) * 1000 );
        my $row = _table_row($stop_out);
        my $s1 = _loop_snapshot( $paths, $pid2 );
        my $clean = ( $start1_exit == 0 && $sub_stop_exit == 0 && $status_exit == 0 && $restart_exit == 0 && $stop_exit == 0 );
        if ( $row eq 'not running' && $clean ) {
            $phase2_repro++;
            diag("PHASE 2 ITER $i: REPRODUCED the round-36 row after $n_samples samples");
            diag("PHASE 2 ITER $i: stop table was:\n$stop_out");
            _snapshot_line( "PHASE 2 ITER $i: snapshot after reproducing stop", $s1, $pid2 );
        }
        elsif ( !$clean ) {
            $phase2_broken++;
            diag("PHASE 2 ITER $i: BROKEN iteration (a CLI call failed, exits start=$start1_exit substop=$sub_stop_exit status=$status_exit restart=$restart_exit stop=$stop_exit)");
        }
        ok( 1,
            sprintf 'PHASE 2 ITER %d: pid1=%s pid2=%s adopted=%d samples=%d torn=%d pid_mismatch=%d stopped=%d pname_mismatch=%d stop_ms=%d row=[%s] post pid2 alive=%s pidfile=%s',
            $i, ( defined $pid1 ? $pid1 : '?' ), ( defined $pid2 ? $pid2 : '?' ), $adopted,
            $n_samples, $counts->{torn}, $counts->{pid_mismatch}, $counts->{stopped}, $counts->{pname_mismatch},
            $stop_ms, $row, ( defined $s1->{alive} ? $s1->{alive} : '?' ),
            ( defined $s1->{pidfile} ? $s1->{pidfile} : 'absent' ) );
    }
    diag("PHASE 2 done: repro=$phase2_repro broken=$phase2_broken torn_samples=$sample_torn_total pid_mismatch_samples=$sample_pid_mismatch_total stopped_samples=$sample_stopped_total pname_mismatch_samples=$sample_pname_mismatch_total");
}

# Summary. Everything above is measurement-only, so a reproducing iteration
# cannot trip fail-fast before the count is complete. These are the only
# real assertions in the file, and they run last.
{
    my $total_repro  = $phase1_repro + $phase2_repro;
    my $total_broken = $phase1_broken + $phase2_broken;
    ok( 1, "SUMMARY: phase 1 (exact shape x15): repro=$phase1_repro broken=$phase1_broken adopted=$phase1_adopted old_loop_alive_after_subcommand_stop=$phase1_old_alive" );
    ok( 1, "SUMMARY: phase 2 (sampled x5): repro=$phase2_repro broken=$phase2_broken torn_samples=$sample_torn_total pid_mismatch_samples=$sample_pid_mismatch_total stopped_samples=$sample_stopped_total pname_mismatch_samples=$sample_pname_mismatch_total" );
    ok( 1, "SUMMARY: broken iterations (a CLI call failed, not a race): $total_broken" );
    ok( $total_repro == 0,
        $total_repro
        ? "SUMMARY: $total_repro of 20 iterations reproduced the round-36 'not running' row"
        : 'SUMMARY: no iteration reproduced the round-36 failure' );
}

# Best-effort cleanup with no Test::More assertions, so the plan is not
# corrupted: stop everything (collectors, web, supervisor) in every home
# this micro created that still has a loop record, leaving no live loop
# behind for the orphan detector. Homes whose stop already succeeded have
# no pidfile left and need no stop call.
END {
    for my $home (@homes) {
        next if !defined $home || $home eq '' || !-d $home;
        local $ENV{HOME} = $home;
        my $paths = eval { Developer::Dashboard::PathRegistry->new( home => $home ) };
        next if !$paths;
        my $pidfile = File::Spec->catfile( $paths->collectors_root, 'cli.collector.pid' );
        my $supfile = File::Spec->catfile( $paths->state_root, 'collector-supervisor.json' );
        next if !-f $pidfile && !-f $supfile;
        eval { _quiet_run( $home, "$perl -I'$lib' '$dashboard' stop" ); };
    }
}

done_testing();

__END__

=head1 NAME

t/996-micro-collector-restart-repeat.t - repeat probe for the round-36 t/05 test 323 race

=head1 DESCRIPTION

Repeats the exact t/05 collector start/stop sequence that failed once on
ARM64 in round 36 (build #353) fifteen times, and samples the state the
stop path reads - pidfile, loop.json validity and contents, the new loop
child's title, and the old loop's liveness - every ~5ms for up to 4s after
five more re-starts. Probe #355 (t/998) ruled out slow registration and
died-on-start with a single clean run per leg; this probe tests whether the
failure is a rarer race that only repetition or fine sampling can catch.

=head1 PURPOSE

Decide between the three open hypotheses for the round-36 failure: (1) a
torn or stale loop.json read - the child rewrites loop.json every tick, and
if the stop reads it mid-replace, or naming the old pid, both the title
check and the state check fail, running_loops deletes the pidfile and the
state, and the stop reports "not running"; (2) re-start adoption - the old
loop is slow to die after the subcommand stop, so the re-start adopts stale
state instead of spawning fresh; (3) full-suite load - the clean probe ran
in isolated fresh homes, while round 36 ran t/05 inside the full suite.
Repetition measures the reproduction rate; sampling shows exactly what the
stop would have seen at every instant after the re-start.

=head1 WHY IT EXISTS

Round 36 failed on exactly one test, ARM64 t/05 test 323: the stop table
showed "collector cli.collector not running / no running collectors" right
after a re-start that had returned a pid. The same test passed on the other
legs and on ARM64 in solo #348, so the failure is intermittent. Probe #355
showed the re-started loop registers within milliseconds and the stop works
at every delay - but one clean run per leg cannot rule out a rarer race.
Guessing the fix without catching the race would be a second guess on top
of the first failure.

=head1 WHEN TO USE

Run as a Jenkins solo (TEST_FILE=t/996-micro-collector-restart-repeat.t)
when adjudicating the round-36 t/05 test 323 failure. Remove in a cleanup
commit once the mechanism is proven and the real fix is decided.

=head1 HOW TO USE

Trigger through Jenkins only, never by hand over SSH: the job runs it on
all four platforms at once. Read the diag lines: the per-iteration rows in
Phase 1 give the reproduction rate; the Phase 2 sample events give the
state trajectory after each re-start (any torn read, pid mismatch,
'stopped' status, or pidfile disappearance is logged with its millisecond
offset). The summary tests are the only real assertions and run last, so a
reproducing iteration cannot trip fail-fast before the count is complete.

=head1 WHAT USES IT

Nothing in the product uses this file. The testing-v1 loop uses it once, as
the second micro-probe for the round-36 failure, and then it is removed.

=head1 EXAMPLES

Jenkins solo: TEST_FILE=t/996-micro-collector-restart-repeat.t, BRANCH=windows/loop6-combined, ROUNDS=1.

=cut
