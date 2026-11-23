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
use Developer::Dashboard::Collector;
use Developer::Dashboard::CollectorRunner;
use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::GoRoutine ();
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);
use Test::More;
use Time::Local qw(timegm timelocal);

my $repo = getcwd();

my $IS_WINDOWS = $^O eq 'MSWin32';

# A fake collector child sleeps this long and then exits on its own. The
# test never kills anything it finds, so a bounded sleep is how a control
# child goes away without a kill: the controls run in well under a second,
# and 30 seconds is margin enough for the slowest node.
my $FAKE_CHILD_SLEEP = 30;

# A state root with no runtime.json is only treated as a dead run when it
# is at least this old. Metadata lands at state-root creation, so a young
# metadata-less root may be a concurrent run still creating itself.
my $METADATA_LESS_ROOT_MIN_AGE = 3600;

# A supervisor polls every 5 seconds, so a heartbeat older than this is
# a stuck supervisor, not a slow one. Reported as evidence only: the
# orphan verdict never depends on the heartbeat.
my $SUPERVISOR_STUCK_HEARTBEAT_AGE = 600;

# _read_json_file($file)
# Returns the decoded JSON hash reference, or undef when the file is
# missing or unreadable.
sub _read_json_file {
    my ($file) = @_;
    return if !-f $file;
    open my $fh, '<', $file or return;
    local $/;
    my $raw = <$fh>;
    close $fh or return;
    my $data = eval { json_decode($raw) };
    return if !$data || ref($data) ne 'HASH';
    return $data;
}

# _write_json_file($file, $data)
# Writes one JSON hash reference to a file, creating parent dirs.
sub _write_json_file {
    my ( $file, $data ) = @_;
    my ( $volume, $dirs, $name ) = File::Spec->splitpath($file);
    my $dir = File::Spec->catpath( $volume, $dirs, '' );
    make_path($dir) if $dir ne '' && !-d $dir;
    open my $fh, '>', $file or die "Unable to write $file: $!";
    print {$fh} json_encode($data) or die "Unable to write $file: $!";
    close $fh or die "Unable to close $file: $!";
    return $file;
}

# _read_pid_file($file)
# Returns the pid integer from a pidfile, or undef when it is missing or
# does not hold a plain pid.
sub _read_pid_file {
    my ($file) = @_;
    return if !-f $file;
    open my $fh, '<', $file or return;
    my $pid = <$fh>;
    close $fh or return;
    return if !defined $pid;
    chomp $pid;
    return if $pid !~ /\A\d+\z/;
    return $pid + 0;
}

# _iso8601_now($utc)
# Formats the current time the way the product writes heartbeats: UTC with
# a trailing Z for the supervisor, local time without one for loops.
sub _iso8601_now {
    my ($utc) = @_;
    my @t = $utc ? gmtime(time) : localtime(time);
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02d%s', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $utc ? 'Z' : '';
}

# _heartbeat_age($file)
# Returns the age in seconds of the heartbeat_at stamp in one state JSON
# file, or undef when the file or the stamp is missing or unparseable.
# A trailing Z means UTC, no Z means local time; parsing them the wrong
# way round would be off by the timezone offset, so the two are kept apart.
sub _heartbeat_age {
    my ($file) = @_;
    my $data = _read_json_file($file);
    # NOTE: return undef, not a bare return: this sub is called in list
    # context as a hash value, and a bare return there is an empty list,
    # which makes the hash odd and warns.
    return undef if !$data || !$data->{heartbeat_at};
    my ( $y, $mo, $d, $h, $mi, $s, $z ) = $data->{heartbeat_at} =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z)?\z/ or return undef;
    my $when = $z ? timegm( $s, $mi, $h, $d, $mo - 1, $y - 1900 ) : timelocal( $s, $mi, $h, $d, $mo - 1, $y - 1900 );
    return time - $when;
}

