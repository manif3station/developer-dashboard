use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Developer::Dashboard::GoRoutine ();
use POSIX qw(WNOHANG);
use Test::More;
use Time::HiRes qw(sleep);

# Fixture pids from t/09: 3101/3102 are the round-42 failing block (the real
# stop_collectors call with no _pid_is_running stub); 1111/2222 are the
# earlier real stop_collectors block that passed; the rest are other t/09
# fake pids plus the monitor's 10000-10003 range.
my @FIXTURE_PIDS = ( 1111, 2222, 1101, 1102, 2101, 2102, 3101, 3102, 9111, 999991, 10000, 10001, 10002, 10003, 1 );

my $IS_WINDOWS = $^O eq 'MSWin32';

# Win32 exit code for a process that has not exited yet.
my $STILL_ACTIVE = 259;

# Least-privilege access right that still lets OpenProcess report on a
# process owned by another user; PROCESS_QUERY_INFORMATION is denied for
# some system processes and would false-negative live pids.
my $QUERY_LIMITED_INFORMATION = 0x1000;

# How long the live-child control sleeps, and the bounds on every poll loop.
# The micro itself must never hang: each wait is capped and the child always
# exits on its own, so no kill is ever needed to end a control.
my $SLEEPER_SECONDS   = 3;
my $EXIT_POLL_LIMIT   = 10;
my $REPEAT_SLEEP      = 10;
my $REPEAT_COUNT      = 3;

# _kill0($pid)
# Runs kill(0) and captures $! and $^E immediately, before any other call
# can overwrite them. A false positive must be distinguishable from a
# stale errno, so the errno values travel with the verdict.
# Output: (alive boolean, errno number, errno string, Win32 error number).
sub _kill0 {
    my ($pid) = @_;
    my $alive = kill( 0, $pid ) ? 1 : 0;
    my $errno_num = $! + 0;
    my $errno_str = "$!";
    my $winerr    = $^E + 0;
    return ( $alive, $errno_num, $errno_str, $winerr );
}

# _live_pids()
# Enumerates the live pid set from the operating system in this process,
# adjacent in time to the kill(0) probes so churn cannot skew the
# cross-check: tasklist on Windows, ps elsewhere. Both are real system
# binaries, not fakes.
# Output: hash reference pid => 1, or undef when enumeration fails.
sub _live_pids {
    my %live;
    if ($IS_WINDOWS) {
        open my $fh, '-|', 'tasklist', '/FO', 'CSV', '/NH' or return undef;
        while ( my $line = <$fh> ) {
            # "image.exe","1234","Console","1","...": the pid is field 2.
            my @fields = split /","/, $line;
            next if @fields < 2;
            my $pid = $fields[1];
            $pid =~ s/^"|"$//g;
            $live{$pid} = 1 if $pid =~ /^\d+$/;
        }
        close $fh;
        return \%live;
    }
    open my $fh, '-|', 'ps', '-eo', 'pid' or return undef;
    while ( my $line = <$fh> ) {
        $line =~ s/^\s+|\s+$//g;
        $live{$line} = 1 if $line =~ /^\d+$/;
    }
    close $fh;
    return \%live;
}

# _ps_state($pid)
# Returns the ps state letters for one pid on Unix (for example 'Z' for a
# zombie), or undef when ps cannot see the pid at all.
sub _ps_state {
    my ($pid) = @_;
    open my $fh, '-|', 'ps', '-o', 'stat=', '-p', $pid or return undef;
    my $state = <$fh>;
    close $fh;
    return undef if !defined $state;
    $state =~ s/^\s+|\s+$//g;
    return $state eq '' ? undef : $state;
}

my ( $_OPEN_PROCESS, $_GET_EXIT_CODE, $_GET_LAST_ERROR, $_CLOSE_HANDLE, $_GET_PROCESS_ID, $_WIN32_API_FAILED );

