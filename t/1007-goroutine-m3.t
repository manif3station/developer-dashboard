#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use Test::More;

use lib File::Spec->catdir( $Bin, '..', 'lib' );
use Developer::Dashboard::GoRoutine qw(go share wait_all channel);

my $GR = 'Developer::Dashboard::GoRoutine';
my $CH = 'Developer::Dashboard::GoRoutine::Channel';
my $RT = 'Developer::Dashboard::GoRoutine::Routine';

# Pumps in bounded slices until $cond->() is true or $seconds pass.
# Returns true when the condition became true. Every wait in this file
# goes through here or wait_all() on routines that are guaranteed to
# finish, so a stuck engine fails a test instead of hanging the suite.
sub _pump_until {
    my ( $cond, $seconds ) = @_;
    my $deadline = time() + $seconds;
    while ( !$cond->() && time() < $deadline ) {
        Developer::Dashboard::GoRoutine::pump(0.05);
    }
    return $cond->() ? 1 : 0;
}

# ----------------------------------------------------------------------
# channel() validation (GoRoutine.pm lines 954-955)
# ----------------------------------------------------------------------
my $bad_cap = eval { channel(-1); 1 } ? '' : $@;
like( $bad_cap, qr/capacity must be a non-negative integer/,
    'channel(-1) dies with an explicit message' );
my $bad_cap2 = eval { channel('abc'); 1 } ? '' : $@;
like( $bad_cap2, qr/capacity must be a non-negative integer/,
    'channel("abc") dies with an explicit message' );
my $bad_cap3 = eval { channel(2.5); 1 } ? '' : $@;
like( $bad_cap3, qr/capacity must be a non-negative integer/,
    'channel(2.5) dies with an explicit message' );
my $ch0 = channel();
is( $ch0->capacity, 0, 'channel() with no argument is unbuffered' );
my $ch3 = channel(3);
is( $ch3->capacity, 3, 'channel(3) has capacity 3' );
my $ch0b = channel(0);
is( $ch0b->capacity, 0, 'channel(0) is unbuffered' );

# _check: an invalid channel handle dies explicitly.
my $fake_ch = bless {}, $CH;
my $bad_handle = eval { $fake_ch->send('x'); 1 } ? '' : $@;
like( $bad_handle, qr/invalid channel handle/,
    'send on a blessed hash with no queue dies' );
my $bad_handle2 = eval { $CH->send( 'notanobject', 'x' ); 1 } ? '' : $@;
like( $bad_handle2, qr/invalid channel handle/,
    'send on a non-reference dies' );

# ----------------------------------------------------------------------
# error() (lines 1235-1237): the error a failed routine died with.
# Perl appends " at FILE line N" to a die without a trailing newline,
# so the recorded string is never literally false -- but it IS always
# defined when the routine failed, and undef when it did not. That
# definedness is what _finish_routine checks (line 642), so that is
# what these tests pin.
# ----------------------------------------------------------------------
my $failed = go sub { die "boom\n"; };
wait_all();
is( $failed->status, 'failed', 'a routine that dies finishes failed' );
is( $failed->error, "boom\n", 'error() returns the exact die message' );
my $failed_zero = go sub { die 0; };
wait_all();
is( $failed_zero->status, 'failed', 'a routine that dies 0 finishes failed' );
ok( defined $failed_zero->error,
    'a routine that dies 0 still records a defined error' );
my $failed_empty = go sub { die ""; };
wait_all();
is( $failed_empty->status, 'failed', 'a routine that dies "" finishes failed' );
ok( defined $failed_empty->error,
    'a routine that dies "" still records a defined error' );
my $ok_routine = go sub { 1; };
wait_all();
is( $ok_routine->status, 'done', 'a routine that returns finishes done' );
is( $ok_routine->error, undef, 'a routine that did not fail has no error' );

# ----------------------------------------------------------------------
# go() validation (lines 714, 716)
# go() has the prototype (&;$), which refuses a scalar variable as the
# code argument at compile time, so the non-code die is only reachable
# through the & form, which bypasses the prototype. That is how the
# guard is exercised here.
# ----------------------------------------------------------------------
my $bad_go = eval { &Developer::Dashboard::GoRoutine::go("hello"); 1 } ? '' : $@;
like( $bad_go, qr/go\(\) expects a code reference/,
    'go() with a non-code reference dies' );
my $bad_opts = eval { go sub { 1 }, "notahash"; 1 } ? '' : $@;
like( $bad_opts, qr/go\(\) options must be a hash reference/,
    'go() with non-hash options dies' );

# ----------------------------------------------------------------------
# go() triggers: every, readable, writable, pid, invalid trigger
# (lines 740-743, 748-758)
# ----------------------------------------------------------------------
# every: a repeating timer runs the callback again and again, and the
# routine stays pending between runs instead of finishing done.
share my $every_runs = 0;
my $every = go sub { $every_runs++ }, { every => 0.05 };
ok( _pump_until( sub { $every_runs >= 2 }, 2 ),
    'an every routine runs more than once' );