# _windows_loop_shape_match($runner, $pid, $name)
# Windows-only identity path for a loop from another run. The product's
# _is_managed_loop can only confirm loops that belong to the checking
# process's own runtime on Windows (its state and pidfile fallbacks both
# read the checker's own paths), so a foreign loop is unconfirmable
# through it. But a real Windows loop child's CIM command line always
# carries its helper argv, collector-loop-foreground --name <name>, since
# $0 never rewrites it there - the product itself uses exactly this shape
# as the "does not disagree" condition in that fallback. An unrelated
# process cannot carry both tokens, so matching them confirms the loop.
sub _windows_loop_shape_match {
    my ( $runner, $pid, $name ) = @_;
    my $title = $runner->_read_process_title($pid);
    return 0 if !defined $title || $title eq '';
    return 1 if $title =~ /\bcollector-loop-foreground\b/ && $title =~ /--name\s+\Q$name\E(?:\s|\z)/;
    return 0;
}

# _orphans_in_root($root, $runner, $manager)
# Returns the orphan records for one state root whose run is already
# known dead: every confirmed-live collector process it still tracks.
# A pidfile alone proves nothing (DD-598: pids are reused), so each pid
# goes through the product's own identity checks - the supervisor check
# for the watchdog, the managed-loop check for loops, plus the Windows
# loop-helper shape for foreign loops _is_managed_loop cannot see.
sub _orphans_in_root {
    my ( $root, $runner, $manager ) = @_;
    my @found;

    my $sup_pid = _read_pid_file( File::Spec->catfile( $root, 'collector-supervisor.pid' ) );
    if ( defined $sup_pid && $manager->_is_collector_supervisor($sup_pid) ) {
        push @found,
          {
            root          => $root,
            kind          => 'supervisor',
            name          => '',
            pid           => $sup_pid,
            heartbeat_age => _heartbeat_age( File::Spec->catfile( $root, 'collector-supervisor.json' ) ),
          };
    }

    my $collectors_root = File::Spec->catdir( $root, 'collectors' );
    if ( -d $collectors_root ) {
        opendir my $dh, $collectors_root or die "Unable to read $collectors_root: $!";
        while ( my $entry = readdir $dh ) {
            my ($name) = $entry =~ /\A(.*)\.pid\z/ or next;
            next if $name eq '';
            my $pid = _read_pid_file( File::Spec->catfile( $collectors_root, $entry ) );
            next if !defined $pid;
            my $confirmed = $runner->_is_managed_loop( $pid, $name );
            if ( !$confirmed && $IS_WINDOWS ) {
                $confirmed = _windows_loop_shape_match( $runner, $pid, $name );
            }
            next if !$confirmed;
            push @found,
              {
                root          => $root,
                kind          => 'loop',
                name          => $name,
                pid           => $pid,
                heartbeat_age => _heartbeat_age( File::Spec->catfile( $collectors_root, $name, 'loop.json' ) ),
              };
        }
        closedir $dh;
    }
    return @found;
}

# _scan_state_base($base, $runner, $manager)
# Returns the orphan records for one state base: every collector process
# (supervisor, worker, loop) confirmed live in a state root whose run is
# dead. A root is a dead run when its runtime.json names a home directory
# that no longer exists - the same rule the Housekeeper's own
# _state_root_is_stale uses. A root whose home still exists is skipped
# outright, so a live run, a concurrent build, or a test that keeps its
# home can never be flagged. A root with no metadata at all is only
# treated as dead when it is old enough that no concurrent run can still
# be creating it. This routine only reads: it never kills, stops, or
# removes anything it finds.
sub _scan_state_base {
    my ( $base, $runner, $manager ) = @_;
    my @orphans;
    return @orphans if !-d $base;
    opendir my $dh, $base or die "Unable to read state base $base: $!";
    my @roots = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    for my $entry (@roots) {
        my $root = File::Spec->catdir( $base, $entry );
        next if !-d $root;
        my $meta = _read_json_file( File::Spec->catfile( $root, 'runtime.json' ) );
        my $home = $meta ? ( $meta->{runtime_root} || '' ) : '';
        if ( $home ne '' && -d $home ) {
            next;
        }
        if ( $home eq '' ) {
            my @st = stat($root);
            next if !@st || ( time - $st[9] ) < $METADATA_LESS_ROOT_MIN_AGE;
        }
        push @orphans, _orphans_in_root( $root, $runner, $manager );
    }
    return @orphans;
}