# _win32_api()
# Lazily imports the four kernel32 functions the OpenProcess probe needs,
# once, in the established product shape (Win32::API, 'Q' handles, packed
# 'L' out-params, $^E cleared before each call). Returns false when the
# import fails, so the OpenProcess phase degrades to a diagnostic instead
# of dying on a leg without Win32::API.
sub _win32_api {
    return 0 if $_WIN32_API_FAILED;
    return 1 if $_OPEN_PROCESS;
    my $ok = eval {
        require Win32::API;
        $_OPEN_PROCESS = Win32::API->new( 'kernel32', 'OpenProcess', 'NIN', 'Q' );
        die "OpenProcess import failed\n" if !defined $_OPEN_PROCESS;
        $_GET_EXIT_CODE = Win32::API->new( 'kernel32', 'GetExitCodeProcess', 'QP', 'I' );
        die "GetExitCodeProcess import failed\n" if !defined $_GET_EXIT_CODE;
        $_GET_LAST_ERROR = Win32::API->new( 'kernel32', 'GetLastError', '', 'N' );
        die "GetLastError import failed\n" if !defined $_GET_LAST_ERROR;
        $_CLOSE_HANDLE = Win32::API->new( 'kernel32', 'CloseHandle', 'Q', 'I' );
        die "CloseHandle import failed\n" if !defined $_CLOSE_HANDLE;
        $_GET_PROCESS_ID = Win32::API->new( 'kernel32', 'GetProcessId', 'Q', 'N' );
        die "GetProcessId import failed\n" if !defined $_GET_PROCESS_ID;
        1;
    };
    if ( !$ok ) {
        $_WIN32_API_FAILED = 1;
        diag("HEARTBEAT: Win32::API unavailable, OpenProcess phase degraded: $@");
        return 0;
    }
    return 1;
}

# _open_process_state($pid)
# Windows only. Opens the process and reads its exit code AND the real pid
# the handle refers to. Two separate traps live here, both proven by the
# read-only SSH probes on win-ts: OpenProcess rounds the requested pid
# down to a multiple of 4 (OpenProcess(3101) opens pid 3100, proven by
# GetProcessId on the handle in both Win32::API and exact .NET P/Invoke),
# so the handle must be verified to be the pid asked for; and a process
# object can linger after exit while some handle to it is still open
# (pid 3104: tasklist/WMI/.NET all say absent, yet OpenProcess succeeds
# with exit code 0), so STILL_ACTIVE must be checked too. Either check
# alone still misreports.
# Output: (opened boolean, real pid or undef, exit code or undef, Win32 last error).
sub _open_process_state {
    my ($pid) = @_;
    return ( undef, undef, undef, undef ) if !_win32_api();
    $^E = 0;
    my $handle = $_OPEN_PROCESS->Call( $QUERY_LIMITED_INFORMATION, 0, $pid );
    if ( !$handle ) {
        my $err = $_GET_LAST_ERROR->Call();
        return ( 0, undef, undef, $err );
    }
    my $real_pid = $_GET_PROCESS_ID->Call($handle);
    my $code_buf = pack 'L', 0;
    $^E = 0;
    my $ok = $_GET_EXIT_CODE->Call( $handle, $code_buf );
    my $code = $ok ? unpack( 'L', $code_buf ) : undef;
    $_CLOSE_HANDLE->Call($handle);
    return ( 1, $real_pid, $code, 0 );
}

# _probe_pid($pid, $live_before, $live_after)
# Probes one pid three ways in the same breath: kill(0) with its errno,
# the OpenProcess exit-code state on Windows, and live-set membership
# against two enumerations (before and after the probe loop). A pid in
# neither enumeration is definitely absent; a pid in exactly one is
# churned and excluded from the false-positive verdicts.
# Output: hash reference with the verdicts.
sub _probe_pid {
    my ( $pid, $live_before, $live_after ) = @_;
    my ( $alive, $errno_num, $errno_str, $winerr ) = _kill0($pid);
    my ( $opened, $real_pid, $code, $last_error ) = ( undef, undef, undef, undef );
    ( $opened, $real_pid, $code, $last_error ) = _open_process_state($pid) if $IS_WINDOWS;
    my $in_before = $live_before->{$pid} ? 1 : 0;
    my $in_after  = $live_after->{$pid}  ? 1 : 0;
    my $membership = ( $in_before && $in_after ) ? 'live' : ( !$in_before && !$in_after ) ? 'absent' : 'churned';
    return {
        pid         => $pid,
        kill0       => $alive,
        errno_num   => $errno_num,
        errno_str   => $errno_str,
        winerr      => $winerr,
        opened      => $opened,
        real_pid    => $real_pid,
        exit_code   => $code,
        last_error  => $last_error,
        membership  => $membership,
    };
}