is( $every->status, 'pending',
    'a repeating routine that completed normally goes back to pending' );
ok( $every->kill, 'a repeating routine can be killed' );
is( $every->status, 'killed', 'a killed repeating routine finishes killed' );

# readable: a pipe becomes readable when data is written to it.
# syswrite, not print: print buffers in Perl and the data may never
# reach the kernel pipe, so the fd would never become readable.
pipe( my $rd, my $wr ) or die "cannot pipe: $!";
share my $readable_ran = 0;
my $readable = go sub { $readable_ran = 1 }, { readable => $rd };
Developer::Dashboard::GoRoutine::pump(0.1);
is( $readable_ran, 0, 'a readable routine does not run while the fd is quiet' );
syswrite( $wr, "x\n" ) or die "cannot write to pipe: $!";
ok( _pump_until( sub { $readable_ran == 1 }, 2 ),
    'a readable routine runs when the fd becomes readable' );
is( $readable->status, 'done', 'a one-shot readable routine finishes done' );
$readable->kill if $readable->status eq 'pending';
close $wr or die "cannot close pipe write end: $!";
close $rd or die "cannot close pipe read end: $!";

# writable: a pipe write end is writable at once (its buffer is empty).
pipe( my $rd2, my $wr2 ) or die "cannot pipe: $!";
share my $writable_ran = 0;
my $writable = go sub { $writable_ran = 1 }, { writable => $wr2 };
ok( _pump_until( sub { $writable_ran == 1 }, 2 ),
    'a writable routine runs when the fd is writable' );
is( $writable->status, 'done', 'a one-shot writable routine finishes done' );
$writable->kill if $writable->status eq 'pending';
close $wr2 or die "cannot close pipe write end: $!";
close $rd2 or die "cannot close pipe read end: $!";

# repeat: an IO trigger with repeat stays registered and the routine
# stays pending after it fires. The callback must consume the
# readiness (read the byte), or the fd stays ready forever and the
# pump would keep re-dispatching the routine and never return: a
# repeat trigger on a permanently-ready fd starves the pump loop.
pipe( my $rd3, my $wr3 ) or die "cannot pipe: $!";
share my $repeat_runs = 0;
my $repeat = go sub {
    $repeat_runs++;
    sysread( $rd3, my $byte, 1 );
}, { readable => $rd3, repeat => 1 };
syswrite( $wr3, "a" ) or die "cannot write to pipe: $!";
ok( _pump_until( sub { $repeat_runs >= 1 }, 2 ),
    'a repeat IO routine runs' );
is( $repeat->status, 'pending',
    'a repeat IO routine stays pending after it fires' );
is( $repeat_runs, 1, 'a repeat IO routine runs once per byte written' );
syswrite( $wr3, "b" ) or die "cannot write to pipe: $!";
ok( _pump_until( sub { $repeat_runs >= 2 }, 2 ),
    'a repeat IO routine fires again when the fd is ready again' );
ok( $repeat->kill, 'a repeat IO routine can be killed' );
is( $repeat->status, 'killed', 'a killed repeat routine finishes killed' );
close $wr3 or die "cannot close pipe write end: $!";
close $rd3 or die "cannot close pipe read end: $!";

# an invalid trigger dies explicitly. The record is created before
# the trigger is validated, so a failed go() leaves a pending record
# with no triggers: it would hang every later wait_all() in the
# process. The record is cancelled here so the rest of the file can
# run; the dangling record itself is a product defect, reported
# separately, not fixed by the tests.
my $id_probe = go sub { 1 };
my $bad_id = $id_probe->{id} + 1;
ok( $id_probe->kill, 'a probe routine can be killed to learn the next id' );
my $bad_trigger = eval { go sub { 1 }, { readable => 'abc' }; 1 } ? '' : $@;
like( $bad_trigger, qr/needs a filehandle or a file descriptor/,
    'a readable trigger that is not a handle or fd dies' );
is( Developer::Dashboard::GoRoutine::_cancel_routine( $bad_id, 'killed' ), 1,
    'the pending record left by a failed go() can be cancelled' );

# pid: the routine runs when the child exits. A lone pid trigger is
# only checked when the wait is bounded (by a pump timeout or another
# trigger): with nothing else registered, go_ev_wait sleeps up to an
# hour before it looks at the pid again, so wait_all() on a lone pid
# trigger would hang. Bounded pumps are the working shape, and the
# test uses them. The child sleeps 0.2s so it is still running when
# the trigger is registered.
my $dir = tempdir( CLEANUP => 1 );
my $pid_child = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'select undef, undef, undef, 0.2; exit 5;' ], {} );
ok( $pid_child > 0, 'spawn returns a positive pid for the pid trigger' );
share my $pid_ran = 0;
my $pid_routine = go sub { $pid_ran = 1 }, { pid => $pid_child };
ok( _pump_until( sub { $pid_ran == 1 }, 5 ),
    'a pid routine runs when the child exits' );
