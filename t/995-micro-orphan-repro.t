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
use Developer::Dashboard::Housekeeper;
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Developer::Dashboard::PathRegistry;
use Encode qw(decode encode);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX qw(setsid);
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo = getcwd();

my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

my $IS_WINDOWS = $^O eq 'MSWin32';

# _run, _run_in_home and _find_free_port are copied verbatim from
# t/05-cli-smoke.t so the micro drives the CLI exactly the way the
# failing test does. _run_quiet is the same runner without the
# assertion, for diagnostics that must never trip the FAIL-SAFE
# watchdog themselves. The $quiet flag is for the forked stand-in
# child: it must never print TAP (is/ok/diag) to prove's pipe, so in
# quiet mode a failed command dies instead of asserting.
sub _run {
    my ( $cmd, $quiet ) = @_;
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => {} } );
    if ($quiet) {
        die "command failed ($exit_code): $cmd\n" if $exit_code != 0;
        return decode( 'UTF-8', $stdout . $stderr );
    }
    is( $exit_code, 0, "command succeeded: $cmd" );
    return decode( 'UTF-8', $stdout . $stderr );
}

sub _run_quiet {
    my ($cmd) = @_;
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => {} } );
    return ( decode( 'UTF-8', $stdout . $stderr ), $exit_code );
}

sub _run_in_home {
    my ( $home, $cmd, $quiet ) = @_;
    die "home directory is required\n" if !defined $home || $home eq '';
    return _run("cd '$home' && $cmd", $quiet);
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

# _read_json_file($path)
# Reads one JSON file, returning undef when it is missing or unparsable.
sub _read_json_file {
    my ($path) = @_;
    return if !defined $path || !-f $path;
    open my $fh, '<:raw', $path or return;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { json_decode($raw) };
    return if $@ || !defined $data;
    return $data;
}

# _slurp_file($path)
# Reads one text file, returning undef when it is missing.
sub _slurp_file {
    my ($path) = @_;
    return if !defined $path || !-f $path;
    open my $fh, '<', $path or return;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $raw;
}

# _wait_for_file($path, $timeout)
# Polls until a file exists, returning true when it appears.
sub _wait_for_file {
    my ( $path, $timeout ) = @_;
    my $deadline = time + $timeout;
    while ( time < $deadline ) {
        return 1 if -f $path;
        sleep 0.5;
    }
    return -f $path ? 1 : 0;
}

# _proc_ids($pid)
# Returns { ppid, pgrp, session } for one pid, or undef when it cannot be
# read. The process-group and session are the whole question in this
# investigation: a group kill can only reach a process in the target
# group, so the topology (who shares prove's group, who left it) is
# measured, not assumed. Perl's POSIX module has setsid but no getpgid
# or getsid, so read them from the kernel: /proc/<pid>/stat fields 4, 5
# and 6 on Linux (ppid, pgrp, session after the comm), `ps -o
# ppid=,pgid=,sid=` on Linux without /proc, `ps -o ppid=,pgid=,sess=`
# on macOS. The session value is an OPAQUE TOKEN, not a pid: on Linux
# it is the numeric session id (a session leader's sid equals its pid),
# but on macOS `sess` is a session POINTER (Darwin ps man page: "sess
# session pointer"), printed in hex - v4 read it as a number and got
# the "0" from "0x..." on every process (solo #229). Compare tokens
# for equality (same session vs detached), never against a pid, on
# macOS. A session leader's pgid always equals its pid, on both.
sub _proc_ids {
    my ($pid) = @_;
    return if !defined $pid || $pid !~ /^\A\d+\z/;
    if ( -r "/proc/$pid/stat" ) {
        my $stat = _slurp_file("/proc/$pid/stat");
        return if !defined $stat;
        my $after_paren = $stat;
        $after_paren =~ s/^.*\)\s*//;
        my @fields = split /\s+/, $after_paren;
        return if @fields < 4;
        return if grep { !defined $_ || $_ !~ /^\A-?\d+\z/ } @fields[ 1, 2, 3 ];
        return { ppid => $fields[1] + 0, pgrp => $fields[2] + 0, session => $fields[3] };
    }
    # No /proc (macOS): ask ps. The session keyword differs by
    # platform - `sid` on Linux, `sess` on macOS - so try both. `ppid`
    # and `pgid` are valid keywords on both. The third field is captured
    # as a bare token, never as a number: macOS `sess` is a pointer.
    for my $keyword (qw(sid sess)) {
        my ( $out, $exit ) = _run_quiet("ps -o ppid=,pgid=,$keyword= -p $pid");
        next if $exit != 0 || !defined $out;
        my ( $ppid, $pgrp, $session ) = $out =~ /(\d+)\s+(\d+)\s+(\S+)/ or next;
        return { ppid => $ppid + 0, pgrp => $pgrp + 0, session => $session };
    }
    return;
}