# _spawn_fake_child($command, $env, $label, $log_dir)
# Starts one fake collector-shaped child with the product's own spawn and
# returns its pid. The child sleeps a bounded time and exits on its own;
# the test never kills it. GoRoutine::spawn is the cross-platform spawn
# the product itself uses for supervisors, so the child is a real process
# with a real pid, environ and command line on every platform. The
# child's stdio logs go under $log_dir, a tempdir the test owns, so no
# log litter survives the run.
sub _spawn_fake_child {
    my ( $command, $env, $label, $log_dir ) = @_;
    my $out = File::Spec->catfile( $log_dir, "t994-fake-child-$$-$label-out.log" );
    my $err = "$out.stderr";
    my $pid = Developer::Dashboard::GoRoutine::spawn(
        $command,
        {
            stdin  => File::Spec->devnull(),
            stdout => $out,
            stderr => $err,
            env    => $env || {},
        },
    );
    die "Unable to spawn fake collector child for $label\n" if !$pid;
    return $pid;
}

# _wait_for_death($pid)
# Waits until a pid is no longer alive, or dies after 30 seconds. Used
# only to obtain a pid that is known dead, for the negative control. A
# child that has exited but not been reaped is a zombie, and kill 0 still
# answers true for a zombie (proven by probe: the child showed state Z
# two seconds after exit, and only went away once waitpid reaped it), so
# the wait reaps with WNOHANG each poll; when the pid is not our child
# at all (spawn double-forked on some platform) it falls back to kill 0.
sub _wait_for_death {
    my ($pid) = @_;
    for ( 1 .. 300 ) {
        my $reaped = waitpid( $pid, WNOHANG );
        return 1 if $reaped == $pid;
        return 1 if $reaped == -1 && !kill( 0, $pid );
        select( undef, undef, undef, 0.1 );
    }
    die "pid $pid did not die within 30 seconds\n";
}

my $home = tempdir( CLEANUP => 1 );
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
my $files = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $store = Developer::Dashboard::Collector->new( paths => $paths );
my $runner = Developer::Dashboard::CollectorRunner->new( collectors => $store, files => $files, paths => $paths );
my $manager = Developer::Dashboard::RuntimeManager->new(
    app_builder => sub { die "app_builder must not run in the detector\n" },
    config      => $config,
    files       => $files,
    paths       => $paths,
    runner      => $runner,
);

# Fake collector-shaped children, one per identity path the product
# recognises. They sleep a bounded time and exit on their own; the test
# never kills them. The supervisor child carries the helper argv the
# product's command-shape check matches; the loop child carries the env
# marker (Linux), the helper argv (Windows), and a fabricated loop.json
# in the checker's own paths (macOS state path); the plain child carries
# none of these, so it must never be confirmed as a collector.
my $script_dir = tempdir( CLEANUP => 1 );
my $core_script = File::Spec->catfile( $script_dir, '_dashboard-core' );
my $loop_script = File::Spec->catfile( $script_dir, 'collector-loop-foreground' );
for my $script ( $core_script, $loop_script ) {
    open my $fh, '>', $script or die "Unable to write $script: $!";
    print {$fh} "sleep $FAKE_CHILD_SLEEP;\n" or die "Unable to write $script: $!";
    close $fh or die "Unable to close $script: $!";
}
my $sup_pid = _spawn_fake_child( [ $^X, $core_script, 'collector-supervisor-foreground' ], {}, 'supervisor', $script_dir );
my $loop_pid = _spawn_fake_child( [ $^X, $loop_script, 'collector-loop-foreground', '--name', 'micro-tick' ],
    { DEVELOPER_DASHBOARD_LOOP_NAME => 'micro-tick' }, 'loop', $script_dir );