is( $pid_routine->status, 'done', 'a pid routine finishes done' );
$pid_routine->kill if $pid_routine->status eq 'pending';
is( Developer::Dashboard::GoRoutine::wait_process($pid_child), 5,
    'the pid trigger child exits 5' );

# ----------------------------------------------------------------------
# _dispatch_routine (line 773): a due id for a routine that is no
# longer pending is ignored.
# ----------------------------------------------------------------------
my $done_id = $ok_routine->{id};
is( Developer::Dashboard::GoRoutine::_dispatch_routine($done_id), 0,
    'dispatching a finished routine returns 0' );
is( Developer::Dashboard::GoRoutine::_dispatch_routine(999999), 0,
    'dispatching an unknown id returns 0' );

# ----------------------------------------------------------------------
# _finish_routine via kill while running, and exit() in a callback
# (lines 779-780, 790)
# ----------------------------------------------------------------------
my $kill_inside;
$kill_inside = go sub { $kill_inside->kill; };
wait_all();
is( $kill_inside->status, 'killed',
    'a routine that kills itself while running finishes killed' );
is( $kill_inside->cancel_requested, 1,
    'a routine killed while running records the cancel request' );
is( $kill_inside->is_killed, 1, 'a killed routine reports is_killed' );

my $exited = go sub { exit(3); };
wait_all();
is( $exited->status, 'exited', 'a routine that calls exit() finishes exited' );
is( $exited->is_killed, 0, 'an exited routine is not killed' );

# ----------------------------------------------------------------------
# _is_finished_state (line 622): every finished state, plus pending.
# Killing a finished routine returns 0; killing a pending one returns 1.
# _cancel_routine calls _is_finished_state on each, so driving all five
# states through kill() covers the condition.
# ----------------------------------------------------------------------
my $done_h = go sub { 1; };
wait_all();
is( $done_h->kill, 0, 'killing a done routine returns 0' );
my $killed_h = go sub { 1; }, { after => 10 };
Developer::Dashboard::GoRoutine::pump(0.05);
is( $killed_h->kill, 1, 'killing a pending routine returns 1' );
is( $killed_h->status, 'killed', 'the killed routine finishes killed' );
is( $killed_h->kill, 0, 'killing a killed routine returns 0' );
my $timed_h = go sub { 1; }, { after => 10 };
$timed_h->timeout(0.05);
Developer::Dashboard::GoRoutine::pump(0.5);
is( $timed_h->status, 'timed_out', 'a routine with a short timeout times out' );
is( $timed_h->kill, 0, 'killing a timed_out routine returns 0' );
is( $timed_h->is_killed, 1, 'a timed_out routine reports is_killed' );
my $exited_h = go sub { exit(0); };
wait_all();
is( $exited_h->status, 'exited', 'an exited routine is finished' );
is( $exited_h->kill, 0, 'killing an exited routine returns 0' );
my $failed_h = go sub { die "fail\n"; };
wait_all();
is( $failed_h->status, 'failed', 'a failed routine is finished' );
is( $failed_h->kill, 0, 'killing a failed routine returns 0' );

# _cancel_routine with no record at all (line 655).
is( Developer::Dashboard::GoRoutine::_cancel_routine( 999999, 'killed' ), 0,
    'cancelling an unknown routine returns 0' );

# _set_routine_timeout with no record (line 676), and on a finished
# routine (line 677).
is( Developer::Dashboard::GoRoutine::_set_routine_timeout( 999999, 5 ), undef,
    'setting a timeout on an unknown routine returns undef' );
my $finished_timeout = go sub { 1; };
wait_all();
is( $finished_timeout->timeout(5), $finished_timeout,
    'setting a timeout on a finished routine still returns the handle' );
is( $finished_timeout->status, 'done',
    'a finished routine stays done after a timeout is set on it' );
# timeout(0) clears a timeout: a routine given a short timeout and
# then cleared runs to completion instead of timing out.
my $cleared = go sub { 1; }, { after => 0.3 };
$cleared->timeout(0.05);
$cleared->timeout(0);
Developer::Dashboard::GoRoutine::pump(0.5);
is( $cleared->status, 'done',
    'a routine whose timeout was cleared runs to completion' );