# _proc_start($pid)
# Returns the process start time as a string (`ps -o lstart=`, valid on
# both Linux and macOS), or undef when it cannot be read. Diag-only:
# solo #228 showed loop pids in the state root OLDER than the
# supervisor that supposedly started them, which is impossible for
# children of one run - the start times say whether those loops predate
# this run (leftovers in a shared root, or interleaved lines from the
# other Linux leg) or belong to it.
sub _proc_start {
    my ($pid) = @_;
    return if !defined $pid || $pid !~ /^\A\d+\z/;
    my ( $out, $exit ) = _run_quiet("ps -o lstart= -p $pid");
    return if $exit != 0 || !defined $out;
    $out =~ s/^\s+|\s+$//g;
    return $out ne '' ? $out : undef;
}

# _diag_topology($label, $pid)
# Prints one process's parent, group and session as a diag line, or notes
# that it could not be read. The topology is the evidence; it is diagged
# rather than asserted, because which processes share the group is the
# question being answered, not a premise.
sub _diag_topology {
    my ( $label, $pid ) = @_;
    my $ids = _proc_ids($pid);
    if ($ids) {
        diag("micro: topology $label pid $pid ppid $ids->{ppid} pgid $ids->{pgrp} session $ids->{session}");
    }
    else {
        diag("micro: topology $label pid $pid unreadable");
    }
    return $ids;
}

# _pid_is_alive($pid)
# True when the pid names a live process (kill 0 probe).
sub _pid_is_alive {
    my ($pid) = @_;
    return 0 if !defined $pid || $pid !~ /^\A\d+\z/ || $pid < 1;
    return kill( 0, $pid ) ? 1 : 0;
}

# _kill_pid($pid)
# TERM then KILL by exact pid only, waiting for the process to go away.
# Never touches a process group: the point of this micro is that the
# supervisor is OUTSIDE every group the test can kill, so only an exact
# pid kill can clean up what the micro itself started.
sub _kill_pid {
    my ($pid) = @_;
    return 1 if !_pid_is_alive($pid);
    kill 'TERM', $pid;
    for ( 1 .. 50 ) {
        return 1 if !_pid_is_alive($pid);
        sleep 0.1;
    }
    kill 'KILL', $pid;
    for ( 1 .. 50 ) {
        return 1 if !_pid_is_alive($pid);
        sleep 0.1;
    }
    return _pid_is_alive($pid) ? 0 : 1;
}

# _cpu_jiffies($pid)
# Reads utime+stime for one pid from /proc on Unix. Returns undef where
# /proc is unavailable (Windows, macOS).
sub _cpu_jiffies {
    my ($pid) = @_;
    my $stat = _slurp_file("/proc/$pid/stat");
    return if !defined $stat;
    my @fields = split /\s+/, $stat;
    return if @fields < 15;
    return ( $fields[13] || 0 ) + ( $fields[14] || 0 );
}

