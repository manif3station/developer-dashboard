#!/usr/bin/env perl

use strict;
use warnings;

use Cwd qw(getcwd);
use Config;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use POSIX qw(strftime);
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $Bin, '..', 'lib' );

use Developer::Dashboard::Collector;
use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::GoRoutine ();
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::Platform qw(is_windows);
use Developer::Dashboard::ProcessSupervision qw(_taskkill_command);
use Developer::Dashboard::RuntimeManager;

# R146 correction: $OS_NAME, not $^O, is the Windows simulation hook.
# Platform.pm line 34 copies $^O into our $OS_NAME at load time, and
# is_windows() reads $OS_NAME (line 52). Localising $^O afterwards
# does not change $OS_NAME, so the M3 $^O pattern does not transfer
# here. Every simulated-Windows block below localises
# $Developer::Dashboard::Platform::OS_NAME to 'MSWin32', the hook the
# Platform POD documents at lines 38-44.

BEGIN {
    # DD-993: both 'redefine' AND 'prototype' must be silenced here,
    # not just 'redefine'. RuntimeManager.pm imports its "sleep" from
    # Time::HiRes, so this permanent (non-local) glob assignment
    # replaces a sub that already carries whatever prototype that
    # Perl's bundled Time::HiRes gives sleep(). A non-local assignment
    # onto a slot that already holds a prototyped sub triggers Perl's
    # separate 'prototype' warning category regardless of whether the
    # NEW sub has a prototype of its own. This project's CI runs under
    # `use warnings FATAL => 'all'`, so that mismatch was a genuine
    # build failure. See t/203 for a deterministic, version-independent
    # reproduction of the mechanism. The stop paths poll in bounded
    # loops, so making their sleep instant keeps this file fast
    # without changing what any of them decides.
    no warnings qw(redefine prototype);
    *Developer::Dashboard::RuntimeManager::sleep = sub { return 0 };
}

{
    package Local::Runner;
    sub new {
        my ( $class, %args ) = @_;
        return bless {
            loops   => [],
            stopped => [],
            %args,
        }, $class;
    }
    sub running_loops { return @{ $_[0]{loops} } }
    sub loop_state    { my ( $s, $n ) = @_; return undef }
    sub start_loop {
        my ( $s, $job ) = @_;
        push @{ $s->{started} }, $job->{name};
        return 4242;
    }
    sub stop_loop {
        my ( $s, $name ) = @_;
        push @{ $s->{stopped} }, $name;
        $s->{loops} = [ grep { $_->{name} ne $name } @{ $s->{loops} } ];
        return 1;
    }

    package Local::Server;
    sub new { my ( $c, %a ) = @_; return bless { %a }, $c }
    sub run { return 'foreground-ran' }
}

my $original_cwd = getcwd();
my $test_cwd     = tempdir( CLEANUP => 1 );
chdir $test_cwd or die "Unable to chdir to $test_cwd: $!";

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;

my $paths  = Developer::Dashboard::PathRegistry->new( home => $home );
my $files  = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $runner = Local::Runner->new;

sub build_manager {
    my (%over) = @_;
    return Developer::Dashboard::RuntimeManager->new(
        app_builder => $over{app_builder} || sub { return Local::Server->new(@_) },
        collectors  => $over{collectors}
          || Developer::Dashboard::Collector->new( paths => $paths ),
        config  => $over{config}  || $config,
        files   => $over{files}   || $files,
        paths   => $over{paths}   || $paths,
        runner  => $over{runner}  || $runner,
    );
}

my $manager = build_manager();

# _sleep_script: one small script file every spawned test child runs.
# A script file, not -e: assigning $0 inside a -e child leaves the
# -e source text in /proc/<pid>/cmdline after the title, so a title
# read never starts with the title. From a file, $0 rewrites the
# whole command line to the title alone.
# A child sets $0 ONLY when a title is passed. A $0 assignment
# rewrites the argv area, and the /proc/<pid>/environ view of the
# child's environment is lost with it, so a child that must carry
# environment markers (the ajax and web-service children) must
# never set $0, and a child that must carry a title must never
# carry markers. _spawn_sleep refuses a call that asks for both.
my $sleep_script = File::Spec->catfile( $test_cwd, 'sleep-child.pl' );
{
    open my $sfh, '>', $sleep_script or die "Unable to write $sleep_script: $!";
    print {$sfh} "my (\$title, \$ignore) = \@ARGV;\n";
    print {$sfh} "\$0 = \$title if defined \$title && length \$title;\n";
    print {$sfh} "\$SIG{TERM} = 'IGNORE' if \$ignore;\n";
    print {$sfh} "select undef, undef, undef, 30;\n";
    close $sfh or die "Unable to close $sleep_script: $!";
}

# _spawn_sleep(%args): a real long-lived child process, spawned the
# GoRoutine way (never fork(), which t/246 forbids in t/). $0 and the
# environment are the child's own: $0 rewrites the Unix command line
# the title readers see, and the env markers are read from /proc.
# The settle sleep matters: the markers and the title are only
# visible once the child has exec'd, and a read in the same instant
# as the spawn can still see the pre-exec state.
# Input: title string, env hash reference, ignore_term boolean.
# Output: spawned process id.
sub _spawn_sleep {
    my (%args) = @_;
    die 'a _spawn_sleep child cannot carry both a title and env markers'
      if defined $args{title} && length $args{title} && $args{env};
    my $title = $args{title} || '';
    my $pid = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $sleep_script, $title, $args{ignore_term} ? 1 : 0 ],
        { $args{env} ? ( env => $args{env} ) : () },
    );
    die 'GoRoutine spawn failed' if !defined $pid;
    sleep 0.3;
    return $pid;
}

# _child_perl5lib($repo_root): the PERL5LIB a spawned child perl
# needs to load the repo and its built XS bundle. A `use lib` line
# in a child script cannot use @ARGV: use runs at compile time,
# before the argv assignment executes, so the paths arrive as undef.
# PERL5LIB is read at startup, before compilation, so it carries
# them. The inherited PERL5LIB (the local CPAN lib) stays at the end.
sub _child_perl5lib {
    my ($repo_root) = @_;
    return join $Config{path_sep},
      File::Spec->catdir( $repo_root, 'lib' ),
      File::Spec->catdir( $repo_root, 'blib', 'lib' ),
      File::Spec->catdir( $repo_root, 'blib', 'arch' ),
      ( defined $ENV{PERL5LIB} ? $ENV{PERL5LIB} : () );
}

# _wait_for_exit($pid, $seconds): waits for a spawned child to exit,
# bounded so a stuck child fails the test instead of hanging the
# suite. Kills the child on timeout. Returns the exit code, or undef
# on timeout.
# Polls process_exited, not process_running: process_running is
# kill(pid, 0), which answers true for a zombie, so an exited child
# that has not been reaped yet would read as still running until
# the timeout. process_exited notices the exit without reaping, and
# wait_process then reaps it and returns the exit code.
sub _wait_for_exit {
    my ( $pid, $seconds ) = @_;
    my $deadline = time() + $seconds;
    while ( time() < $deadline ) {
        if ( Developer::Dashboard::GoRoutine::process_exited($pid) ) {
            return Developer::Dashboard::GoRoutine::wait_process($pid);
        }
        sleep 0.05;
    }
    kill 'KILL', $pid;
    Developer::Dashboard::GoRoutine::wait_process($pid);
    return undef;
}