# ----------------------------------------------------------------------
# Spawn wrappers under a localised $^O (lines 69-100, 109-132, 148-151)
# The module documents $^O localisation as the designed test hook
# (lines 52-58): the registry keep/check key off runtime $^O, so a
# test can exercise the Windows branches on POSIX. The Win32::Process
# block itself (lines 89-96) cannot run here -- require Win32::Process
# fails on POSIX -- and is out of scope by Ryan's R134 ruling, as are
# the _wait_process_wrapper lines that key off the load-time platform
# (lines 172-183).
# ----------------------------------------------------------------------
# _keep_spawn_handle: undef and 0 are refused at the guard (line 71).
is( Developer::Dashboard::GoRoutine::_keep_spawn_handle(undef), undef,
    '_keep_spawn_handle(undef) returns without recording' );
is( Developer::Dashboard::GoRoutine::is_spawn_child(undef), 0,
    'an undefined pid is not a spawn child' );
is( Developer::Dashboard::GoRoutine::_keep_spawn_handle(0), undef,
    '_keep_spawn_handle(0) returns without recording' );
is( Developer::Dashboard::GoRoutine::is_spawn_child(0), 0,
    'pid 0 is not a spawn child' );
is( Developer::Dashboard::GoRoutine::is_spawn_child('abc'), 0,
    'a non-numeric pid is not a spawn child' );

# Without localisation a valid pid is refused at the $^O gate (line 75).
my $plain_child = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'select undef, undef, undef, 0.5; exit 0;' ], {} );
Developer::Dashboard::GoRoutine::_keep_spawn_handle($plain_child);
is( Developer::Dashboard::GoRoutine::is_spawn_child($plain_child), 0,
    'a pid is not recorded when $^O is not Windows' );
# With $^O localised the registry path runs (lines 75-77, 98-99): the
# pid is recorded with the fallback handle 1, because Win32::Process
# cannot load on POSIX and $opened stays undef.
{
    local $^O = 'MSWin32';
    Developer::Dashboard::GoRoutine::_keep_spawn_handle($plain_child);
}
is( Developer::Dashboard::GoRoutine::is_spawn_child($plain_child), 1,
    'a pid is recorded when $^O is localised to Windows' );
# _process_running_wrapper returns 1 for a registered pid (line 151).
{
    local $^O = 'MSWin32';
    is( Developer::Dashboard::GoRoutine::_process_running_wrapper($plain_child), 1,
        'a registered pid reports running under localised $^O' );
}
is( Developer::Dashboard::GoRoutine::wait_process($plain_child), 0,
    'the registered child is collected' );
is( Developer::Dashboard::GoRoutine::is_spawn_child($plain_child), 0,
    'a collected pid leaves the registry' );
# _process_running_wrapper falls through to the native check for a
# pid that was never registered: a reaped child reports not running.
{
    local $^O = 'MSWin32';
    is( Developer::Dashboard::GoRoutine::_process_running_wrapper($plain_child), 0,
        'an unregistered reaped pid falls through to the native check' );
}

# reap_child: the guard, the unregistered case, the not-exited case,
# and the reaped case (lines 194-201).
is( Developer::Dashboard::GoRoutine::reap_child(undef), 0,
    'reap_child(undef) returns 0' );
is( Developer::Dashboard::GoRoutine::reap_child(0), 0,
    'reap_child(0) returns 0' );
is( Developer::Dashboard::GoRoutine::reap_child('abc'), 0,
    'reap_child("abc") returns 0' );
my $reap_child = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'select undef, undef, undef, 0.3; exit 0;' ], {} );
is( Developer::Dashboard::GoRoutine::reap_child($reap_child), 0,
    'reap_child on an unregistered pid returns 0' );
{
    local $^O = 'MSWin32';
    Developer::Dashboard::GoRoutine::_keep_spawn_handle($reap_child);
}
is( Developer::Dashboard::GoRoutine::reap_child($reap_child), 0,
    'reap_child on a registered but running child returns 0' );
ok( _pump_until(
        sub { Developer::Dashboard::GoRoutine::process_exited($reap_child) }, 5 ),
    'the registered child exits' );
is( Developer::Dashboard::GoRoutine::reap_child($reap_child), 1,
    'reap_child on a registered exited child returns 1' );
is( Developer::Dashboard::GoRoutine::is_spawn_child($reap_child), 0,
    'a reaped child leaves the registry' );
is( Developer::Dashboard::GoRoutine::reap_any_exited(), 0,
    'reap_any_exited returns 0 with an empty registry' );

# _spawn_wrapper with an env override under localised $^O (lines
# 112-132): the overrides are merged into the parent environment for
# the spawn, and the child sees them alongside inherited values.
# The wrapper is called directly for the branch under test.
my $env_out = File::Spec->catfile( $dir, 'env-child.txt' );
my $env_err = File::Spec->catfile( $dir, 'env-child.err' );
my $wrapped_child;
{
    local $^O = 'MSWin32';
    local $ENV{M3_INHERITED} = 'inherited-value';
    $wrapped_child = Developer::Dashboard::GoRoutine::_spawn_wrapper(
        [ $^X, '-e', 'print join q{|}, @ENV{qw(M3_INHERITED M3_OVERRIDE)};' ],
        {
            cwd    => $dir,
            stdout => $env_out,
            stderr => $env_err,
            env    => { M3_OVERRIDE => 'override-value' },
        },
    );
}
is( Developer::Dashboard::GoRoutine::wait_process($wrapped_child), 0,
    'the wrapped env child exits 0' );