my $plain_pid = _spawn_fake_child( [ $^X, '-e', 'sleep 30' ], {}, 'plain', $script_dir );
ok( kill( 0, $sup_pid ) && kill( 0, $loop_pid ) && kill( 0, $plain_pid ), 'detector: fake collector children are alive for the controls' );

# The loop control also needs the fabricated state the macOS path reads
# and the pidfile the Windows fallback reads, both in the checker's own
# paths: loop.json with pid, name and process title, and the pidfile.
my $loop_dir = $paths->collector_dir('micro-tick');
_write_json_file(
    File::Spec->catfile( $loop_dir, 'loop.json' ),
    {
        pid          => $loop_pid,
        name         => 'micro-tick',
        process_name => 'd2 collector: micro-tick',
        status       => 'running',
        heartbeat_at => _iso8601_now(0),
    }
);
my $runner_pidfile = $runner->_pidfile('micro-tick');
make_path( $paths->collectors_root );
open my $pfh, '>', $runner_pidfile or die "Unable to write $runner_pidfile: $!";
print {$pfh} $loop_pid or die "Unable to write $runner_pidfile: $!";
close $pfh or die "Unable to close $runner_pidfile: $!";

# A pid known dead, for the negative control: spawn a child that exits at
# once and wait until it is gone.
my $dying_pid = _spawn_fake_child( [ $^X, '-e', 'exit 0' ], {}, 'dying', $script_dir );
_wait_for_death($dying_pid);

my $dead_home = File::Spec->catdir( File::Spec->tmpdir(), "t994-dead-home-$$" );
my $live_home = tempdir( CLEANUP => 1 );
my $fake_base = tempdir( CLEANUP => 1 );

# Control 1: live supervisor, dead home. Must be flagged.
{
    my $root = File::Spec->catdir( $fake_base, 'root-supervisor-live-dead-home' );
    _write_json_file( File::Spec->catfile( $root, 'runtime.json' ),
        { runtime_root => $dead_home, app_name => 'developer-dashboard' } );
    open my $fh, '>', File::Spec->catfile( $root, 'collector-supervisor.pid' ) or die $!;
    print {$fh} $sup_pid or die $!;
    close $fh or die $!;
    _write_json_file( File::Spec->catfile( $root, 'collector-supervisor.json' ), { heartbeat_at => _iso8601_now(1) } );
    my @found = _scan_state_base( $fake_base, $runner, $manager );
    is( scalar @found, 1, 'detector: flags a live supervisor whose run is dead' );
    is( $found[0]{kind}, 'supervisor', 'detector: the flagged process is the supervisor' ) if @found;
    is( $found[0]{pid}, $sup_pid, 'detector: the flagged supervisor pid is the live one' ) if @found;
    remove_tree($root);
}

# Control 2: live loop, dead home. Must be flagged.
{
    my $root = File::Spec->catdir( $fake_base, 'root-loop-live-dead-home' );
    _write_json_file( File::Spec->catfile( $root, 'runtime.json' ),
        { runtime_root => $dead_home, app_name => 'developer-dashboard' } );
    make_path( File::Spec->catdir( $root, 'collectors' ) );
    open my $fh, '>', File::Spec->catfile( $root, 'collectors', 'micro-tick.pid' ) or die $!;
    print {$fh} $loop_pid or die $!;
    close $fh or die $!;
    my @found = _scan_state_base( $fake_base, $runner, $manager );
    is( scalar @found, 1, 'detector: flags a live loop whose run is dead' );
    is( $found[0]{kind}, 'loop', 'detector: the flagged process is a loop' ) if @found;
    is( $found[0]{name}, 'micro-tick', 'detector: the flagged loop name matches' ) if @found;
    remove_tree($root);
}