# _kill_child($pid): ends a spawned test child and reaps it, so no
# test child outlives its section.
sub _kill_child {
    my ($pid) = @_;
    return if !defined $pid || !$pid;
    kill 'TERM', $pid;
    _wait_for_exit( $pid, 5 );
    return;
}

# _iso_at($epoch): an ISO-8601 UTC timestamp for one epoch, the shape
# _iso8601_to_epoch parses.
sub _iso_at {
    my ($epoch) = @_;
    return strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime($epoch) );
}

# _read_file($path): slurps one file, or undef when it is absent.
sub _read_file {
    my ($path) = @_;
    return if !-f $path;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $content;
}

# Fake command directory, on PATH only inside the sections that need
# it. The fakes stand in for Windows tools the way the M1 fake grep
# stood in for grep: the processes they are asked about are real,
# the markers are real, and the signals are real executions of the
# fake. taskkill records every invocation and exits 0 without ending
# anything, so a TERM never lands and the lingering checks see live
# processes. powershell prints the real Unix process table in the
# Windows format _ps_processes parses (pid, tab, command line), so
# the Windows table scan runs for real instead of returning ().
my $fakebin        = tempdir( CLEANUP => 1 );
my $taskkill_args  = File::Spec->catfile( $fakebin, 'taskkill-args.txt' );
my $powershell_log = File::Spec->catfile( $fakebin, 'powershell-log.txt' );
{
    open my $fh, '>', File::Spec->catfile( $fakebin, 'taskkill' )
      or die "Unable to write fake taskkill: $!";
    print {$fh} "#!/bin/sh\n";
    print {$fh} "echo \"\$@\" >> '$taskkill_args'\n";
    print {$fh} "exit 0\n";
    close $fh or die "Unable to close fake taskkill: $!";
    chmod 0755, File::Spec->catfile( $fakebin, 'taskkill' )
      or die "Unable to chmod fake taskkill: $!";

    open my $pfh, '>', File::Spec->catfile( $fakebin, 'powershell' )
      or die "Unable to write fake powershell: $!";
    print {$pfh} "#!/bin/sh\n";
    print {$pfh} "echo \"\$@\" >> '$powershell_log'\n";
    print {$pfh} "ps -eo pid=,args= | awk '{ pid = \$1; \$1 = \"\"; sub(/^ /, \"\", \$0); print pid \"\\t\" \$0 }'\n";
    print {$pfh} "exit 0\n";
    close $pfh or die "Unable to close fake powershell: $!";
    chmod 0755, File::Spec->catfile( $fakebin, 'powershell' )
      or die "Unable to chmod fake powershell: $!";
}

# --- _web_watcher_spares_itself (line 2212) -------------------------------
# One line, no tool or filesystem: is_windows() ? 1 : 0. Both sides
# are driven by localising $OS_NAME (R146), the documented hook.
# The Unix-side checks (1 and 3) are skipped on Windows, where
# the runtime $OS_NAME is already MSWin32.
{
    # On Windows the runtime $OS_NAME is MSWin32, so the watcher
    # spares itself and this check reads 1, not 0. Skip it there;
    # the localised check below still runs on all legs.
    SKIP: {
        skip 'the watcher spares itself on a Windows runtime', 1
          if is_windows();
        is( $manager->_web_watcher_spares_itself(), 0,
            'the watcher does not spare itself on a Unix runtime' );
    }
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $manager->_web_watcher_spares_itself(), 1,
            'the watcher spares itself with $OS_NAME localised to MSWin32' );
    }
    # The localisation restores, but on Windows it restores to
    # MSWin32, so this check reads 1 there, not 0. Skip it there.
    SKIP: {
        skip 'the $OS_NAME localisation restores to MSWin32 on Windows', 1
          if is_windows();
        is( $manager->_web_watcher_spares_itself(), 0,
            'the $OS_NAME localisation restores after the block' );
    }
}

# --- _kill_exact_pids on Unix (lines 2322-2333) --------------------------
# _taskkill_command returns the bare name 'taskkill' when not on
# Windows, so on Unix the command does not exist, the exit is never
# 0, no output ever matches /not found/i, and the count stays 0.
# The pid filter keeps only positive integers.
{
    is( $manager->_kill_exact_pids(), 0,
        '_kill_exact_pids with no pids ends nothing' );
    is( $manager->_kill_exact_pids( undef, 'abc', 0, -3 ), 0,
        '_kill_exact_pids ignores non-pids and ends nothing on Unix' );
    # On Windows the real taskkill kills the pid, so the count is
    # 1, not 0, and the pid is gone. Skip both checks there; the
    # no-pid and non-pid checks above still run on all legs.
    SKIP: {
        skip 'the Unix no-op kill needs a Unix runtime', 2
          if is_windows();

        my $victim = _spawn_sleep();
        is( $manager->_kill_exact_pids($victim), 0,
            '_kill_exact_pids returns 0 for a live pid on Unix' );
        is( $manager->_pid_is_running($victim), 1,
            'the live pid is still running after the Unix no-op kill' );
        _kill_child($victim);
    }
}

# --- _kill_exact_pids with a fake taskkill (lines 2322-2333) ------------
# With $OS_NAME localised to MSWin32, _taskkill_command resolves the
# fake on PATH through command_in_path (the ProcessSupervision POD
# describes the fake taskkill.bat shape). The fake records its args
# and exits 0, so the success path runs for real: ended counts up,
# and the args are exactly /PID <pid> /F, one taskkill per pid.
# On real Windows the fake IS found now (R154 fixed the PATH),
# but it is a Unix shell script and cannot execute there, so the
# whole block is skipped on Windows (R155).
{
    unlink $taskkill_args;
    local $ENV{PATH} = "$fakebin$Config{path_sep}$ENV{PATH}";
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    # The fake is a Unix shell script and cannot execute on
    # Windows, so this check cannot run there. Skip it; the
    # kill-count checks below are skipped there too.
    # This block localises $OS_NAME to MSWin32 to simulate
    # Windows, so is_windows() reads true here on every leg.
    # Guard on $^O, the real OS, so the skips fire only on
    # real Windows. $^O is never localised in this file.
    SKIP: {
        skip 'the fake taskkill is a Unix shell script', 1
          if $^O eq 'MSWin32';
        is( _taskkill_command(), File::Spec->catfile( $fakebin, 'taskkill' ),
            '_taskkill_command resolves the fake taskkill on PATH' );
    }
    # On Windows the fake IS found now (R154 fixed the PATH), but
    # it is a Unix shell script and cannot execute there, so
    # _kill_exact_pids counts 0, not 1/2/1. Skip the kill-count
    # checks there; the logic is covered on Linux and macOS.
    SKIP: {
        skip 'the fake taskkill cannot execute on Windows', 3
          if $^O eq 'MSWin32';
        is( $manager->_kill_exact_pids(11111), 1,
            '_kill_exact_pids counts one ended pid with the fake taskkill' );
        is( $manager->_kill_exact_pids( 11111, 22222 ), 2,
            '_kill_exact_pids counts two ended pids' );
        is( $manager->_kill_exact_pids( undef, 'abc', 0, -3, 33333 ), 1,
            '_kill_exact_pids filters non-pids before calling taskkill' );
    }
    # The fake was never called on Windows, so the args file does
    # not exist there. Skip this check; the kill counts above
    # are skipped on Windows too (the fake cannot run there).
    SKIP: {
        skip 'the fake taskkill is never called on Windows', 1
          if $^O eq 'MSWin32';
        is( _read_file($taskkill_args),
            "/PID 11111 /F\n/PID 11111 /F\n/PID 22222 /F\n/PID 33333 /F\n",
            'the fake taskkill was called once per pid with /PID <pid> /F' );
    }
}