open my $env_fh, '<', $env_out or die "cannot read env child output: $!";
is( scalar(<$env_fh>), 'inherited-value|override-value',
    'the wrapped child sees the inherited value and the override' );
close $env_fh or die "cannot close env child output: $!";

# _spawn_wrapper env validation dies (lines 119-124). Each die is
# inside the localised-$^O env branch, so no child is ever spawned.
{
    local $^O = 'MSWin32';
    my $empty_key = eval {
        Developer::Dashboard::GoRoutine::_spawn_wrapper(
            [ $^X, '-e', 'exit 0;' ], { env => { '' => 'x' } } );
        1;
    } ? '' : $@;
    like( $empty_key, qr/environment keys must be non-empty/,
        'an empty env key dies' );
    my $eq_key = eval {
        Developer::Dashboard::GoRoutine::_spawn_wrapper(
            [ $^X, '-e', 'exit 0;' ], { env => { 'A=B' => 'x' } } );
        1;
    } ? '' : $@;
    like( $eq_key, qr/environment keys must be non-empty/,
        'an env key containing = dies' );
    my $nul_key = eval {
        Developer::Dashboard::GoRoutine::_spawn_wrapper(
            [ $^X, '-e', 'exit 0;' ], { env => { "A\0B" => 'x' } } );
        1;
    } ? '' : $@;
    like( $nul_key, qr/environment keys must be non-empty/,
        'an env key containing NUL dies' );
    my $undef_val = eval {
        Developer::Dashboard::GoRoutine::_spawn_wrapper(
            [ $^X, '-e', 'exit 0;' ], { env => { A => undef } } );
        1;
    } ? '' : $@;
    like( $undef_val, qr/environment values must be defined scalars/,
        'an undefined env value dies' );
    my $ref_val = eval {
        Developer::Dashboard::GoRoutine::_spawn_wrapper(
            [ $^X, '-e', 'exit 0;' ], { env => { A => [] } } );
        1;
    } ? '' : $@;
    like( $ref_val, qr/environment values must be defined scalars/,
        'a reference env value dies' );
    my $nul_val = eval {
        Developer::Dashboard::GoRoutine::_spawn_wrapper(
            [ $^X, '-e', 'exit 0;' ], { env => { A => "x\0y" } } );
        1;
    } ? '' : $@;
    like( $nul_val, qr/environment values must not contain NUL/,
        'an env value containing NUL dies' );
}

# ----------------------------------------------------------------------
# Channels: send and receive paths (lines 1023-1052, 1088-1158)
# ----------------------------------------------------------------------
# A buffered value is taken from the queue at once (the fast path).
my $buf = channel(2);
$buf->send('first');
$buf->send('second');
is( $buf->size, 2, 'two buffered sends fill the buffer' );
my ( $first, $first_ok ) = $buf->receive;
is_deeply( [ $first, $first_ok ], [ 'first', 1 ],
    'buffered receive preserves FIFO values and open status' );
is( $buf->size, 1, 'one buffered value remains after a receive' );

# A sender parked in sender_queue is taken at once by a receiver
# routine (lines 1100-1104): the main thread sends, the pump inside
# send() dispatches the receiver, and the receiver takes the value
# straight from sender_queue.
share my $parked_got = '';
my $parked_ch = channel();
my $parked_receiver = go sub { $parked_got = $parked_ch->receive; };
$parked_ch->send('parked');
wait_all();
is( $parked_got, 'parked', 'a receiver takes a parked sender value' );
is( $parked_receiver->status, 'done', 'the receiver finishes done' );

# The receiver_waiting fast path (lines 1037-1040): the receiver yields
# first, then the main thread sends, and the value goes straight onto
# the queue and wakes the waiter.
share my $fast_got = '';
my $fast_ch = channel();
my $fast_receiver = go sub { $fast_got = $fast_ch->receive; };
Developer::Dashboard::GoRoutine::pump(0.1);
is( $fast_receiver->status, 'pending',
    'the receiver is pending after it yields' );
$fast_ch->send('fast');
wait_all();
is( $fast_got, 'fast', 'the fast-path send reaches the yielded receiver' );
is( $fast_receiver->status, 'done', 'the fast-path receiver finishes done' );