# Control 3: dead pid, dead home. Must NOT be flagged: a pidfile alone
# proves nothing, and the pid is gone.
{
    my $root = File::Spec->catdir( $fake_base, 'root-dead-pid-dead-home' );
    _write_json_file( File::Spec->catfile( $root, 'runtime.json' ),
        { runtime_root => $dead_home, app_name => 'developer-dashboard' } );
    open my $fh, '>', File::Spec->catfile( $root, 'collector-supervisor.pid' ) or die $!;
    print {$fh} $dying_pid or die $!;
    close $fh or die $!;
    make_path( File::Spec->catdir( $root, 'collectors' ) );
    open my $lfh, '>', File::Spec->catfile( $root, 'collectors', 'micro-tick.pid' ) or die $!;
    print {$lfh} $dying_pid or die $!;
    close $lfh or die $!;
    my @found = _scan_state_base( $fake_base, $runner, $manager );
    is( scalar @found, 0, 'detector: ignores a dead pid in a dead run' );
    remove_tree($root);
}

# Control 4: live supervisor, live home. Must NOT be flagged: the run
# still owns its home, so this may be a live run, not a leftover.
{
    my $root = File::Spec->catdir( $fake_base, 'root-supervisor-live-live-home' );
    _write_json_file( File::Spec->catfile( $root, 'runtime.json' ),
        { runtime_root => $live_home, app_name => 'developer-dashboard' } );
    open my $fh, '>', File::Spec->catfile( $root, 'collector-supervisor.pid' ) or die $!;
    print {$fh} $sup_pid or die $!;
    close $fh or die $!;
    my @found = _scan_state_base( $fake_base, $runner, $manager );
    is( scalar @found, 0, 'detector: ignores a live supervisor whose home still exists' );
    remove_tree($root);
}

# Control 5: live foreign process, dead home. Must NOT be flagged: the
# pid is alive but carries no collector identity, so it is a reused pid,
# not a collector (DD-598).
{
    my $root = File::Spec->catdir( $fake_base, 'root-foreign-live-dead-home' );
    _write_json_file( File::Spec->catfile( $root, 'runtime.json' ),
        { runtime_root => $dead_home, app_name => 'developer-dashboard' } );
    open my $fh, '>', File::Spec->catfile( $root, 'collector-supervisor.pid' ) or die $!;
    print {$fh} $plain_pid or die $!;
    close $fh or die $!;
    make_path( File::Spec->catdir( $root, 'collectors' ) );
    open my $lfh, '>', File::Spec->catfile( $root, 'collectors', 'plain.pid' ) or die $!;
    print {$lfh} $plain_pid or die $!;
    close $lfh or die $!;
    my @found = _scan_state_base( $fake_base, $runner, $manager );
    is( scalar @found, 0, 'detector: ignores a live foreign process with no collector identity' );
    remove_tree($root);
}

# Fixture teardown, not orphan cleanup: remove the two files the loop
# control wrote into the checker's own paths (the pidfile the Windows
# fallback reads, the loop.json the macOS state path reads). They are
# the test's own fixtures, and leaving them would point the NEXT run's
# scan at a pid that is still alive for the rest of its bounded sleep -
# a self-inflicted false positive one run later, proven by the local
# re-run that flagged the previous run's loop child. The fake children
# themselves are never touched: they exit on their own when the sleep
# ends, and with no pidfile naming them no scan can find them.
unlink $runner_pidfile;
unlink File::Spec->catfile( $loop_dir, 'loop.json' );