# --- _managed_ajax_processes, second loop (lines 658-668) ----------------
# The procfs second pass only keeps a process whose
# DEVELOPER_DASHBOARD_AJAX_SINGLETON marker is set and whose
# DEVELOPER_DASHBOARD_RUNTIME_ROOT marker matches this runtime.
# The processes are real, spawned with the markers in their own
# environment; the rows table is the one the caller passes in.
# The second loop lives inside `if ( $self->_procfs_available )`,
# and _procfs_available is false where /proc does not exist
# (macOS), so the loop never runs there. The spawned ajax process
# carries env markers but no 'd2 ajax:' title, so only this loop
# can find it. Skip the whole block where /proc is not available,
# the same shape as the looks-loop skip. The block holds six
# checks: the found case asserts both the count and the pid.
SKIP: {
    skip 'the ajax second loop needs /proc (procfs)', 6
      unless $manager->_procfs_available;

    my $root = $paths->state_root;
    my $ajax = _spawn_sleep(
        env => {
            DEVELOPER_DASHBOARD_AJAX_SINGLETON => '1',
            DEVELOPER_DASHBOARD_RUNTIME_ROOT   => $root,
        },
    );
    my @found = $manager->_managed_ajax_processes(
        [ { pid => $ajax, args => 'sleep 30' } ] );
    is( scalar(@found), 1,
        'a process with the singleton and runtime-root markers is found' );
    is( $found[0]{pid}, $ajax, 'the found process is the spawned one' );
    _kill_child($ajax);

    my $plain = _spawn_sleep();
    is( scalar( $manager->_managed_ajax_processes(
                [ { pid => $plain, args => 'sleep 30' } ] ) ),
        0, 'a process with no singleton marker is skipped' );
    _kill_child($plain);

    my $wrong_root = _spawn_sleep(
        env => {
            DEVELOPER_DASHBOARD_AJAX_SINGLETON => '1',
            DEVELOPER_DASHBOARD_RUNTIME_ROOT   => '/somewhere/else',
        },
    );
    is( scalar( $manager->_managed_ajax_processes(
                [ { pid => $wrong_root, args => 'sleep 30' } ] ) ),
        0, 'a process whose runtime-root marker does not match is skipped' );
    _kill_child($wrong_root);

    my $empty_singleton = _spawn_sleep(
        env => {
            DEVELOPER_DASHBOARD_AJAX_SINGLETON => '',
            DEVELOPER_DASHBOARD_RUNTIME_ROOT   => $root,
        },
    );
    is( scalar( $manager->_managed_ajax_processes(
                [ { pid => $empty_singleton, args => 'sleep 30' } ] ) ),
        0, 'a process with an empty singleton marker is skipped' );
    _kill_child($empty_singleton);

    my $empty_marker = _spawn_sleep(
        env => {
            DEVELOPER_DASHBOARD_AJAX_SINGLETON => '1',
            DEVELOPER_DASHBOARD_RUNTIME_ROOT   => '',
        },
    );
    is( scalar( $manager->_managed_ajax_processes(
                [ { pid => $empty_marker, args => 'sleep 30' } ] ) ),
        0, 'a process with an empty runtime-root marker and a non-empty root is skipped' );
    _kill_child($empty_marker);

    # The first loop (a process whose title starts with 'd2 ajax:')
    # is not driven here: it needs a title AND the runtime-root
    # marker, and a child cannot carry both, because setting $0
    # loses the /proc environ view the marker is read from. The
    # first loop is already covered by the existing tests.
}

# --- _is_starman_worker (lines 1984-1987) --------------------------------
# The title is read from /proc/<pid>/cmdline, so a child that sets
# $0 to 'starman worker ...' reads back as a worker. Bad pids and a
# process with no readable title all return 0.
{
    is( $manager->_is_starman_worker(undef), 0,
        'an undefined pid is not a starman worker' );
    is( $manager->_is_starman_worker('abc'), 0,
        'a non-numeric pid is not a starman worker' );
    is( $manager->_is_starman_worker(0), 0,
        'pid zero is not a starman worker' );
    is( $manager->_is_starman_worker(999999), 0,
        'a pid with no process behind it is not a starman worker' );
    my $plain = _spawn_sleep();
    is( $manager->_is_starman_worker($plain), 0,
        'a plain sleep process is not a starman worker' );
    _kill_child($plain);
    # _read_process_title reads /proc/<pid>/cmdline, which does
    # not exist on Windows, and setting $0 in Perl does not change
    # the Windows process title, so the title never reads back
    # there. Skip both title checks on Windows; the negative
    # checks above still run on all legs.
    SKIP: {
        skip 'the $0 title does not read back on Windows', 2
          if is_windows();

        my $worker = _spawn_sleep( title => 'starman worker test' );
        is( $manager->_read_process_title($worker), 'starman worker test',
            'the worker child reads back with its $0 title' );
        is( $manager->_is_starman_worker($worker), 1,
            'a process titled starman worker is a starman worker' );
        _kill_child($worker);
    }
}

# --- _process_started_not_before (lines 2266-2267) ------------------------
# A numeric string comparison: leading zeros are stripped, then the
# longer string wins, then the lexical comparison. Anything
# non-numeric, or missing, is never "not before".
{
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( '200', '100' ), 1,
        'a later start time is not before its parent' );
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( '100', '200' ), 0,
        'an earlier start time is before its parent' );
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( '200', '200' ), 1,
        'the same start time is not before its parent' );
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( '0100', '100' ), 1,
        'leading zeros do not change the comparison' );
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( undef, '100' ), 0,
        'a missing start time is never not before' );
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( 'abc', '100' ), 0,
        'a non-numeric start time is never not before' );
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( '100', undef ), 0,
        'a missing parent start time is never not before' );
}