# _running_via_open_process($probe)
# Whether the OpenProcess exit-code check calls this probe running: the
# handle opened AND it refers to exactly the pid asked for AND the exit
# code is STILL_ACTIVE. Both halves are required: without the real-pid
# check, OpenProcess(3101) reports the live pid 3100 as running; without
# the exit-code check, the lingering pid 3104 object reports as running.
sub _running_via_open_process {
    my ($probe) = @_;
    return 0 if !defined $probe->{opened} || !$probe->{opened};
    return 0 if !defined $probe->{real_pid} || $probe->{real_pid} != $probe->{pid};
    return 0 if !defined $probe->{exit_code};
    return $probe->{exit_code} == $STILL_ACTIVE ? 1 : 0;
}

# _nearest_live_distance($pid, $live)
# Distance from one pid to the closest live pid, for testing the
# neighbour hypothesis (the monitor's false positives sat just above
# live pids). Returns undef when the live set is empty.
sub _nearest_live_distance {
    my ( $pid, $live ) = @_;
    my $best;
    for my $live_pid ( keys %{$live} ) {
        my $dist = abs( $pid - $live_pid );
        $best = $dist if !defined $best || $dist < $best;
    }
    return $best;
}

diag('HEARTBEAT: phase A sanity controls starting');

# Phase A: sanity controls. kill(0) must at least agree with reality for
# pids whose state is known without enumeration.
my ( $self_alive, $self_errno, $self_str, $self_winerr ) = _kill0($$);
diag("HEARTBEAT: phase A kill(0, \$\$) alive=$self_alive errno=$self_errno/$self_str winerr=$self_winerr");
ok( $self_alive, 'kill(0) reports the current process alive' );

my ( $huge_alive, $huge_errno, $huge_str, $huge_winerr ) = _kill0(999_999_999);
diag("HEARTBEAT: phase A kill(0, 999999999) alive=$huge_alive errno=$huge_errno/$huge_str winerr=$huge_winerr");
ok( !$huge_alive, 'kill(0) reports a never-existent pid dead' );

my $control_pid = $IS_WINDOWS ? 1 : getppid();
my ( $control_alive, $control_errno, $control_str, $control_winerr ) = _kill0($control_pid);
diag("HEARTBEAT: phase A kill(0, $control_pid) alive=$control_alive errno=$control_errno/$control_str winerr=$control_winerr");
if ($IS_WINDOWS) {
    ok( !$control_alive, 'kill(0, 1) reports pid 1 dead on Windows (no such process exists there)' );
}
else {
    # Pid 1 is root-owned on the Jenkins nodes, so kill(0, 1) answers
    # false with EPERM there even though init exists: signal 0 conflates
    # "no such process" with "no permission to signal it". The parent
    # prove process is the same user and alive, so it is the correct
    # known-alive low control on Unix.
    ok( $control_alive, 'kill(0, parent) reports the parent process alive on Unix' );
}

diag('HEARTBEAT: phase A sanity controls done');

# Phase B: live-child control. A real spawned child that sleeps, probed
# while alive, then after it exits and is reaped. GoRoutine::spawn is the
# product's own spawn primitive; the child exits on its own, so no kill is
# ever needed and the control cannot hang the micro.
diag('HEARTBEAT: phase B live-child control starting');
my $sleeper = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', "sleep $SLEEPER_SECONDS" ], {} );
BAIL_OUT('GoRoutine::spawn failed for the live-child control') if !$sleeper;
diag("HEARTBEAT: phase B sleeper pid=$sleeper");
my ( $sleeper_alive ) = _kill0($sleeper);
my ( $sleeper_opened, $sleeper_real, $sleeper_code ) = $IS_WINDOWS ? _open_process_state($sleeper) : ( undef, undef, undef );
diag("HEARTBEAT: phase B sleeper alive kill0=$sleeper_alive opened="
        . ( defined $sleeper_opened ? $sleeper_opened : 'n/a' )
        . ' real_pid=' . ( defined $sleeper_real ? $sleeper_real : 'n/a' )
        . ' exit_code=' . ( defined $sleeper_code ? $sleeper_code : 'n/a' ) );