# The real scan: the shared state base. Any orphan found here fails the
# test, which trips the existing fail-fast/fail-safe and terminates the
# job through the existing mechanism - no separate monitor is needed.
# Nothing found is killed, stopped, or removed: it stays in place as
# evidence for the investigation.
my $real_base = $paths->state_base_root;
my @orphans = _scan_state_base( $real_base, $runner, $manager );
for my $orphan (@orphans) {
    my $age = defined $orphan->{heartbeat_age} ? $orphan->{heartbeat_age} . 's' : 'unknown';
    my $stuck = $orphan->{kind} eq 'supervisor' && defined $orphan->{heartbeat_age} && $orphan->{heartbeat_age} > $SUPERVISOR_STUCK_HEARTBEAT_AGE
      ? ' STUCK (heartbeat stale)'
      : '';
    diag( sprintf 'detector: ORPHAN %s %s pid %s root %s heartbeat age %s%s',
        $orphan->{kind}, $orphan->{name} || '-', $orphan->{pid}, $orphan->{root}, $age, $stuck );
}
is( scalar @orphans, 0, 'detector: no orphaned collector processes left behind after the run' );

done_testing();

__END__

=head1 NAME

t/994-orphan-collector-detector.t - fail the suite when orphaned collector processes are left behind

=head1 PURPOSE

Detect collector processes (supervisor, worker, loop) left behind after
a run and fail the test when one is found, so the existing fail-fast and
fail-safe terminate the job through the existing mechanism. The test
only detects: it never kills, stops, or removes anything it finds, so
the orphans stay in place as evidence for the investigation. Detection
reuses the product's own identity checks (the supervisor check and the
managed-loop check), so a bare pidfile never condemns a process - the
pid must still be the collector that recorded it. A state root is a
dead run when its runtime.json names a home directory that no longer
exists, the same rule the Housekeeper's own stale-root check uses, and
a root whose home still exists is skipped outright, so a live run, a
concurrent build, or a test that keeps its home can never be flagged.

=head1 WHY IT EXISTS

Round 25 failed on ARM64 t/05 test 360 because 19 orphaned "d2
collector supervisor" processes plus a spinning housekeeper loop had
accumulated on the Pi from earlier fail-fast-killed runs, some ten
hours old. Nothing in the suite noticed them: each run just got slower
until a timing test broke, and the orphans were only found by hand
afterwards. A detector in the suite itself turns that silent pile-up
into a loud failure at the point it happens, with the orphan's pid,
state root and heartbeat age in the output for the investigation.

=head1 WHEN TO USE

It runs as part of the normal suite (prove runs files in lexical order,
so t/994 runs near the end, after the serve tests). Run it as a Jenkins
solo (TEST_FILE=t/994-orphan-collector-detector.t) to check one leg, or
read its diag lines in a full run to see exactly which orphans it
found. Never run it by hand against a live home: it reads the shared
state base, which is where every run on the machine keeps its roots.

=head1 HOW TO USE

No setup: the test builds its own throwaway home, spawns three fake
collector-shaped children (supervisor, loop, plain) that sleep a bounded
time and exit on their own, and runs five controls against fake state
roots before the real scan. The controls prove the detection logic in
both directions - live supervisor and live loop in a dead run are
flagged, a dead pid, a live home, and a live foreign process are not.
When the real scan finds orphans, the test fails and diags each one
(kind, name, pid, state root, heartbeat age, and STUCK when a
supervisor heartbeat is stale). Do not delete the orphans it reports:
they are the evidence, and are only cleaned up once the mechanism is
proven and the fix is in.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a permanent suite test for
the orphan problem, in the testing-v1 loop. The fail-fast and fail-safe
in the Jenkins job terminate the run when it fails; no separate monitor
watches for orphans.

=head1 EXAMPLES

On a clean machine the test passes with eleven assertions: the fake
children are alive, the five controls agree, and the real scan finds
no orphans. On a machine with leftovers it fails on the last assertion
with diag lines like "ORPHAN supervisor - pid 3010488 root
/tmp/tester/developer-dashboard/state/728eaf... heartbeat age 642s
STUCK (heartbeat stale)", naming exactly what to investigate.

=cut