# _serve_home($home, $collector_name, $quiet)
# Inits one temp home, writes a one-collector config, and starts serve.
# Returns the decoded serve JSON (with the web pid). In quiet mode (the
# forked stand-in child) a missing pid dies instead of asserting.
sub _serve_home {
    my ( $home, $collector_name, $quiet ) = @_;
    _run_in_home( $home, "$perl -I'$lib' '$dashboard' init", $quiet );
    my $config_file = File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' );
    open my $fh, '>:raw', $config_file or die "Unable to write $config_file: $!";
    my $config_json = json_encode(
        {
            collectors => [
                {
                    name     => $collector_name,
                    command  => q{perl -MTime::HiRes=time -e 'printf qq{%.6f\n}, time'},
                    cwd      => 'home',
                    interval => 1,
                },
            ],
        }
    );
    $config_json = encode( 'UTF-8', $config_json ) if utf8::is_utf8($config_json);
    print {$fh} $config_json;
    close $fh;
    my $port = _find_free_port();
    my $serve_json = json_decode( _run_in_home( $home, "$perl -I'$lib' '$dashboard' serve --host 127.0.0.1 --port $port", $quiet ) );
    if ($quiet) {
        die "d2 serve returned no managed web pid\n" if !$serve_json->{pid};
    }
    else {
        ok( $serve_json->{pid}, "d2 serve returns a managed web pid in $home" );
    }
    return $serve_json;
}

# _state_root_for_home($home)
# Returns the hashed temp-state root for one runtime home, through the
# product's own PathRegistry, so the micro reads exactly the directory
# the supervisor writes its pidfile and state into.
sub _state_root_for_home {
    my ($home) = @_;
    my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
    return $paths->state_root;
}

# _collect_managed_pids($state_root)
# Reads every pid the runtime tracks in one state root: the supervisor
# pidfile plus every collector loop pidfile. Returns a hash reference
# of label => pid.
sub _collect_managed_pids {
    my ($state_root) = @_;
    my %pids;
    my $sup_pidfile = File::Spec->catfile( $state_root, 'collector-supervisor.pid' );
    if ( my $raw = _slurp_file($sup_pidfile) ) {
        chomp $raw;
        $pids{supervisor} = $raw + 0 if $raw =~ /^\A\d+\z/;
    }
    my $collectors_root = File::Spec->catdir( $state_root, 'collectors' );
    if ( -d $collectors_root ) {
        opendir my $dh, $collectors_root or die "Unable to read $collectors_root: $!";
        while ( my $entry = readdir $dh ) {
            my ($loop_name) = $entry =~ /^(.*)\.pid\z/;
            next if !defined $loop_name;
            my $raw = _slurp_file( File::Spec->catfile( $collectors_root, $entry ) );
            next if !defined $raw;
            chomp $raw;
            # NOTE: capture the name above first. `$1` after the
            # `if $raw =~ ...` modifier would be the modifier match's
            # (empty) captures, not the entry's name.
            $pids{"loop:$loop_name"} = $raw + 0 if $raw =~ /^\A\d+\z/;
        }
        closedir $dh;
    }
    return \%pids;
}

# _cleanup_pids($pids)
# Kills every pid in the hash by exact pid and reports the survivors.
# Returns the list of pids still alive afterwards (empty on success).
sub _cleanup_pids {
    my ($pids) = @_;
    my @survivors;
    for my $label ( sort keys %{$pids} ) {
        my $pid = $pids->{$label};
        next if !defined $pid;
        my $gone = _kill_pid($pid);
        diag("micro: cleanup killed $label pid $pid") if $gone;
        push @survivors, "$label:$pid" if !$gone;
    }
    return @survivors;
}

