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
use POSIX qw(setpgid);
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

# _pid_is_alive($pid)
# True when a pid exists right now. kill 0 is the same liveness probe
# the product uses in _pid_is_running.
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
            next if $entry !~ /^(.*)\.pid\z/;
            my $raw = _slurp_file( File::Spec->catfile( $collectors_root, $entry ) );
            next if !defined $raw;
            chomp $raw;
            $pids{"loop:$1"} = $raw + 0 if $raw =~ /^\A\d+\z/;
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
    # of the lifecycle (supervisor starts, is alive, has targets) and that
    # an exact-pid kill removes it. The Unix leg below carries the
    # fail-fast kill reproduction.
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
    diag( 'micro: Windows pids before cleanup: ' . join( ', ', map { "$_=$pids->{$_}" } sort keys %{$pids} ) );
    my @survivors = _cleanup_pids($pids);
    _kill_pid( $serve_json->{pid} ) if $serve_json->{pid};
    is( scalar @survivors, 0, 'micro: exact-pid cleanup removes every managed process on Windows' );
    diag( 'micro: Windows survivors: ' . join( ', ', @survivors ) ) if @survivors;
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

    # Child: the stand-in for prove. Its own process group, so the
    # parent micro can kill the group exactly the way failsafe.pl kills
    # prove (TERM to the negative pgid) without touching prove itself.
    setpgid( 0, 0 ) or die "Unable to set the stand-in process group: $!";
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

    # The supervisor detaches into its own session (setsid in
    # _run_collector_supervisor_child): its session id is itself, never
    # the stand-in's group. That is the first half of the orphan
    # mechanism: a process-group kill can never reach it.
    my $sup_sid = POSIX::getsid($sup_pid);
    ok( defined $sup_sid && $sup_sid == $sup_pid, 'micro: supervisor runs in its own session (setsid)' );
    diag("micro: supervisor sid $sup_sid, stand-in pgid $pgid") if defined $sup_sid;

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

    # The supervisor survives its owner's death, and its heartbeat keeps
    # advancing: it is alive and working, not a leftover zombie.
    ok( _pid_is_alive($sup_pid), 'micro: supervisor survives the fail-fast kill of its owner' );
    my $state1 = _read_json_file( File::Spec->catfile( $state_root, 'collector-supervisor.json' ) );
    sleep 6;
    my $state2 = _read_json_file( File::Spec->catfile( $state_root, 'collector-supervisor.json' ) );
    ok(
        $state1 && $state2 && $state1->{heartbeat_at} && $state2->{heartbeat_at} && $state1->{heartbeat_at} ne $state2->{heartbeat_at},
        'micro: orphan supervisor heartbeat advances after its owner dies'
    );
    diag( 'micro: heartbeat ' . ( $state1->{heartbeat_at} || '?' ) . ' -> ' . ( $state2->{heartbeat_at} || '?' ) );

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

    1;
} or $err = $@;

# Cleanup runs even when the body above failed: kill everything this
# micro started, by exact pid only, and verify nothing survives. The
# orphan supervisor is the micro's own creation, so this kill is allowed.
my $final_pids = {};
if ( -f $results_file ) {
    my $standin = _read_json_file($results_file);
    if ( $standin && $standin->{state_root} ) {
        $final_pids = _collect_managed_pids( $standin->{state_root} );
        $final_pids->{web} = $standin->{web_pid} if $standin->{web_pid};
    }
}
my @survivors = _cleanup_pids($final_pids);
is( scalar @survivors, 0, 'micro: exact-pid cleanup removes every managed process the micro started' );
diag( 'micro: survivors: ' . join( ', ', @survivors ) ) if @survivors;
unlink $results_file;
remove_tree($home) if -d $home;
ok( !$err, 'micro: body completed without dying' ) or diag("micro: body died: $err");

done_testing();

__END__

=head1 NAME

t/995-micro-orphan-repro.t - reproduce the orphaned collector supervisor that starved the Pi in round 25

=head1 PURPOSE

Prove, by measurement, why a collector supervisor survives a fail-fast
kill and keeps running forever: it detaches into its own session, its
state lives in a per-runtime hashed root that outlives the test home,
its only self-exit is an empty target set that nothing ever writes, and
the housekeeper refuses to remove its state root while its loops are
alive. The micro kills a stand-in parent exactly the way failsafe.pl
kills prove (TERM to the process group) and then checks the supervisor
is alive, heartbeating, invisible to a fresh runtime, and protected
from housekeeper cleanup.

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
CPU jiffies over 10s. Remove the file in a cleanup commit when the
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