my $sleeper_alive_ok = $sleeper_alive
    && ( !$IS_WINDOWS
        || ( $sleeper_opened && defined $sleeper_real && $sleeper_real == $sleeper && defined $sleeper_code && $sleeper_code == $STILL_ACTIVE ) );
ok( $sleeper_alive_ok, 'live spawned child reports alive via kill(0) (and OpenProcess STILL_ACTIVE on Windows)' );

my $exited = 0;
for ( 1 .. $EXIT_POLL_LIMIT * 10 ) {
    if ( Developer::Dashboard::GoRoutine::process_exited($sleeper) ) {
        $exited = 1;
        last;
    }
    sleep 0.1;
}
diag("HEARTBEAT: phase B sleeper process_exited=$exited");
ok( $exited, 'live-child control exits on its own inside the poll bound' );
my $wait_status = Developer::Dashboard::GoRoutine::wait_process($sleeper);
diag("HEARTBEAT: phase B sleeper wait_process status=$wait_status");
my ( $sleeper_dead ) = _kill0($sleeper);
my ( $sleeper_reopened ) = $IS_WINDOWS ? _open_process_state($sleeper) : (undef);
diag("HEARTBEAT: phase B sleeper after reap kill0=$sleeper_dead reopened="
        . ( defined $sleeper_reopened ? $sleeper_reopened : 'n/a' ) );
my $sleeper_dead_ok = !$sleeper_dead && ( !$IS_WINDOWS || !$sleeper_reopened );
ok( $sleeper_dead_ok, 'reaped spawned child reports dead via kill(0) (and OpenProcess fails on Windows)' );

diag('HEARTBEAT: phase B live-child control done');

# Phase C: fixture-pid triple probe, three repeats with sleeps between.
# Each repeat enumerates the live set, probes every fixture pid, then
# enumerates again; only pids absent from both enumerations count towards
# the false-positive verdicts.
diag('HEARTBEAT: phase C fixture-pid triple probe starting');
my @repeat_results;
for my $repeat ( 1 .. $REPEAT_COUNT ) {
    diag("HEARTBEAT: phase C repeat $repeat starting");
    my $live_before = _live_pids();
    BAIL_OUT('live-pid enumeration failed') if !$live_before;
    my @probes = map { _probe_pid( $_, $live_before, $live_before ) } @FIXTURE_PIDS;
    my $live_after = _live_pids();
    BAIL_OUT('live-pid enumeration failed') if !$live_after;
    # Membership needs both enumerations: re-derive it now that the second
    # enumeration exists (the probes above were taken with a placeholder).
    for my $probe (@probes) {
        my $pid        = $probe->{pid};
        my $in_before  = $live_before->{$pid} ? 1 : 0;
        my $in_after   = $live_after->{$pid}  ? 1 : 0;
        $probe->{membership} = ( $in_before && $in_after ) ? 'live'
            : ( !$in_before && !$in_after ) ? 'absent' : 'churned';
    }
    my @kill0_fp = grep { $_->{kill0} && $_->{membership} eq 'absent' } @probes;
    my @open_fp  = grep { _running_via_open_process($_) && $_->{membership} eq 'absent' } @probes;
    my @churned  = grep { $_->{membership} eq 'churned' } @probes;
    diag( 'HEARTBEAT: phase C repeat ' . $repeat
            . ' kill0_fp=[' . join( ',', map { $_->{pid} } @kill0_fp ) . ']'
            . ' openprocess_fp=[' . join( ',', map { $_->{pid} } @open_fp ) . ']'
            . ' live_count=' . scalar( keys %{$live_before} )
            . ' churned=[' . join( ',', map { $_->{pid} } @churned ) . ']' );
    for my $probe (@kill0_fp) {
        diag( 'HEARTBEAT: phase C repeat ' . $repeat . ' kill(0) false positive pid=' . $probe->{pid}
                . ' errno=' . $probe->{errno_num} . '/' . $probe->{errno_str}
                . ' winerr=' . $probe->{winerr}
                . ' opened=' . ( defined $probe->{opened} ? $probe->{opened} : 'n/a' )
                . ' real_pid=' . ( defined $probe->{real_pid} ? $probe->{real_pid} : 'n/a' )
                . ' exit_code=' . ( defined $probe->{exit_code} ? $probe->{exit_code} : 'n/a' )
                . ' last_error=' . ( defined $probe->{last_error} ? $probe->{last_error} : 'n/a' ) );
    }
    push @repeat_results,
        { kill0_fp => \@kill0_fp, open_fp => \@open_fp, probes => \@probes, live_before => $live_before };
    diag("HEARTBEAT: phase C repeat $repeat done, sleeping ${REPEAT_SLEEP}s before the next repeat");
    sleep $REPEAT_SLEEP if $repeat < $REPEAT_COUNT;
}
diag('HEARTBEAT: phase C fixture-pid triple probe done');