if ($IS_WINDOWS) {

    # Windows: no fork/setpgid/getsid, and the stop path is the restart
    # applier's live investigation, so this leg only proves the start side
    # of the lifecycle (supervisor starts, is alive, has targets). The
    # Unix leg below carries the fail-fast kill reproduction.
    my $home = tempdir( CLEANUP => 0 );
    my $serve_json = _serve_home( $home, 'micro-tick' );
    my $state_root = _state_root_for_home($home);
    my $sup_pidfile = File::Spec->catfile( $state_root, 'collector-supervisor.pid' );
    ok( _wait_for_file( $sup_pidfile, 60 ), 'micro: supervisor pidfile appears after serve on Windows' );
    my $pids = _collect_managed_pids($state_root);
    ok( defined $pids->{supervisor}, 'micro: supervisor pid recorded on Windows' );
    ok( _pid_is_alive( $pids->{supervisor} ), 'micro: supervisor alive after serve on Windows' );
    my $state = _read_json_file( File::Spec->catfile( $state_root, 'collector-supervisor.json' ) );
    ok( $state && ref( $state->{watched_names} ) eq 'ARRAY' && @{ $state->{watched_names} },
        'micro: supervisor state carries watched targets on Windows' );
    # Michael's standing rule (19 Nov ~08:45): do NOT clean up orphans -
    # they are the evidence. Kill only the web (it holds prove's pipes);
    # leave the supervisor and its loops alive and record them.
    _kill_pid( $serve_json->{pid} ) if $serve_json->{pid};
    my @evidence;
    for my $label ( sort keys %{$pids} ) {
        push @evidence, "$label:$pids->{$label}" if _pid_is_alive( $pids->{$label} );
    }
    ok( scalar @evidence, 'micro: orphan supervisor and loops LEFT ALIVE as evidence on Windows (not cleaned up)' );
    diag( 'micro: EVIDENCE left running on Windows - state root ' . $state_root . ' pids ' . join( ' ', @evidence ) );
    remove_tree($home);
    done_testing();
    exit 0;
}

# Unix leg: reproduce the fail-fast kill and watch the supervisor survive.
my $home = tempdir( CLEANUP => 0 );
my $results_file = File::Spec->catfile( File::Spec->tmpdir(), "micro-orphan-$$.json" );

my $parent_pid = fork();
die "Unable to fork the stand-in parent: $!" if !defined $parent_pid;
if ( $parent_pid == 0 ) {

    # Child: the stand-in for prove. It calls setsid exactly the way
    # failsafe.pl does before execing prove, so it is a session leader
    # and a process-group leader (pgid == sid == its own pid), and the
    # parent micro can kill its group exactly the way failsafe.pl kills
    # prove (TERM to the negative pgid) without touching prove itself.
    # v2 used setpgid here instead: a group without a session, which is
    # NOT prove's shape, and it made the supervisor look like it had
    # failed to detach when the measurement was really of the wrong
    # replica. v3 measures the topology instead of assuming it.
    setsid() or die "Unable to set the stand-in session: $!";
    local $ENV{HOME} = $home;
    my $serve_json = _serve_home( $home, 'micro-tick', 1 );
    my $state_root = _state_root_for_home($home);
    my $pids       = _collect_managed_pids($state_root);
    open my $rfh, '>', $results_file or die "Unable to write $results_file: $!";
    print {$rfh} json_encode(
        {
            web_pid    => $serve_json->{pid} + 0,
            state_root => $state_root,
            pids       => $pids,
            pgid       => getpgrp(0) + 0,
        }
    );
    close $rfh or die "Unable to close $results_file: $!";
    sleep 600;
    POSIX::_exit(0);
}