# _wake_waiter skips a waiter that was killed while it waited (lines
# 1067-1071): the value parks in the queue, the flag is cleared, and a
# later receive takes the parked value.
share my $killed_waiter_got = '';
my $kw_ch = channel();
my $kw_receiver = go sub { $killed_waiter_got = $kw_ch->receive; };
Developer::Dashboard::GoRoutine::pump(0.1);
is( $kw_receiver->status, 'pending', 'the waiter is pending' );
ok( $kw_receiver->kill, 'the waiting receiver can be killed' );
is( $kw_receiver->status, 'killed', 'the waiting receiver finishes killed' );
$kw_ch->send('after-kill');
is( $kw_ch->size, 1, 'the send parks the value when its waiter is dead' );
my $kw_v = $kw_ch->receive;
is( $kw_v, 'after-kill', 'a later receive takes the parked value' );

# close() wakes a yielded receiver (lines 1151-1153): the waiter is
# re-dispatched and sees the channel is closed.
share my $close_got = 'not-set';
share my $close_ok = 2;
my $close_ch = channel();
my $close_receiver = go sub {
    my ( $v, $ok ) = $close_ch->receive;
    $close_got = $v;
    $close_ok = $ok;
};
Developer::Dashboard::GoRoutine::pump(0.1);
is( $close_receiver->status, 'pending', 'the close waiter is pending' );
$close_ch->close;
ok( $close_ch->is_closed, 'close marks the channel closed' );
wait_all();
is( $close_got, undef, 'a woken receiver gets undef from a closed channel' );
is( $close_ok, 0, 'a woken receiver gets closed status 0' );
is( $close_receiver->status, 'done', 'the woken receiver finishes done' );

# The main-thread receive loop (lines 1124-1139): a value sent by a
# timer routine arrives through the queue branch.
my $loop_ch = channel();
my $loop_sender = go sub { $loop_ch->send('from-timer'); }, { after => 0.05 };
my $loop_v = $loop_ch->receive;
is( $loop_v, 'from-timer', 'a main-thread receive takes a timer-sent value' );
is( $loop_sender->status, 'done', 'the timer sender finishes done' );

# The main-thread receive loop closed branch (line 1139): a timer
# routine closes the channel while the main thread waits.
my $loop_close_ch = channel();
my $loop_closer = go sub { $loop_close_ch->close; }, { after => 0.05 };
my ( $lc_v, $lc_ok ) = $loop_close_ch->receive;
is( $lc_v, undef, 'a main-thread receive on a closed channel gets undef' );
is( $lc_ok, 0, 'a main-thread receive on a closed channel gets status 0' );
is( $loop_closer->status, 'done', 'the timer closer finishes done' );

# A buffered send that blocks on a full buffer dies when the channel
# is closed while it waits (line 1031).
my $full_ch = channel(1);
$full_ch->send('fills-it');
my $full_closer = go sub { $full_ch->close; }, { after => 0.05 };
my $full_err = eval { $full_ch->send('blocked'); 1 } ? '' : $@;
like( $full_err, qr/send on closed channel/,
    'a blocked buffered send dies when the channel closes' );
is( $full_closer->status, 'done', 'the full-buffer closer finishes done' );

# An unbuffered send that blocks in sender_queue dies when the channel
# is closed while it waits (line 1050).
my $uq_ch = channel();
my $uq_sender = go sub { $uq_ch->send('queued'); };
my $uq_closer = go sub { $uq_ch->close; }, { after => 0.05 };
wait_all();
is( $uq_sender->status, 'failed', 'a blocked unbuffered send fails on close' );
like( $uq_sender->error // '', qr/send on closed channel/,
    'the blocked unbuffered send reports the closed channel' );
is( $uq_closer->status, 'done', 'the sender-queue closer finishes done' );

# Sending on a closed channel dies at once (both capacities).
my $closed_ch = channel();
$closed_ch->close;
my $closed_err = eval { $closed_ch->send('too-late'); 1 } ? '' : $@;
like( $closed_err, qr/send on closed channel/, 'send on a closed channel dies' );
my $closed_buf = channel(1);
$closed_buf->close;
my $closed_buf_err = eval { $closed_buf->send('too-late'); 1 } ? '' : $@;
like( $closed_buf_err, qr/send on closed channel/,
    'send on a closed buffered channel dies' );
my ( $closed_v, $closed_ok ) = $closed_ch->receive;
is_deeply( [ $closed_v, $closed_ok ], [ undef, 0 ],
    'receive from a closed drained channel reports closed state' );
is( $closed_ch->receive, undef,
    'scalar receive from a closed drained channel returns undef' );

# ----------------------------------------------------------------------
# pump() paths (lines 822, 830, 845-846, 884-897, 912-920)
# ----------------------------------------------------------------------
# pump() with a negative timeout clamps to zero and returns at once.
my $t0 = time();
my $neg_progress = Developer::Dashboard::GoRoutine::pump(-1);
ok( time() - $t0 < 1, 'pump(-1) returns promptly' );
is( $neg_progress, 0, 'pump(-1) with nothing due reports no progress' );