# --- _descendant_pids_sparing (lines 2292-2312) ---------------------------
# A pure walk over a process listing: deepest first, a child is only
# taken when its start time is not before its parent, the spared pid
# is never returned and nothing below it is walked, a row whose pid
# is its own parent never enters the walk at all.
{
    my ( $found, $refused ) = $manager->_descendant_pids_sparing(
        [
            { pid => 10, ppid => 1,  started => '100' },
            { pid => 11, ppid => 10, started => '150' },
            { pid => 12, ppid => 10, started => '50' },
        ],
        { 10 => '100' },
        undef,
    );
    is_deeply( $found, [ [ 11, '150' ] ],
        'the walk returns the child that started after its parent' );
    is_deeply( $refused,
        ['12: it is older than the process holding its parent pid, so that pid was reused'],
        'the walk refuses the child that started before its parent' );

    ( $found, $refused ) = $manager->_descendant_pids_sparing(
        [
            { pid => 10, ppid => 1,  started => '100' },
            { pid => 11, ppid => 10, started => '150' },
            { pid => 12, ppid => 11, started => '160' },
        ],
        { 10 => '100' },
        12,
    );
    is_deeply( $found, [ [ 11, '150' ] ],
        'the spared pid is never returned' );

    ( $found, $refused ) = $manager->_descendant_pids_sparing(
        [
            { pid => 10, ppid => 1,  started => '100' },
            { pid => 13, ppid => 10, started => undef },
            { pid => 14, ppid => 10, started => 'abc' },
        ],
        { 10 => '100' },
        undef,
    );
    is_deeply( $found, [], 'no child is returned when no start time reads' );
    is_deeply( $refused,
        [ '13: a start time could not be read', '14: a start time could not be read' ],
        'an unreadable start time is refused with its own reason' );

    ( $found, $refused ) = $manager->_descendant_pids_sparing(
        [
            { pid => 14, ppid => 14, started => '150' },
            { pid => 15, ppid => 14, started => '160' },
        ],
        { 10 => '100' },
        undef,
    );
    is_deeply( $found, [], 'a row whose pid is its own parent never enters the walk' );
    is_deeply( $refused, [], 'nothing is refused when nothing is walked' );

    ( $found, $refused ) = $manager->_descendant_pids_sparing(
        [
            { pid => 10, ppid => 1,  started => '100' },
            { pid => 11, ppid => 10, started => '150' },
            { pid => 12, ppid => 11, started => '160' },
            { pid => 13, ppid => 11, started => '155' },
        ],
        { 10 => '100' },
        undef,
    );
    is_deeply( $found, [ [ 12, '160' ], [ 13, '155' ], [ 11, '150' ] ],
        'the walk returns descendants deepest first, then by pid' );
}

# --- _collector_stalled_for_watchdog, started_at (lines 1625-1627) --------
# The cron path reads the heartbeat and the started_at from the
# running entry's state. A loop that started less than one stale
# window ago cannot be stalled, even on a stale heartbeat: its first
# run has not had a full window in which to happen yet.
{
    my $job = { schedule => 'cron', interval => 1, timeout_ms => 100 };
    my $status = { last_completed_at => _iso_at( time() - 3600 ) };

    my $fresh = {
        state => {
            heartbeat_at => _iso_at( time() - 3600 ),
            started_at   => _iso_at( time() ),
        },
    };
    is( $manager->_collector_stalled_for_watchdog( $job, $status, $fresh ), 0,
        'a freshly started loop is not stalled on a stale heartbeat' );

    my $old = {
        state => {
            heartbeat_at => _iso_at( time() - 3600 ),
            started_at   => _iso_at( time() - 3600 ),
        },
    };
    is( $manager->_collector_stalled_for_watchdog( $job, $status, $old ), 1,
        'a loop started long ago is stalled on a stale heartbeat' );

    my $no_started = { state => { heartbeat_at => _iso_at( time() ) } };
    is( $manager->_collector_stalled_for_watchdog( $job, $status, $no_started ), 0,
        'a loop with no started_at is judged on its fresh heartbeat alone' );

    my $interval_job = { schedule => 'interval', interval => 1, timeout_ms => 100 };
    is( $manager->_collector_stalled_for_watchdog( $interval_job, $status, undef ), 1,
        'a non-cron loop with no recent progress is stalled' );
    is( $manager->_collector_stalled_for_watchdog( $interval_job, {}, undef ), 0,
        'a loop with no usable timestamp is not stalled' );
    is( $manager->_collector_stalled_for_watchdog( 'not-a-hash', $status, undef ), 0,
        'a non-hash job is never stalled' );
    is( $manager->_collector_stalled_for_watchdog( $job, 'not-a-hash', undef ), 0,
        'a non-hash status is never stalled' );
}

# --- _recorded_web_pid_for_lifetime_owner (line 2150) ---------------------
# The pid this runtime itself recorded, read from the web_pid file.
# Malformed or missing means no recorded web.
{
    my $web_pid_file = $files->resolve_file('web_pid');
    unlink $web_pid_file if -f $web_pid_file;
    is( $manager->_recorded_web_pid_for_lifetime_owner(), undef,
        'no recorded web pid when the file is absent' );
    $files->write( 'web_pid', "abc\n" );
    is( $manager->_recorded_web_pid_for_lifetime_owner(), undef,
        'a non-numeric recorded web pid is ignored' );
    $files->write( 'web_pid', "0\n" );
    is( $manager->_recorded_web_pid_for_lifetime_owner(), undef,
        'a zero recorded web pid is ignored' );
    $files->write( 'web_pid', "4242\n" );
    is( $manager->_recorded_web_pid_for_lifetime_owner(), 4242,
        'a numeric recorded web pid is returned' );
    unlink $web_pid_file;
}

# --- _log_collector_supervisor_lifetime_event (line 2130) -----------------
# One line in the global collector log. A missing or empty message
# writes nothing; a message is collapsed to single spaces and
# trimmed before it is written.
{
    is( $manager->_log_collector_supervisor_lifetime_event(undef), undef,
        'an undefined lifetime message writes nothing' );
    is( $manager->_log_collector_supervisor_lifetime_event(''), undef,
        'an empty lifetime message writes nothing' );
    is( $manager->_log_collector_supervisor_lifetime_event('  spaced   message  '), 1,
        'a lifetime message is written' );
    my $log = _read_file( $files->resolve_file('collector_log') );
    like( $log, qr/\[supervisor\]\[lifetime-owner\] spaced message\n/,
        'the lifetime message is collapsed and trimmed in the log' );
}

# --- _log_web_lifetime_owner_event (lines 2407-2408) ----------------------
# One line in the watcher log for one web pid. A missing path or a
# missing message writes nothing.
{
    my $log_path = File::Spec->catfile( $test_cwd, 'web-lifetime.log' );
    is( $manager->_log_web_lifetime_owner_event( undef, 'hello' ), undef,
        'an undefined watcher log path writes nothing' );
    is( $manager->_log_web_lifetime_owner_event( '', 'hello' ), undef,
        'an empty watcher log path writes nothing' );
    is( $manager->_log_web_lifetime_owner_event( $log_path, undef ), undef,
        'an undefined watcher message writes nothing' );
    is( $manager->_log_web_lifetime_owner_event( $log_path, '' ), undef,
        'an empty watcher message writes nothing' );
    is( $manager->_log_web_lifetime_owner_event( $log_path, 'hello' ), 1,
        'a watcher message is written' );
    like( _read_file($log_path), qr/hello\n/,
        'the watcher message lands in the log file' );
}