my $orphan_survived = 0;
my $err;
eval {
    my $standin = _read_json_file($results_file);
    for ( 1 .. 120 ) {
        last if $standin && $standin->{pids} && $standin->{pids}{supervisor};
        sleep 0.5;
        $standin = _read_json_file($results_file);
    }
    ok( $standin && $standin->{pids} && $standin->{pids}{supervisor}, 'micro: stand-in parent started a supervisor' );
    die "stand-in parent produced no supervisor pid\n" if !$standin || !$standin->{pids} || !$standin->{pids}{supervisor};

    my $sup_pid    = $standin->{pids}{supervisor};
    my $state_root = $standin->{state_root};
    my $pgid       = $standin->{pgid};
    diag("micro: supervisor pid $sup_pid, state root $state_root, stand-in pgid $pgid");

    # Topology first, measured not assumed. The stand-in must be a
    # session leader like prove (pgid == sid == its own pid); that
    # validates the replica. The supervisor, the web and the loops are
    # diagged with parent, group and session: whether the supervisor
    # shares the stand-in's group (so a group kill reaches it) or left
    # it (so the kill cannot) is the question being answered, not a
    # premise. v2 asserted the supervisor had setsid'd into its own
    # session and failed on amd64 (sid 3082304, not its pid) - but the
    # code plainly calls setsid in _run_collector_supervisor_child, so
    # either the detach is broken somewhere or the measurement was of
    # the wrong replica. v3 records the whole topology and lets the
    # kill result speak.
    my $standin_ids = _diag_topology( 'stand-in', $parent_pid );
    # Session leadership on both platforms: a process-group leader has
    # pgid == pid, and the stand-in called setsid() - which dies on
    # failure - before serving, so it is a session leader if it is
    # alive with pgid == pid. The session TOKEN is only checked present,
    # never compared to the pid: on Linux it is the numeric sid (which
    # does equal the leader's pid), but on macOS it is a session
    # pointer, an opaque hex token. v4 compared it to the pid and
    # failed macOS test 2 on every process reading "0" (the "0" of
    # "0x...", solo #229).
    ok( $standin_ids && $standin_ids->{pgrp} == $parent_pid && defined $standin_ids->{session} && $standin_ids->{session} ne '',
        'micro: stand-in is a session leader like prove (pgid == pid, session token present)' );
    _diag_topology( 'web', $standin->{web_pid} ) if $standin->{web_pid};
    my $sup_ids = _diag_topology( 'supervisor', $sup_pid );
    my $all_pids = _collect_managed_pids($state_root);
    for my $label ( sort keys %{$all_pids} ) {
        next if $label eq 'supervisor';
        _diag_topology( $label, $all_pids->{$label} );
    }

    # The heartbeat must advance BEFORE the kill: that proves the pid in
    # the pidfile is the live supervisor, not a stale record, so the
    # kill result below is about a living process.
    my $state1 = _read_json_file( File::Spec->catfile( $state_root, 'collector-supervisor.json' ) );
    sleep 6;
    my $state2 = _read_json_file( File::Spec->catfile( $state_root, 'collector-supervisor.json' ) );
    ok(
        $state1 && $state2 && $state1->{heartbeat_at} && $state2->{heartbeat_at} && $state1->{heartbeat_at} ne $state2->{heartbeat_at},
        'micro: supervisor heartbeat advances before the kill (it is the live supervisor)'
    );
    diag( 'micro: heartbeat ' . ( $state1->{heartbeat_at} || '?' ) . ' -> ' . ( $state2->{heartbeat_at} || '?' ) );

    # Steady state, after the 6s heartbeat sleep: the supervisor has had
    # time to finish starting. Solo #228 showed the immediate reading
    # can catch the child before its setsid (the parent writes the
    # pidfile at spawn, the child setsid's only after exec + module
    # load), so the before/after pair documents the race instead of
    # hiding it. The loop start times say whether the loops in this
    # state root belong to this run or predate it.
    _diag_topology( 'supervisor-steady', $sup_pid );
    my $steady_sup_ids = _proc_ids($sup_pid);
    if ( $standin_ids && $steady_sup_ids ) {
        diag( 'micro: supervisor session token ' . $steady_sup_ids->{session} . ' vs stand-in ' . $standin_ids->{session}
              . ( $steady_sup_ids->{session} ne $standin_ids->{session} ? ' - DETACHED into its own session' : ' - STILL in the stand-in session' ) );
    }
    my $steady_pids = _collect_managed_pids($state_root);
    for my $label ( sort keys %{$steady_pids} ) {
        next if $label eq 'supervisor';
        my $started = _proc_start( $steady_pids->{$label} );
        # The pidfile mtime next to the process start time is the
        # adoption proof: a fresh pidfile naming an old process means
        # this run's supervisor ADOPTED an already-running loop from
        # the process table (CollectorRunner
        # _adopt_existing_loop_if_running) instead of spawning a fresh
        # one. An old pidfile would mean a shared state root instead.
        my ($loop_name) = $label =~ /\Aloop:(.*)\z/;
        my $pidfile = defined $loop_name ? File::Spec->catfile( $state_root, 'collectors', "$loop_name.pid" ) : undef;
        my $mtime = $pidfile && -f $pidfile ? scalar localtime( ( stat($pidfile) )[9] ) : 'missing';
        diag( 'micro: loop ' . $label . ' pid ' . $steady_pids->{$label} . ' started ' . ( $started || 'unknown' ) . ', pidfile mtime ' . $mtime );
    }

    # Fail-fast, exactly as failsafe.pl does it: TERM to the negative
    # pgid of the stand-in parent, then KILL if it lingers.
    kill 'TERM', -$pgid;
    my $deadline = time + 30;
    while ( time < $deadline ) {
        my $reaped = waitpid( $parent_pid, 1 );
        last if $reaped == $parent_pid;
        sleep 0.1;
    }
    if ( kill( 0, $parent_pid ) ) {
        kill 'KILL', -$pgid;
        waitpid( $parent_pid, 0 );
    }
    ok( !kill( 0, $parent_pid ), 'micro: stand-in parent is dead after the fail-fast-style group kill' );

    # THE question: does the supervisor survive its owner's death? If
    # it does, the group kill cannot reach it and the orphan mechanism
    # is the group/session topology. If it does not, the kill works and
    # the orphans must come from elsewhere (the stop/teardown path),
    # which is a different micro.
    my $sup_survived = _pid_is_alive($sup_pid);
    $orphan_survived = $sup_survived ? 1 : 0;
    ok( $sup_survived, 'micro: supervisor survives the fail-fast kill of its owner' );
    _diag_topology( 'supervisor-after-kill', $sup_pid );

    # The sections below need a live orphan: home deletion, the fresh
    # runtime, the housekeeper dry run, the CPU measurement, and the
    # fresh runtime's cleanup are 10 tests. If the supervisor died with
    # its owner there is no orphan to examine, so they are skipped and
    # the kill result above is the finding.
    if ( !$sup_survived ) {
        SKIP: {
            skip 'supervisor died with its owner; orphan sections need a live orphan', 10;
        }
    }
    else {
    # The test home is deleted (File::Temp cleanup), exactly as after a
    # fail-fast-killed run. The orphan's state root is a different tree
    # (tmpdir/<user>/developer-dashboard/state/<md5-of-home>), so it
    # survives, targets intact, supervisor still alive.
    remove_tree($home);
    ok( !-d $home, 'micro: runtime home deleted' );
    ok( -f File::Spec->catfile( $state_root, 'collector-supervisor.pid' ), 'micro: supervisor pidfile survives home deletion' );
    ok( -f File::Spec->catfile( $state_root, 'collector-supervisor.json' ), 'micro: supervisor state survives home deletion' );
    my $state3 = _read_json_file( File::Spec->catfile( $state_root, 'collector-supervisor.json' ) );
    ok( $state3 && ref( $state3->{watched_names} ) eq 'ARRAY' && @{ $state3->{watched_names} },
        'micro: orphan supervisor keeps its watched targets after home deletion' );
    ok( _pid_is_alive($sup_pid), 'micro: supervisor still alive after home deletion' );

    # A fresh runtime in a new home cannot see or stop the orphan: its
    # state root is keyed by md5 of its own home, a different directory.
    # Start serve there and prove the old supervisor is untouched.
    my $home2 = tempdir( CLEANUP => 0 );
    my $serve2_json = _serve_home( $home2, 'micro-tick' );
    ok( _pid_is_alive($sup_pid), 'micro: fresh runtime does not adopt or stop the orphan supervisor' );
    my $state_root2 = _state_root_for_home($home2);
    ok( $state_root2 ne $state_root, 'micro: fresh runtime has a different hashed state root' );

    # The housekeeper cannot clean the orphan root either: the orphan's
    # loops are alive, their pidfiles name live managed processes, so
    # _state_root_has_live_collectors protects the root. Dry run only:
    # it reports without touching anything.
    my $paths2 = Developer::Dashboard::PathRegistry->new( home => $home2 );
    my $keeper = Developer::Dashboard::Housekeeper->new( paths => $paths2 );
    my $dry = eval { $keeper->run( dry_run => 1, min_age_seconds => 0 ) };
    ok( !$@ && $dry && ref( $dry->{removed} ) eq 'ARRAY', 'micro: housekeeper dry run completes' );
    diag("micro: housekeeper dry run error: $@") if $@;
    my @would_remove_root = grep { ref($_) eq 'HASH' && ( $_->{path} || '' ) eq $state_root } @{ $dry->{removed} || [] };
    is( scalar @would_remove_root, 0, 'micro: housekeeper would NOT remove the orphan state root (live loops protect it)' );

    # Measure, do not assert: how much CPU do the orphaned processes
    # burn while their owner is gone? Two /proc samples 10s apart.
    my $pids_now = _collect_managed_pids($state_root);
    my %before = map { $_ => ( _cpu_jiffies( $pids_now->{$_} ) // 0 ) } keys %{$pids_now};
    sleep 10;
    for my $label ( sort keys %{$pids_now} ) {
        my $after = _cpu_jiffies( $pids_now->{$label} );
        next if !defined $after;
        diag( sprintf 'micro: cpu %s pid %s: +%s jiffies over 10s', $label, $pids_now->{$label}, $after - $before{$label} );
    }

    # Clean up the fresh runtime first through its own CLI, then by exact
    # pid for anything the CLI leaves behind.
    _run_quiet_in_home( $home2, "$perl -I'$lib' '$dashboard' stop" );
    my $pids2 = _collect_managed_pids($state_root2);
    $pids2->{web2} = $serve2_json->{pid} if $serve2_json->{pid};
    my @left2 = _cleanup_pids($pids2);
    is( scalar @left2, 0, 'micro: fresh runtime processes cleaned up' );
    remove_tree($home2);
    }

    1;
} or $err = $@;

# Cleanup runs even when the body above failed. Michael's standing rule
# (19 Nov ~08:45): do NOT clean up orphans - cleanup destroys the
# evidence. The supervisor and its loops are left ALIVE exactly where
# they are, their pids and state root diagged as evidence; they are
# only killed once the mechanism is proven and the fix is in. The one
# exception is the web: it holds prove's pipes, so leaving it would hang
# the harness after the plan (the t/17 backend shape). It is killed by
# exact pid, and the kill is diagged, not hidden.
my $final_pids = {};
my $final_root;
if ( -f $results_file ) {
    my $standin = _read_json_file($results_file);
    if ( $standin && $standin->{state_root} ) {
        $final_root = $standin->{state_root};
        $final_pids = _collect_managed_pids($final_root);
        if ( $standin->{web_pid} ) {
            my @web_left = _cleanup_pids( { web => $standin->{web_pid} } );
            diag( 'micro: web killed for harness hygiene, survivors: ' . join( ', ', @web_left ) ) if @web_left;
        }
    }
}
my @evidence;
for my $label ( sort keys %{$final_pids} ) {
    my $pid = $final_pids->{$label};
    if ( _pid_is_alive($pid) ) {
        push @evidence, "$label:$pid";
    }
}
if ($orphan_survived) {
    ok( scalar @evidence, 'micro: orphan supervisor and loops LEFT ALIVE as evidence (not cleaned up)' );
    diag( 'micro: EVIDENCE left running - state root ' . ( $final_root || '?' ) . ' pids ' . join( ' ', @evidence ) );
}
else {
    ok( 1, 'micro: no orphans left - the group kill took the supervisor down with its owner' );
    diag('micro: EVIDENCE: none left running; the kill worked, so the orphan path is elsewhere (stop/teardown)');
}
unlink $results_file;
remove_tree($home) if -d $home;
ok( !$err, 'micro: body completed without dying' ) or diag("micro: body died: $err");

done_testing();

__END__

=head1 NAME

t/995-micro-orphan-repro.t - reproduce the orphaned collector supervisor that starved the Pi in round 25

=head1 PURPOSE

Prove, by measurement, why a collector supervisor survives a fail-fast
kill and keeps running forever. The code reading says it detaches into
its own session, its state lives in a per-runtime hashed root that
outlives the test home, its only self-exit is an empty target set that
nothing ever writes, and the housekeeper refuses to remove its state
root while its loops are alive. Solo #226 (v2) CONTRADICTED the first
of those on amd64: the supervisor's session was prove's session, not
its own, and the group kill took it down - but v2's stand-in used
setpgid (a group without a session), which is NOT prove's shape, so
the measurement may have been of the wrong replica. v3 replicates
failsafe.pl exactly (the stand-in calls setsid, like prove), records
the whole process topology (parent, group, session for every process
in the chain), and lets the kill result speak. If the supervisor
survives in the true replica, the topology is the mechanism. If it
dies, the kill works and the orphans must come from elsewhere (the
stop/teardown path), which is a different micro. Solo #228 (v3)
ANSWERED it on one Linux leg: the supervisor survived the group kill
(ok 5, 10/10 tests before fail-fast cascade), its session changing
from the stand-in's (3143844) to its own pid (3143982) - and the
startup race is now understood: the parent writes the pidfile at
spawn, the child setsid's only after exec + module load, so a kill
landing in that window takes the supervisor down (which is what v2's
solo #226 measured). v4 fixes the macOS topology reader (ps needs
`sess`, not `sid`) and adds a steady-state re-read plus loop start
times; solo #228's macOS leg failed test 2 on the unreadable topology
and tripped fail-fast before the other legs finished. Solo #229 (v4)
confirmed the survival a SECOND time on a Linux leg (10/10 before
cascade, supervisor re-sessioned itself before the kill) and resolved
the loop puzzle: the loops in the fresh state root started 16 and 38
minutes before the run - they are orphans from earlier runs, and the
supervisor ADOPTS them (CollectorRunner
_adopt_existing_loop_if_running: if the pidfile is missing it asks the
process table by name and rewrites the record) instead of spawning
fresh ones, so orphaned loops are never replaced and never die across
runs. v4's macOS leg failed test 2 again, differently: `sess` is a
session POINTER (Darwin ps man page), printed in hex, and the numeric
regex read the "0" of "0x..." on every process. v5 treats the session
as an opaque token (equality only, never compared to a pid) and adds
the pidfile mtime to the loop diag, which is the adoption proof
(fresh pidfile naming an old process).

=head1 WHY IT EXISTS

Round 25 failed on ARM64 t/05 test 360 because 19 orphaned
"d2 collector supervisor" processes plus a spinning housekeeper loop
had accumulated on the Pi from earlier fail-fast-killed runs, some ten
hours old. Hand cleanup fixed that one run, but the orphans came back
once before (builds #69/#70) and will keep coming back until the root
cause is understood. This micro pins the mechanism down before any fix
is attempted: if the supervisor does NOT survive the group kill, the
code reading is wrong and the investigation must start over.

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/995-micro-orphan-repro.t) on the
loop branch. Never run it by hand against a live home: it starts real
web services and collector loops in temp homes, kills a process group,
and deletes a temp home while its supervisor is still running.

=head1 HOW TO USE

Commit it to windows/loop6-combined, push, then trigger a solo with
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined
t/995-micro-orphan-repro.t 1. Read the diag lines in the console:
supervisor pid and session, heartbeat before/after, whether the state
root survives home deletion, whether a fresh runtime sees the orphan,
whether the housekeeper dry run would remove the root, and the per-pid
CPU jiffies over 10s.

EVIDENCE RULE (Michael, 19 Nov ~08:45): do NOT clean up orphans -
cleanup destroys the evidence. The micro leaves the orphan supervisor
and its loops running on every leg and diags their pids and state root
as EVIDENCE; only the web is killed, because it holds prove's pipes
and leaving it would hang the harness after the plan. Kill the
left-behind orphans by exact pid only once the mechanism is proven and
the fix is in. Remove the file in a cleanup commit when the
investigation ends.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a diagnostic micro for the
orphan-root-cause investigation, in the testing-v1 loop.

=head1 EXAMPLES

If the mechanism is as the code reading says, the Unix leg passes with
diag lines like "supervisor sid <pid>" (own session), "heartbeat
<ts> -> <ts+>" (alive after the kill), "housekeeper would NOT remove
the orphan state root" (live loops protect it), and per-pid CPU
jiffies showing what the orphans burn. If the supervisor dies with its
owner instead, the "survives the fail-fast kill" assertion fails and
the orphan theory is wrong.

=cut