# The OpenProcess verdict: the exit-code check must never call a
# definitely-absent pid running, on any repeat. On Unix the OpenProcess
# phase does not run, so the check is vacuously true there.
my $open_fp_total = 0;
$open_fp_total += scalar( @{ $_->{open_fp} } ) for @repeat_results;
if ($IS_WINDOWS) {
    is( $open_fp_total, 0,
        'OpenProcess running check never claims a definitely-absent fixture pid is running' );
}
else {
    ok( 1, 'OpenProcess phase skipped on Unix (OpenProcess running check is Windows-only)' );
}

# The kill(0) verdict: on Unix it must never claim a definitely-absent
# pid is alive. On Windows that is the defect under test, so the set is
# recorded in the test name instead of asserted.
my $kill0_fp_total = 0;
$kill0_fp_total += scalar( @{ $_->{kill0_fp} } ) for @repeat_results;
if ($IS_WINDOWS) {
    my @all_fp = map { $_->{pid} } map { @{ $_->{kill0_fp} } } @repeat_results;
    ok( 1, 'kill(0) false-positive fixture pids recorded for the fix decision: [' . join( ',', @all_fp ) . ']' );
}
else {
    is( $kill0_fp_total, 0, 'kill(0) never claims a definitely-absent fixture pid is alive on Unix' );
}

# Stability: every fixture pid must give the same kill(0) answer in all
# three repeats. A pid that flips is process churn moving the verdict,
# which the diagnostics above will show by repeat.
my $stable = 1;
for my $i ( 0 .. $#FIXTURE_PIDS ) {
    my $first = $repeat_results[0]->{probes}->[$i]->{kill0};
    for my $repeat (@repeat_results) {
        $stable = 0 if $repeat->{probes}->[$i]->{kill0} != $first;
    }
}
ok( $stable, 'kill(0) result is identical across all three repeats for every fixture pid' );

diag('HEARTBEAT: phase C verdicts done');

# Phase D: range scan. Same triple probe across 3000-3200 and 10000-10010,
# testing the monitor's neighbour hypothesis: every kill(0) false positive
# sits just above a live pid.
diag('HEARTBEAT: phase D range scan starting');
my $range_live_before = _live_pids();
BAIL_OUT('live-pid enumeration failed') if !$range_live_before;
my @range_pids = ( 3000 .. 3200, 10000 .. 10010 );
my @range_probes = map { _probe_pid( $_, $range_live_before, $range_live_before ) } @range_pids;
my $range_live_after = _live_pids();
BAIL_OUT('live-pid enumeration failed') if !$range_live_after;
for my $probe (@range_probes) {
    my $pid       = $probe->{pid};
    my $in_before = $range_live_before->{$pid} ? 1 : 0;
    my $in_after  = $range_live_after->{$pid}  ? 1 : 0;
    $probe->{membership} = ( $in_before && $in_after ) ? 'live'
        : ( !$in_before && !$in_after ) ? 'absent' : 'churned';
}
my @range_kill0_fp = grep { $_->{kill0} && $_->{membership} eq 'absent' } @range_probes;
my @range_open_fp  = grep { _running_via_open_process($_) && $_->{membership} eq 'absent' } @range_probes;
my @range_distances;
for my $probe (@range_kill0_fp) {
    my $dist = _nearest_live_distance( $probe->{pid}, $range_live_before );
    push @range_distances, $probe->{pid} . '=>' . ( defined $dist ? $dist : 'n/a' );
}
diag( 'HEARTBEAT: phase D range kill0_fp=[' . join( ',', map { $_->{pid} } @range_kill0_fp ) . ']'
        . ' openprocess_fp=[' . join( ',', map { $_->{pid} } @range_open_fp ) . ']'
        . ' nearest_live_distances={' . join( ' ', @range_distances ) . '}' );