# --- _stop_web_pid_as_its_watcher, fallback (lines 2354-2362) -------------
# With $OS_NAME localised, the watcher spares itself, so the ordinary
# stop is skipped and the tree kill is attempted. _powershell_command
# returns '' on Unix even simulated, so _windows_process_tree_rows
# returns undef, the fallback branch fires, and the ordinary stop
# runs. The ordinary stop needs a taskkill on the simulated Windows
# side: without one _send_signal dies on the missing command, so the
# fake taskkill is on PATH here. The fake records its args and exits
# 0 without ending anything, so the fallback returns the pid and
# the web is still alive afterwards; the real ending is proven by
# the runtime-$OS_NAME web above and on the Windows legs in the
# Jenkins proof. At runtime $OS_NAME the ordinary stop runs
# directly and ends the web for real.
{
    my $log_path = File::Spec->catfile( $test_cwd, 'watcher-fallback.log' );
    unlink $taskkill_args;
    local $ENV{PATH} = "$fakebin$Config{path_sep}$ENV{PATH}";

    my $plain = _spawn_sleep();
    is( $manager->_stop_web_pid_as_its_watcher( $plain, undef, '' ), undef,
        'a process that is not a managed web is left alone' );
    is( $manager->_pid_is_running($plain), 1,
        'the unmanaged process is still running' );
    _kill_child($plain);
    is( $manager->_stop_web_pid_as_its_watcher( 999999, undef, '' ), undef,
        'a pid with no process behind it is left alone' );

    # The six checks below need _is_managed_web to recognise the
    # spawned sleep, and _is_managed_web reads the WEB_SERVICE
    # marker from /proc/<pid>/environ, which does not exist on
    # macOS. Skip them where /proc is not available, the same
    # shape as the ajax second-loop skip. The three negative
    # checks above stay and run on all legs: they only need
    # _is_managed_web to return 0, which it does everywhere for
    # an unmarked pid or a pid with no process behind it.
    SKIP: {
        skip 'the watcher fallback needs /proc (procfs) to recognise a managed web', 6
          unless $manager->_procfs_available;

        my $web = _spawn_sleep(
            env => { DEVELOPER_DASHBOARD_WEB_SERVICE => '1' } );
        is( $manager->_stop_web_pid_as_its_watcher( $web, $log_path, '' ), $web,
            'the ordinary stop ends a managed web at runtime $OS_NAME' );
        # The stop has already waited for the web to go, but the reap
        # and the liveness read race the scheduler: a child that has
        # just been killed can still read as running for a moment.
        # Poll briefly for the gone state; a child that is really still
        # alive stays alive past the poll and fails the test.
        my $gone = 0;
        for my $i ( 1 .. 20 ) {
            if ( !$manager->_pid_is_running($web) ) { $gone = 1; last }
            sleep 0.1;
        }
        ok( $gone, 'the web is gone after the ordinary stop' );

        my $spared = _spawn_sleep(
            env => { DEVELOPER_DASHBOARD_WEB_SERVICE => '1' } );
        {
            local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
            is( $manager->_stop_web_pid_as_its_watcher( $spared, $log_path, '' ), $spared,
                'the fallback returns the pid when the tree is not listed' );
        }
        is( $manager->_pid_is_running($spared), 1,
            'the web is still alive: the fake taskkill ends nothing' );
        is( _read_file($taskkill_args), "/PID $spared /T /F\n/PID $spared /T /F\n",
            'the fallback TERMd then KILLd the web through the fake taskkill' );
        like( _read_file($log_path), qr/web tree not listed: the process tree of web pid $spared/,
            'the fallback logs that the web tree was not listed' );
        _kill_child($spared);
    }
}

# --- _check_collector_supervisor_parent, direct paths (lines 2021-2059) ---
# web_state names the serve pid. A live pid is adopted, the same pid
# refreshes the grace, a live Starman worker is never adopted, and a
# dead pid is adopted with dead_since starting now. A malformed pid
# in web_state names nothing.
{
    my $web_state_file = $files->web_state;
    unlink $web_state_file if -f $web_state_file;

    my $parent = {};
    is( $manager->_check_collector_supervisor_parent( ['alpha.collector'], $parent ),
        undef, 'no web state leaves the parent unadopted' );
    is_deeply( $parent, {}, 'the parent stays empty with no web' );

    my $web = _spawn_sleep();
    $manager->_write_web_state( { pid => $web, status => 'running' } );
    is( $manager->_check_collector_supervisor_parent( ['alpha.collector'], $parent ),
        undef, 'a live web pid is adopted' );
    is( $parent->{pid}, $web, 'the adopted parent is the live web pid' );
    is( $parent->{dead_since}, undef, 'a live adoption clears dead_since' );

    $parent->{dead_since} = time() - 100;
    is( $manager->_check_collector_supervisor_parent( ['alpha.collector'], $parent ),
        undef, 'the same live pid refreshes the grace' );
    is( $parent->{dead_since}, undef, 'the refresh clears dead_since' );
    _kill_child($web);

    my $worker = _spawn_sleep( title => 'starman worker test' );
    $manager->_write_web_state( { pid => $worker, status => 'running' } );
    my $no_parent = {};
    is( $manager->_check_collector_supervisor_parent( ['alpha.collector'], $no_parent ),
        undef, 'a live starman worker is not adopted' );
    # On Windows the $0 title does not read back, so the live
    # starman worker is treated as a regular web pid and adopted.
    # Skip this check there; the return value above still runs.
    SKIP: {
        skip 'the starman title does not read back on Windows', 1
          if is_windows();
        is_deeply( $no_parent, {}, 'no parent is adopted from a worker' );
    }

    my $live = _spawn_sleep();
    my $kept = { pid => $live, dead_since => time() - 100 };
    is( $manager->_check_collector_supervisor_parent( ['alpha.collector'], $kept ),
        undef, 'an adopted live parent still decides over a worker' );
    # On Windows the $0 title does not read back, so the live
    # starman worker is adopted and replaces the already-adopted
    # parent. Skip this check there; the return value above still
    # runs.
    SKIP: {
        skip 'the starman title does not read back on Windows', 1
          if is_windows();
        is( $kept->{pid}, $live, 'the adopted parent is kept, not replaced by the worker' );
    }
    _kill_child($live);
    _kill_child($worker);

    $manager->_write_web_state( { pid => 999999, status => 'running' } );
    my $dead_parent = {};
    is( $manager->_check_collector_supervisor_parent( ['alpha.collector'], $dead_parent ),
        undef, 'a dead web pid is adopted' );
    is( $dead_parent->{pid}, 999999, 'the adopted parent is the dead web pid' );
    ok( defined $dead_parent->{dead_since}
          && $dead_parent->{dead_since} <= time()
          && $dead_parent->{dead_since} > time() - 10,
        'a dead adoption starts dead_since now' );

    $manager->_write_web_state( { pid => 'abc', status => 'running' } );
    my $bad_parent = {};
    is( $manager->_check_collector_supervisor_parent( ['alpha.collector'], $bad_parent ),
        undef, 'a non-numeric web pid names nothing' );
    is_deeply( $bad_parent, {}, 'no parent is adopted from a bad pid' );

    $manager->_write_web_state( { pid => 0, status => 'running' } );
    is( $manager->_check_collector_supervisor_parent( ['alpha.collector'], $bad_parent ),
        undef, 'pid zero names nothing' );
    unlink $web_state_file;
}