# A routine timeout bounds the pump wait (lines 845-846): the pump
# returns after the routine timeout, not after the caller's bound.
my $bound_h = go sub { 1; }, { after => 10 };
$bound_h->timeout(0.05);
my $bt0 = time();
my $bound_progress = Developer::Dashboard::GoRoutine::pump(10);
my $bound_elapsed = time() - $bt0;
ok( $bound_elapsed < 1, 'a routine timeout bounds the pump wait' );
ok( $bound_progress >= 1, 'the bounded pump reports progress' );
is( $bound_h->status, 'timed_out', 'the bounded routine times out' );

# A Perl-side timeout on a pending routine (lines 912, 914).
my $perl_timeout = go sub { 1; }, { after => 10 };
$perl_timeout->timeout(0.05);
Developer::Dashboard::GoRoutine::pump(0.5);
is( $perl_timeout->status, 'timed_out',
    'a pending routine with a short timeout times out' );

# A Perl-side timeout on a running routine (lines 919-920): the
# callback sets its own timeout and pumps, and the nested pump sees
# it running past its deadline.
my $nested_timeout;
$nested_timeout = go sub {
    $nested_timeout->timeout(0.02);
    Developer::Dashboard::GoRoutine::pump(0.5);
};
wait_all();
is( $nested_timeout->status, 'timed_out',
    'a running routine past its timeout finishes timed_out' );
is( $nested_timeout->is_killed, 1,
    'a timed_out routine reports is_killed' );

# An engine timeout trigger (negative id) on a pending routine (lines
# 888-893): a timeout-kind timer is registered directly with the
# engine, because go() never registers one. The routine's fire timer
# is in the future, so the timeout timer is the one that fires.
my $eng_pending = go sub { 1; }, { after => 10 };
Developer::Dashboard::GoRoutine::_ev_add_timer(
    $eng_pending->{id}, Developer::Dashboard::GoRoutine::_ev_now(), 0, 1 );
Developer::Dashboard::GoRoutine::pump(0.5);
is( $eng_pending->status, 'timed_out',
    'an engine timeout trigger times out a pending routine' );

# An engine timeout trigger on a running routine (lines 896-897): the
# callback registers a timeout timer for its own id and pumps.
my $eng_running;
$eng_running = go sub {
    Developer::Dashboard::GoRoutine::_ev_add_timer(
        $eng_running->{id}, Developer::Dashboard::GoRoutine::_ev_now(), 0, 1 );
    Developer::Dashboard::GoRoutine::pump(0.5);
};
wait_all();
is( $eng_running->status, 'timed_out',
    'an engine timeout trigger times out a running routine' );
is( $eng_running->cancel_requested, 1,
    'a running routine timed out by the engine records the request' );

# An engine timeout trigger for an unknown id is skipped (line 890).
Developer::Dashboard::GoRoutine::_ev_add_timer(
    999999, Developer::Dashboard::GoRoutine::_ev_now(), 0, 1 );
my $bogus_progress = Developer::Dashboard::GoRoutine::pump(0.5);
ok( $bogus_progress >= 1, 'a timeout trigger for an unknown id is skipped' );

# The pump recursion guard (line 822): a chain of one-shot routines
# that each pump once nests pump() calls until the guard fires. The
# failing routines report the recursion error; the rest finish done.
# "Deep recursion" warnings are expected from the chain, so they are
# silenced for this block only.
share my $chain_ran = 0;
my @chain;
{
    no warnings 'recursion';
    for ( 1 .. 105 ) {
        push @chain, go sub {
            $chain_ran++;
            Developer::Dashboard::GoRoutine::pump(0);
        };
    }
    Developer::Dashboard::GoRoutine::pump(2);
}
is( $chain_ran, 105, 'every routine in the pump chain ran' );
my @chain_failed = grep { $_->status eq 'failed' } @chain;
ok( @chain_failed >= 1, 'at least one routine in the chain failed' );
like( $chain_failed[0]->error // '', qr/pump recursion too deep/,
    'the failing routine reports the recursion guard' );
my @chain_pending = grep { $_->status eq 'pending' } @chain;
is( scalar(@chain_pending), 0, 'no routine in the chain is left pending' );

# ----------------------------------------------------------------------
# _rec, DESTROY, age (lines 1189-1191, 1203, 1258-1260)
# ----------------------------------------------------------------------
my $fake_no_id = bless {}, $RT;
my $rec_no_id = eval { $fake_no_id->status; 1 } ? '' : $@;
like( $rec_no_id, qr/invalid go routine handle/,
    'a handle with no id dies on use' );