for my $probe (@range_kill0_fp) {
    diag( 'HEARTBEAT: phase D range kill(0) false positive pid=' . $probe->{pid}
            . ' opened=' . ( defined $probe->{opened} ? $probe->{opened} : 'n/a' )
            . ' real_pid=' . ( defined $probe->{real_pid} ? $probe->{real_pid} : 'n/a' )
            . ' exit_code=' . ( defined $probe->{exit_code} ? $probe->{exit_code} : 'n/a' )
            . ' last_error=' . ( defined $probe->{last_error} ? $probe->{last_error} : 'n/a' ) );
}
diag('HEARTBEAT: phase D range scan done');

my $range_open_fp_total = scalar @range_open_fp;
if ($IS_WINDOWS) {
    is( $range_open_fp_total, 0,
        'OpenProcess running check never claims a definitely-absent range pid is running' );
}
else {
    ok( 1, 'OpenProcess phase skipped on Unix (OpenProcess running check is Windows-only)' );
}
ok( 1, 'kill(0) false-positive nearest-live distances recorded: {' . join( ' ', @range_distances ) . '}' );

diag('HEARTBEAT: phase D verdicts done');

# Phase E: exited-but-unreaped child. Spawn a child that exits at once and
# do NOT reap it: on Windows the GoRoutine registry keeps the process
# handle open until wait_process collects it, which is the documented
# shape that makes a completed child still "exist" until reaped; on Unix
# the child stays a zombie until reaped. Either way kill(0) must still
# report it alive while completion is provable another way (OpenProcess
# exit code on Windows, ps zombie state on Unix). That is the exact shape
# of the round-42 failure: _pid_is_running asked kill(0) and got "alive"
# for a pid whose process had already exited.
diag('HEARTBEAT: phase E exited-but-unreaped child starting');
my $quick = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'exit 0' ], {} );
BAIL_OUT('GoRoutine::spawn failed for the exited-child control') if !$quick;
sleep 0.5;
my ( $quick_alive, $quick_errno, $quick_str, $quick_winerr ) = _kill0($quick);
my ( $quick_opened, $quick_real, $quick_code ) = $IS_WINDOWS ? _open_process_state($quick) : ( undef, undef, undef );
my $quick_exited = Developer::Dashboard::GoRoutine::process_exited($quick);
my $quick_running = Developer::Dashboard::GoRoutine::process_running($quick);
my $quick_ps = $IS_WINDOWS ? undef : _ps_state($quick);
diag( 'HEARTBEAT: phase E unreaped child pid=' . $quick
        . ' kill0=' . $quick_alive
        . ' errno=' . $quick_errno . '/' . $quick_str . ' winerr=' . $quick_winerr
        . ' opened=' . ( defined $quick_opened ? $quick_opened : 'n/a' )
        . ' real_pid=' . ( defined $quick_real ? $quick_real : 'n/a' )
        . ' exit_code=' . ( defined $quick_code ? $quick_code : 'n/a' )
        . ' process_exited=' . $quick_exited
        . ' process_running=' . $quick_running
        . ' ps_state=' . ( defined $quick_ps ? $quick_ps : 'n/a' ) );
my $phase_e_ok;
if ($IS_WINDOWS) {
    $phase_e_ok = $quick_alive
        && $quick_opened
        && defined $quick_real
        && $quick_real == $quick
        && defined $quick_code
        && $quick_code != $STILL_ACTIVE;
}
else {
    $phase_e_ok = $quick_alive && defined $quick_ps && $quick_ps =~ /Z/;
}
ok( $phase_e_ok,
    'exited-but-unreaped child still reports alive via kill(0) while completion is provable another way' );

my $quick_wait = Developer::Dashboard::GoRoutine::wait_process($quick);
my ( $quick_dead ) = _kill0($quick);
my ( $quick_reopened ) = $IS_WINDOWS ? _open_process_state($quick) : (undef);
diag( 'HEARTBEAT: phase E after wait_process status=' . $quick_wait
        . ' kill0=' . $quick_dead
        . ' reopened=' . ( defined $quick_reopened ? $quick_reopened : 'n/a' ) );
diag('HEARTBEAT: phase E exited-but-unreaped child done');