# --- _check_collector_supervisor_parent, parent gone (lines 2060-2063) ---
# Once the adopted parent has been dead past the grace period, the
# supervisor stops the watched loops and shuts down. The shutdown
# exits the process (POSIX::_exit), so it runs in a spawned child:
# the child pre-seeds an adopted parent dead long ago, calls the
# check once, and the parent reads back the exit code, the stopped
# loops, and the supervisor state file being gone.
{
    my $repo_root    = File::Spec->catdir( $Bin, '..' );
    my $stopped_file = File::Spec->catfile( $test_cwd, 'parent-gone-stopped.txt' );
    my $child_script = File::Spec->catfile( $test_cwd, 'parent-gone-child.pl' );
    my $child_out    = File::Spec->catfile( $test_cwd, 'parent-gone-out.txt' );
    my $child_err    = File::Spec->catfile( $test_cwd, 'parent-gone-err.txt' );
    {
        open my $cfh, '>', $child_script or die "Unable to write $child_script: $!";
        print {$cfh} <<'CHILD';
use strict;
use warnings;
use File::Spec;
my ( $repo, $home, $stopped_file ) = @ARGV;
use Developer::Dashboard::Collector;
use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;
{
    package Local::Runner;
    sub new { my ( $c, %a ) = @_; return bless { stopped => [], %a }, $c }
    sub running_loops { return () }
    sub loop_state { return undef }
    sub stop_loop {
        my ( $s, $name ) = @_;
        open my $fh, '>>', $stopped_file or die "Unable to write $stopped_file: $!";
        print {$fh} "$name\n";
        close $fh or die "Unable to close $stopped_file: $!";
        return 1;
    }
    package Local::Server;
    sub new { my ( $c, %a ) = @_; return bless { %a }, $c }
    sub run { return 'foreground-ran' }
}
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";
my $paths  = Developer::Dashboard::PathRegistry->new( home => $home );
my $files  = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $manager = Developer::Dashboard::RuntimeManager->new(
    app_builder => sub { return Local::Server->new(@_) },
    collectors  => Developer::Dashboard::Collector->new( paths => $paths ),
    config      => $config,
    files       => $files,
    paths       => $paths,
    runner      => Local::Runner->new,
);
$manager->_write_web_state( { pid => 999999, status => 'running' } );
my $parent = { pid => 999999, dead_since => time() - 100 };
$manager->_check_collector_supervisor_parent( ['alpha.collector'], $parent );
print "parent-gone check returned, which it must never do\n";
exit 3;
CHILD
        close $cfh or die "Unable to close $child_script: $!";
    }
    my $child = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $child_script, $repo_root, $home, $stopped_file ],
        {
            stdout => $child_out,
            stderr => $child_err,
            env    => {
                PERL5LIB => _child_perl5lib($repo_root),
                DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_PARENT_GRACE_SECONDS => '0.2',
            },
        },
    );
    ok( defined $child && $child > 0, 'the parent-gone child spawns' );
    my $exit = _wait_for_exit( $child, 10 );
    if ( !defined $exit ) {
        diag 'parent-gone child timed out; stderr: ' . ( _read_file($child_err) // '' );
    }
    is( $exit, 0, 'the parent-gone check exits the supervisor' );
    is( _read_file($stopped_file), "alpha.collector\n",
        'the watched loop is stopped before the shutdown' );
    # The shutdown writes the parent-gone status and then removes
    # the state file in the same call, so the status itself cannot
    # be read back after the exit. The observable end of it is the
    # state file being gone.
    ok( !-f $manager->_collector_supervisor_statefile,
        'the shutdown removes the supervisor state file' );
    # The child wrote this web state into the shared home; clear it
    # so the later stop_web section starts with no web state.
    my $web_state_file = $files->web_state;
    unlink $web_state_file if -f $web_state_file;
}

# --- _run_collector_supervisor_child, quiesce (lines 1954-1964) -----------
# The quiesce block only runs with no adopted serve parent. The
# supervisor exits once no watched loop has been live for the
# quiesce period, and stays alive while a scan fails or a watched
# loop is live. The shutdown exits the process, so it runs in a
# spawned child with a tiny quiesce interval and a tiny poll
# interval, and a bounded wait so a stuck child fails the test.
# The collector must be configured, or the child exits 'stopped'
# for having nothing to watch before the quiesce block ever runs.
{
    $config->save_global(
        {
            collectors => [
                { name => 'alpha.collector', command => 'true', cwd => 'home', interval => 1 },
            ],
        }
    );
    $manager->_write_collector_supervisor_state(
        { watched_names => ['alpha.collector'] } );

    my $repo_root    = File::Spec->catdir( $Bin, '..' );
    my $child_script = File::Spec->catfile( $test_cwd, 'quiesce-child.pl' );
    my $child_out    = File::Spec->catfile( $test_cwd, 'quiesce-out.txt' );
    my $child_err    = File::Spec->catfile( $test_cwd, 'quiesce-err.txt' );
    {
        open my $cfh, '>', $child_script or die "Unable to write $child_script: $!";
        print {$cfh} <<'CHILD';
use strict;
use warnings;
use File::Spec;
my ( $repo, $home ) = @ARGV;
use Developer::Dashboard::Collector;
use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;
{
    package Local::Runner;
    my $calls = 0;
    sub new { my ( $c, %a ) = @_; return bless { stopped => [], %a }, $c }
    sub running_loops {
        $calls++;
        # R153: log each poll result to stderr, so the next proof
        # shows what the child was doing if it hangs. The test
        # reads the child's stderr on timeout.
        my $now = time;
        if ( $calls == 1 ) {
            print STDERR "[$now] running_loops call 1: scan fails\n";
            die "loop scan failed\n";
        }
        if ( $calls == 2 ) {
            print STDERR "[$now] running_loops call 2: one live loop (alpha.collector)\n";
            return ( { name => 'alpha.collector' } );
        }
        print STDERR "[$now] running_loops call $calls: no live loops\n";
        return ();
    }
    sub loop_state { return undef }
    # 999999 is above the macOS max pid (99999), so it never
    # exists: _collector_runtime_ready fails fast on the pid.
    # 4242 is a live pid on macOS, and the readiness poll then
    # ran 271 times and the child never reached the quiesce check.
    sub start_loop { return 999999 }
    sub stop_loop { return 1 }
    package Local::Server;
    sub new { my ( $c, %a ) = @_; return bless { %a }, $c }
    sub run { return 'foreground-ran' }
}
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";
my $paths  = Developer::Dashboard::PathRegistry->new( home => $home );
my $files  = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $manager = Developer::Dashboard::RuntimeManager->new(
    app_builder => sub { return Local::Server->new(@_) },
    collectors  => Developer::Dashboard::Collector->new( paths => $paths ),
    config      => $config,
    files       => $files,
    paths       => $paths,
    runner      => Local::Runner->new,
);
# R156: log the parent-adoption state before the supervisor runs,
# so the next proof shows whether a parent pid exists on macOS.
# The quiesce check only runs when no parent is adopted.
my $quiesce_state = $manager->web_state;
print STDERR 'quiesce diagnostic: web_state pid=',
    ( defined $quiesce_state && defined $quiesce_state->{pid}
        ? $quiesce_state->{pid}
        : 'no web state' ),
    ' quiesce_seconds=', $manager->_collector_supervisor_quiesce_seconds,
    ' poll_interval=', $manager->_collector_supervisor_poll_interval, "\n";
$manager->_run_collector_supervisor_child( daemonize => 0, redirect => 0 );
print "supervisor child returned, which it must never do\n";
exit 3;
CHILD
        close $cfh or die "Unable to close $child_script: $!";
    }
    my $child = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $child_script, $repo_root, $home ],
        {
            stdout => $child_out,
            stderr => $child_err,
            env    => {
                PERL5LIB => _child_perl5lib($repo_root),
                DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS => '0.2',
                DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL   => '0.1',
            },
        },
    );
    ok( defined $child && $child > 0, 'the quiesce child spawns' );
    # R153: the wait is 30s, not 10s, so the next proof shows
    # whether the child is slow (exits in 10-30s) or truly hung
    # (still running at 30s). The child's stderr log, read on
    # timeout below, shows what it was doing.
    my $exit = _wait_for_exit( $child, 30 );
    if ( !defined $exit ) {
        diag 'quiesce child timed out; stderr: ' . ( _read_file($child_err) // '' );
    }
    is( $exit, 0, 'the supervisor exits once its loops have been dead for the quiesce period' );
    # The shutdown writes the quiesced status and then removes the
    # state file in the same call, so the status itself cannot be
    # read back after the exit. The observable end of it is the
    # state file being gone.
    ok( !-f $manager->_collector_supervisor_statefile,
        'the shutdown removes the supervisor state file' );
}