my $fake_bogus = bless { id => 999999 }, $RT;
my $rec_bogus = eval { $fake_bogus->status; 1 } ? '' : $@;
like( $rec_bogus, qr/invalid go routine handle/,
    'a handle with an unknown id dies on use' );

# DESTROY on a handle with no record (line 694) and on a handle with
# no id at all (line 1260) both return quietly.
undef $fake_bogus;
undef $fake_no_id;
ok( 1, 'destroying handles with no record does not die' );

# A finished routine's record is dropped once its handle is gone.
my $drop_h = go sub { 1; };
my $drop_id = $drop_h->{id};
wait_all();
is( $drop_h->status, 'done', 'the drop routine finishes done' );
undef $drop_h;
is( Developer::Dashboard::GoRoutine::_routine_record($drop_id), undef,
    'the record is dropped once a finished routine loses its handle' );

# age(): a finished routine ages from its finished time, a pending
# routine from now (line 1203, both sides of the //).
my $age_done = go sub { 1; };
wait_all();
ok( $age_done->age >= 0, 'a finished routine has a non-negative age' );
my $age_pending = go sub { 1; }, { after => 10 };
ok( $age_pending->age >= 0, 'a pending routine has a non-negative age' );
ok( $age_pending->kill, 'the age probe routine can be killed' );

# is_running: true inside the callback, false outside it.
share my $inside_running = 0;
my $run_h;
$run_h = go sub { $inside_running = $run_h->is_running; };
wait_all();
is( $inside_running, 1, 'a routine reports running inside its callback' );
is( $run_h->is_running, 0, 'a finished routine reports not running' );

# ----------------------------------------------------------------------
# The fork guard (line 976): a forked child returns from the END
# block at once instead of draining the parent's queue.
# ----------------------------------------------------------------------
my $fork_pid = fork();
if ( !defined $fork_pid ) {
    fail('fork failed for the END block probe');
}
elsif ( $fork_pid == 0 ) {
    exit(0);
}
else {
    waitpid( $fork_pid, 0 );
    is( $? >> 8, 0, 'a forked child exits cleanly' );
}

done_testing();

# ----------------------------------------------------------------------
# END-block drain (lines 979-981, 994-1002). These two routines are
# created AFTER done_testing, so they cannot affect any test above.
# The repeating one is cancelled by the END block before it can run;
# the finite one fires during the drain and finishes, so the process
# exits promptly. Both callbacks are no-ops and print nothing, so the
# TAP stream stays clean.
# ----------------------------------------------------------------------
my $end_repeating = go sub { 1; }, { every => 0.05 };
my $end_finite = go sub { 1; }, { after => 0.05 };

__END__

=head1 NAME

t/1007-goroutine-m3.t - M3 GoRoutine coverage tests

=head1 PURPOSE

Covers the GoRoutine.pm remainder from the R83 coverage programme:
the engine core (receive, pump, channel, send, go triggers), the
spawn wrappers under a localised $^O, the error sub, and the small
accessors. Written first, before any implementation change, as the
M3 milestone requires.

=head1 WHY IT EXISTS

Cover build #12 measured GoRoutine.pm at stmt 81.8, branch 66.1,
cond 58.6, sub 96.7, total 74.8. The uncovered lines cluster in the
engine core: receive, pump, channel, send and go, plus the spawn
wrappers and the error sub. The existing goroutine tests that drive
those paths run in the native-thread suite, which contributes no
coverage, so the paths stayed uncovered. This file drives them in
the instrumented suite instead.

=head1 WHEN TO USE

Run this file whenever GoRoutine.pm changes. It is part of the normal
suite, not a probe: if it fails, a GoRoutine behaviour regressed.

=head1 HOW TO USE

    prove -v t/1007-goroutine-m3.t

Every wait goes through _pump_until or wait_all() on routines that
are guaranteed to finish, so a stuck engine fails a test instead of
hanging the suite. Two shapes need care: a lone pid trigger is only
checked when the wait is bounded, so the pid test uses bounded
pumps, never wait_all(); and pump() and spawn() are not methods, so
they are always called fully qualified -- the method form passes the
package name as the first argument and breaks.

=head1 WHAT USES IT

Nothing calls this file directly. It guards
lib/Developer/Dashboard/GoRoutine.pm (the engine core, the spawn
wrappers, the error sub, and the small accessors) and GoRoutineEvent.h
(the engine timeout trigger, driven through _ev_add_timer with kind 1).

=head1 EXAMPLES

A routine that dies records its error, and a routine that does not
fail has none:

    my $bad = go sub { die "boom\n"; };
    wait_all();
    is( $bad->error, "boom\n" );

A pid trigger fires when the child exits, driven with bounded pumps:

    my $child = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-e', 'exit 5;' ], {} );
    my $r = go sub { 1 }, { pid => $child };
    _pump_until( sub { $r->status eq 'done' }, 5 );

=cut