done_testing();

__END__

=head1 NAME

t/997-micro-kill0-windows-misreport.t - probe the Windows kill(0) misreport behind the round-42 t/09 failure

=head1 PURPOSE

Prove, before any fix is chosen, why kill(0, 3101) reports alive on the
Windows node although no such process exists. Round 42 failed when the
t/09 test-209 block called the real stop_collectors with fake loop pids
3101/3102 and _ensure_collector_pid_stopped died with "Collector
'running.alpha' did not stop after TERM and KILL": _process_exists is a
bare kill(0, $pid), and on this Strawberry Perl kill(0) answers true for
pids that the Win32 process list does not contain. The micro scans
fixture and range pids with kill(0), an OpenProcess check (handle plus
GetProcessId identity plus GetExitCodeProcess), and a live-set
enumeration in the same breath, repeats the fixture scan three times
for stability, and reproduces the shape in miniature with a spawned
child that exits before it is reaped.

The mechanism, proven by read-only SSH probes on win-ts before this
micro was revised: Windows pids are multiples of 4, and OpenProcess
resolves a requested pid by rounding down to a multiple of 4, so
OpenProcess(3101) opens pid 3100 (ShellHost.exe, live) - proven by
GetProcessId on the returned handle in both Win32::API and exact .NET
P/Invoke, so the rounding is in OpenProcess itself, not in the Perl
marshalling. Perl's kill(0) on Windows is OpenProcess-based, so it
inherits the rounding. A second, separate trap: pid 3104 is an exited
process whose object lingers while some handle to it is still open
(exit code 0, yet tasklist, WMI, Get-Process and .NET all say absent),
so kill(0, 3104..3107) is also true. Either check alone still
misreports, so the OpenProcess check in this micro requires all three:
the handle opened, GetProcessId equal to the pid asked for, and the
exit code STILL_ACTIVE.

=head1 WHY IT EXISTS

The round-42 monitor reproduced the misreport three times across fifteen
minutes with read-only probes on win-ts and cross-checked it against a
full Win32_Process scan and Get-Process, but a hand probe is not a
verdict: the false-positive set, its stability, what $! and $^E say, and
whether an OpenProcess check (handle, GetProcessId identity, exit
code) agrees with the live set all need to be pinned by the same run
on all four legs. Without that, the fix choice (harden _process_exists
in the product, or change the t/09 fixture pids in the test) would be a
guess, and a guessed fix for a liveness check can turn a loud failure
into a silent wrong answer.

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/997-micro-kill0-windows-misreport.t)
to prove the mechanism on all four legs. Remove it in a cleanup commit
once the fix is verified, like every other micro. Never run it by hand
against a live box for a verdict: the solo is the evidence.

=head1 HOW TO USE

No setup: the micro enumerates the live pid set (tasklist on Windows,
ps elsewhere), probes the t/09 fixture pids and two ranges with kill(0)
plus OpenProcess/GetProcessId/GetExitCodeProcess on Windows, repeats
the fixture scan three times with sleeps, and runs two spawned-child
controls (a sleeper that exits on its own, and a child that exits
before it is reaped). The OUTCOME is in the HEARTBEAT diag lines: the
kill(0) false-positive set per repeat, the OpenProcess false-positive
set, the nearest-live distance of each false positive, and the $!/$^E
values. The assertions only pin what must hold for the fix to work
(the OpenProcess check - handle opened, GetProcessId equal to the pid
asked for, exit code STILL_ACTIVE - never calls a definitely-absent
pid running); the kill(0) false-positive set itself is recorded, not
asserted, on Windows.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a probe for the testing-v1
loop, written for round 42, and is removed once the kill(0) fix is
verified. The Jenkins solo runner is the only caller.

=head1 EXAMPLES

On a leg where kill(0) is reliable the file passes with twelve
assertions and empty false-positive sets. On the Windows node it passes
the same twelve while the HEARTBEAT lines name the false positives, for
example "kill(0) false positive pid=3101 errno=22/Invalid argument
winerr=87 opened=1 real_pid=3100 exit_code=259 last_error=0", which is
the whole mechanism in one line: the handle opens, GetProcessId shows
it is really pid 3100, the exit code is STILL_ACTIVE for that live
process, and kill(0) still answers alive for 3101.

=cut