# --- stop_web, Windows branch (lines 500, 506, 515, 517) ------------------
# With $OS_NAME localised to MSWin32, stop_web takes the Windows
# branch on Unix. The fake powershell prints the real Unix process
# table in the Windows format _ps_processes parses, so the scan runs
# for real; the fake taskkill records its args and exits 0 without
# ending anything, so a TERM never lands and the lingering checks
# see live processes. The ajax and legacy workers are real processes
# with real markers and titles; only the two Windows tools are faked,
# the same shape as the M1 fake grep and the approved fake taskkill.
{
    unlink $taskkill_args;
    unlink $powershell_log;
    # The parent-gone child wrote pid 999999 into this home's web
    # state; this section starts with no web state at all.
    my $web_state_file = $files->web_state;
    unlink $web_state_file if -f $web_state_file;
    local $ENV{PATH} = "$fakebin$Config{path_sep}$ENV{PATH}";
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';

    my $root = $paths->state_root;
    # The ajax worker is found by the markers alone: a title would
    # need $0, and $0 loses the /proc environ view the markers are
    # read from.
    my $ajax = _spawn_sleep(
        env => {
            DEVELOPER_DASHBOARD_AJAX_SINGLETON => '1',
            DEVELOPER_DASHBOARD_RUNTIME_ROOT   => $root,
        },
    );
    my $legacy = _spawn_sleep( title => 'd2 serve' );
    select undef, undef, undef, 0.3;

    my $rc = $manager->stop_web();
    # There is no web state, but running_web finds the live legacy
    # web in the process table, so stop_web returns its pid.
    # On Windows the legacy worker is found only by its $0 title
    # 'd2 serve', and $0 does not change the process CommandLine
    # there, so the real process table has no 'd2 serve' row and
    # stop_web returns undef. Skip this check there; the call above
    # still runs. This block localises $OS_NAME to MSWin32, so
    # is_windows() reads true here on every leg. Guard on $^O, the
    # real OS, so the skip fires only on real Windows. $^O is never
    # localised in this file.
    SKIP: {
        skip 'the legacy worker is found only by its $0 title, which does not read back on Windows', 1
          if $^O eq 'MSWin32';
        is( $rc, $legacy, 'stop_web with a live legacy web and no web state returns the web pid' );
    }
    # The Windows branch TERMs the web pid first, then the ajax and
    # legacy workers, then KILLs the web pid and the lingering
    # workers, in that order.
    # The fake powershell prints the process table with no
    # guaranteed order, so the ajax and legacy workers can come
    # back in either order inside each round. The web pid is
    # TERMed first and KILLed first, and the TERM round comes
    # before the KILL round, so sort only the two worker lines
    # inside each round before comparing. The count stays one
    # assertion, so the file still has 107 checks.
    my $kills_text = _read_file($taskkill_args) // '';
    my @kills = split /\n/, $kills_text;
    my ( $worker_a, $worker_b )
        = sort "/PID $ajax /T /F", "/PID $legacy /T /F";
    if ( scalar(@kills) == 6 ) {
        $kills_text = join( "\n",
            $kills[0],
            ( sort @kills[ 1 .. 2 ] ),
            $kills[3],
            ( sort @kills[ 4 .. 5 ] ) ) . "\n";
    }
    # The kills list has six entries only when the ajax worker is
    # found, and the ajax worker is found only by the second loop,
    # which needs /proc. On macOS (no /proc) the list has four
    # entries, all the legacy pid. Skip this check there.
    SKIP: {
        skip 'the stop_web kills need the ajax worker found through /proc', 1
          unless $manager->_procfs_available;
        is( $kills_text,
            "/PID $legacy /T /F\n$worker_a\n$worker_b\n/PID $legacy /T /F\n$worker_a\n$worker_b\n",
            'stop_web TERMs the web, the ajax and legacy workers, then KILLs the lingering ones' );
    }
    # On Windows the fake powershell IS found on PATH, but it is a
    # Unix shell script and cannot execute there, so the scan returns
    # no rows and the fake log is never written. Skip this check
    # there. Guard on $^O, the real OS: this block localises
    # $OS_NAME to MSWin32, so is_windows() would fire on every leg.
    SKIP: {
        skip 'the fake powershell cannot execute on Windows', 1
          if $^O eq 'MSWin32';
        ok( defined _read_file($powershell_log)
              && length( _read_file($powershell_log) ) > 0,
            'the Windows table scan ran through the fake powershell' );
    }
    is( $manager->_pid_is_running($ajax), 1,
        'the ajax worker is still alive: the fake taskkill ends nothing' );
    is( $manager->_pid_is_running($legacy), 1,
        'the legacy worker is still alive: the fake taskkill ends nothing' );
    _kill_child($ajax);
    _kill_child($legacy);
}

# --- _stop_web_pid_as_its_watcher, looks loop (lines 2369-2394) -----------
# The looks loop needs a real Windows process tree: real PowerShell
# rows and a real taskkill. It cannot run on Unix, even simulated,
# because _powershell_command returns '' there and the rows are
# undef. It runs here only on a real Windows leg, where the Jenkins
# proof runs this file. The web child spawns a grandchild and writes
# its pid to a file; the watcher stop ends both, and the tail of the
# wait loop is driven by stubbing _pid_is_running to 1 (the t/46
# pattern) so the web reads as still running after the kills.
# The child must also be recognisable as a managed web on Windows
# (R161): the WEB_SERVICE marker cannot be read there, because
# _read_process_env_marker reads /proc/<pid>/environ and Windows
# has no /proc, and the $0 title never changes the Windows
# CommandLine, so _is_managed_web falls through to the persisted
# state proof. The child therefore listens on a port (bound to
# port 0, the OS assigns a free one) and writes the port to a
# file, and the test writes web state naming the child pid as
# running on that port before each stop. The socket stays open
# for the child's whole life, so the listener table names it.
SKIP: {
    skip 'the looks loop needs a real Windows process tree', 8
      unless is_windows();

    my $repo_root = File::Spec->catdir( $Bin, '..' );
    my $gc_file   = File::Spec->catfile( $test_cwd, 'grandchild-pid.txt' );
    my $port_file = File::Spec->catfile( $test_cwd, 'looks-web-port.txt' );
    my $web_script = File::Spec->catfile( $test_cwd, 'looks-web-child.pl' );
    {
        open my $cfh, '>', $web_script or die "Unable to write $web_script: $!";
        print {$cfh} <<'CHILD';
use strict;
use warnings;
use File::Spec;
use IO::Socket::INET;
my ( $repo, $gc_file, $port_file ) = @ARGV;
use Developer::Dashboard::GoRoutine ();
# Listen first, so the port is known before the grandchild spawns.
# The socket stays open for the child's whole life: the listener
# table must name this pid on the saved port when the stop runs.
my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    ReuseAddr => 1,
    Listen    => 1,
) or die "Unable to listen: $!";
my $port = $listener->sockport();
open my $pfh, '>', $port_file or die "Unable to write $port_file: $!";
print {$pfh} "$port\n";
close $pfh or die "Unable to close $port_file: $!";
my $grandchild = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'select undef, undef, undef, 30;' ], {} );
die 'GoRoutine spawn failed' if !defined $grandchild;
open my $fh, '>', $gc_file or die "Unable to write $gc_file: $!";
print {$fh} "$grandchild\n";
close $fh or die "Unable to close $gc_file: $!";
select undef, undef, undef, 30;
CHILD
        close $cfh or die "Unable to close $web_script: $!";
    }
    my $web = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $web_script, $repo_root, $gc_file, $port_file ],
        { env => {
            PERL5LIB => _child_perl5lib($repo_root),
            DEVELOPER_DASHBOARD_WEB_SERVICE => '1',
        } },
    );
    ok( defined $web && $web > 0, 'the looks-loop web child spawns' );
    my $grandchild;
    for ( 1 .. 50 ) {
        last if defined( $grandchild = _read_file($gc_file) );
        sleep 0.1;
    }
    ok( defined $grandchild && $grandchild =~ /^\d+$/,
        'the web child records its grandchild pid' );
    chomp $grandchild if defined $grandchild;
    # The port file is polled the same way. No new check here: the
    # block stays at 8 checks, and a missing port dies loudly, the
    # same as a failed spawn above.
    my $port;
    for ( 1 .. 50 ) {
        last if defined( $port = _read_file($port_file) );
        sleep 0.1;
    }
    chomp $port if defined $port;
    die 'looks-web child did not report a listener port'
      if !defined $port || $port !~ /^\d+$/ || $port < 1;
    # Write web state before the stop: on Windows this is the only
    # proof _is_managed_web can use (no /proc marker, no title),
    # and the state names this pid as running on its listener port.
    $manager->_write_web_state( { pid => $web, status => 'running', port => $port } );
    select undef, undef, undef, 0.3;
    is( $manager->_stop_web_pid_as_its_watcher( $web, undef, '' ), $web,
        'the looks loop ends the web through its tree' );
    is( $manager->_pid_is_running($web), 0, 'the web is gone after the tree kill' );
    is( $manager->_pid_is_running($grandchild), 0,
        'the grandchild is gone after the tree kill' );

    # The wait-loop tail: the web is already dead, but _pid_is_running
    # is stubbed to 1, so the thirty polls run out and the final
    # _kill_exact_pids runs before the pid is returned.
    # The port file is unlinked first, so the poll below waits for
    # the second child's fresh port, not the first child's stale one.
    unlink $port_file;
    my $web2 = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $web_script, $repo_root, $gc_file, $port_file ],
        { env => {
            PERL5LIB => _child_perl5lib($repo_root),
            DEVELOPER_DASHBOARD_WEB_SERVICE => '1',
        } },
    );
    ok( defined $web2 && $web2 > 0, 'the wait-tail web child spawns' );
    my $port2;
    for ( 1 .. 50 ) {
        last if defined( $port2 = _read_file($port_file) );
        sleep 0.1;
    }
    chomp $port2 if defined $port2;
    die 'wait-tail web child did not report a listener port'
      if !defined $port2 || $port2 !~ /^\d+$/ || $port2 < 1;
    # Fresh state for the second child: the file still names the
    # first (now dead) web, so _is_managed_web would not match.
    $manager->_write_web_state( { pid => $web2, status => 'running', port => $port2 } );
    select undef, undef, undef, 0.3;
    {
        no warnings 'redefine';
        local *Developer::Dashboard::RuntimeManager::_pid_is_running =
          sub { return 1 };
        is( $manager->_stop_web_pid_as_its_watcher( $web2, undef, '' ), $web2,
            'the wait loop returns the pid after the final kill' );
    }
    ok( !$manager->_pid_is_running($web2), 'the web is really gone even though liveness was stubbed' );
    _kill_child($web2);
}

done_testing();

chdir $original_cwd or die "Unable to chdir back to $original_cwd: $!";

__END__

=head1 NAME

t/1008-runtime-manager-m4.t - M4 RuntimeManager coverage tests

=head1 PURPOSE

Covers the RuntimeManager.pm remainder from the R83 coverage
programme: the watcher and kill paths (_web_watcher_spares_itself,
_kill_exact_pids, _stop_web_pid_as_its_watcher), the ajax singleton
scan, the supervisor parent and quiesce paths, the watchdog
started_at guard, and the scattered lifetime and logging guards.
Written first, before any implementation change, as the M4 milestone
requires.

=head1 WHY IT EXISTS

Cover build #15 measured RuntimeManager.pm at stmt 96.4, branch
93.4, cond 87.1, sub 96.7, total 93.8. The uncovered lines cluster
in the watcher and kill paths, the supervisor parent and quiesce
paths, and the scattered guards. This file drives them in the
instrumented suite. The simulation hook is $OS_NAME, not $^O:
Platform.pm copies $^O into $OS_NAME at load time and is_windows()
reads $OS_NAME, so localising $^O does not drive it (R146).

=head1 WHEN TO USE

Run this file whenever RuntimeManager.pm changes. It is part of the
normal suite, not a probe: if it fails, a RuntimeManager behaviour
regressed.

=head1 HOW TO USE

    prove -v t/1008-runtime-manager-m4.t

Every wait goes through _wait_for_exit, so a stuck child fails a
test instead of hanging the suite. Two shapes need care: the
supervisor shutdowns exit the process, so the parent-gone and
quiesce paths run in spawned children and the parent reads back
their exit code and state file; and the Windows looks loop needs a
real Windows process tree, so it is skipped on Unix and runs only
on the Windows legs of the Jenkins proof.

=head1 WHAT USES IT

The M4 milestone of the R83 coverage programme, and the cover
re-measure that follows it. The Jenkins proof runs this file on all
five legs.

=head1 EXAMPLES

    make test TEST_FILES=t/1008-runtime-manager-m4.t

=cut
