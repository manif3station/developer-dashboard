#!/usr/bin/env perl

# M5 (R163): StreamDrain + Watch coverage tests.
#
# Written first, before any implementation change, as the M5 milestone
# requires. Cover build #16 measured StreamDrain.pm at stmt 46.0,
# branch 26.4, cond 25.0, sub 85.7, total 41.0 and Watch.pm at stmt
# 87.1, branch 84.0, cond 91.9, sub 90.6, total 87.0. Both gaps are
# Windows paths never taken on the ARM64 cover run: StreamDrain's whole
# _drain_child_streams_windows sub (never called) and Watch's Windows
# readable path (line 158 true side 0 times in 769 calls).
#
# THE MOCK. The Win32 primitives do not exist on Unix, so this file
# installs fake Win32::API and Win32API::File modules on non-Windows
# (runtime typeglob assignments, never on MSWin32, where the real
# primitives run against real pipes in the Jenkins proof). The fake
# PeekNamedPipe is an honest model, not canned answers: it reports the
# true byte count via FIONREAD, reports a pipe broken once its writer
# closed and its bytes are drained (poll says readable, FIONREAD says
# zero), and reports zero while a pipe is quiet. Every drain assertion
# below therefore pins real behaviour against real pipes carrying real
# data. Two deliberate exceptions, both documented where they are
# used: the EINTR test arms a one-shot lie (the peek reports five
# bytes on an empty pipe, so the read blocks and the alarm interrupts
# it for real), and the import-failure test makes Win32::API->new
# return undef.
#
# ORDER MATTERS. Watch caches a failed PeekNamedPipe import in
# $_WINDOWS_PEEK_FAILED and never retries, and caches a successful
# import in $_WINDOWS_PEEK. Both are lexical, so the test cannot reset
# them. The import-failure test therefore runs in a SPAWNED CHILD
# (GoRoutine's native process API, R169: t/246 forbids a direct
# fork() in t/), first, before the parent ever calls
# _windows_peek_named_pipe; the child poisons only its own copy.
# Every later test uses the one consistent mock, whose Call reads
# live state.
#
# WRITE WITH SYSWRITE. A print to a pipe handle buffers: the bytes sit
# in Perl's output buffer and never reach the pipe until the handle is
# flushed or closed, so a peek taken before that sees an empty pipe
# and a sysread on it blocks forever. The first probe of this file
# hung exactly that way. Every write to a test pipe below uses
# syswrite, which is unbuffered.
#
# The $^O hook here is the M3 pattern, not the M4 one: Watch.pm reads
# $^O DIRECTLY at line 158, so localising $^O to 'MSWin32' drives the
# Windows branch. The M4 $OS_NAME pattern does not apply.

use strict;
use warnings;

use Config;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use File::Spec;
use IO::Select;
use IO::Socket::INET;
use Socket qw(SO_TYPE SOL_SOCKET);
use Test::More;
use Time::HiRes ();

use lib File::Spec->catdir( $Bin, '..', 'lib' );

use Developer::Dashboard::GoRoutine ();

require_ok('Developer::Dashboard::StreamDrain');
require_ok('Developer::Dashboard::IndicatorStore::Watch');

my $IS_WINDOWS = $^O eq 'MSWin32';

# Fake Win32 modules (non-Windows only). See the header comment.
my $FAKE_NEW_FAIL       = 0;
my $FAKE_GETHANDLE_FAIL = 0;
my $FAKE_CALL_COUNT     = 0;
my %FAKE_LIE_ONCE;         # handle (fileno) => 1: next Call reports 5 bytes, once
my %FAKE_FH_FOR_HANDLE;    # handle (fileno) => filehandle
my $FIONREAD = $^O eq 'darwin' ? 0x4004667F : 0x541B;

if ( !$IS_WINDOWS ) {
    $INC{'Win32/API.pm'}     = 'fake-t1009';
    $INC{'Win32API/File.pm'} = 'fake-t1009';
    no warnings qw(once redefine prototype);
    *Win32::API::new = sub {
        my ( $class, @args ) = @_;
        return undef if $FAKE_NEW_FAIL;
        return bless {}, 'FakePeekNamedPipe';
    };
    *FakePeekNamedPipe::Call = sub {
        my ( $self, $handle, $buffer, $n, $bytes_read, $total_avail, $bytes_left ) = @_;
        $FAKE_CALL_COUNT++;
        # One-shot lie for the EINTR test: report five bytes on an empty
        # pipe, so the read that follows blocks and the alarm interrupts
        # it for real. The lie models bytes vanishing between the peek
        # and the read, which is a real race on Windows.
        if ( delete $FAKE_LIE_ONCE{$handle} ) {
            $_[5] = pack 'L', 5;
            return 1;
        }
        my $fh = $FAKE_FH_FOR_HANDLE{$handle};
        return 0 if !defined $fh;
        # Readable means data waits OR the writer closed (EOF is
        # readable). A readable pipe with nothing in it is broken.
        my $sel = IO::Select->new($fh);
        my @ready = $sel->can_read(0);
        if ( !@ready ) {
            $_[5] = pack 'L', 0;
            return 1;
        }
        my $packed = pack 'L', 0;
        my $ok = ioctl( $fh, $FIONREAD, $packed );
        return 0 if !$ok;
        my $count = unpack 'L', $packed;
        return 0 if $count == 0;
        $_[5] = pack 'L', $count;
        return 1;
    };
    *Win32API::File::GetOsFHandle = sub {
        my ($fh) = @_;
        return undef if $FAKE_GETHANDLE_FAIL;
        return undef if !defined $fh || !defined fileno($fh);
        my $handle = fileno($fh);
        $FAKE_FH_FOR_HANDLE{$handle} = $fh;
        return $handle;
    };
}

# _child_perl5lib($repo_root): the PERL5LIB a spawned child perl
# needs to load the repo and its built XS bundle. A `use lib` line
# in a child script cannot use @ARGV: use runs at compile time,
# before the argv assignment executes, so the paths arrive as undef.
# PERL5LIB is read at startup, before compilation, so it carries
# them. The inherited PERL5LIB (the local CPAN lib) stays at the end.
# Input: repository root directory.
# Output: PERL5LIB string.
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
# Input: child process id and a bound in seconds.
# Output: exit code integer, or undef on timeout.
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

# _loopback_socketpair()
# Creates a connected loopback socket pair, the t/669 pattern: a real
# socket answers getsockopt, which is what separates it from a pipe
# in _windows_handle_readable. Works on all five legs.
# Input: none.
# Output: ($reader, $peer) connected socket handles, or dies on failure.
sub _loopback_socketpair {
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Unable to create loopback listener: $!";
    my $peer = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $listener->sockport,
        Proto    => 'tcp',
    ) or die "Unable to connect loopback peer: $!";
    my $reader = $listener->accept
      or die "Unable to accept loopback connection: $!";
    close $listener;
    return ( $reader, $peer );
}

# Feature: a failed PeekNamedPipe import falls back to can_read.
#
# Scenario: the Win32 primitive is unavailable, so _handle_readable
# must fall back to the pre-existing can_read behaviour, never a new
# failure. Given the import fails, when _handle_readable runs on a
# pipe with data waiting, then it returns what can_read says.
# This runs in a spawned child FIRST (GoRoutine process API, R169:
# t/246 forbids a direct fork() in t/), before the parent ever
# imports the peek: the failed import is cached and never retried,
# so a failure here would poison every later test in this process.
# The child is a separate perl process, so it installs its own fake
# Win32 modules and makes its own pipe; the parent keeps no pipe.
SKIP: {
    skip 'import failure needs the fake Win32 modules', 2 if $IS_WINDOWS;
    my $dir = tempdir( CLEANUP => 1 );
    my $child_script = File::Spec->catfile( $dir, 'import-failure-child.pl' );
    {
        open my $sfh, '>', $child_script or die "Unable to write $child_script: $!";
        print {$sfh} "use strict;\n";
        print {$sfh} "use warnings;\n";
        print {$sfh} "use IO::Select;\n";
        print {$sfh} "require Developer::Dashboard::IndicatorStore::Watch;\n";
        print {$sfh} "# Fake Win32 modules: only Win32::API->new needs faking. The import\n";
        print {$sfh} "# fails before Call or GetOsFHandle are ever reached, so they are not\n";
        print {$sfh} "# modelled here; the failure is the whole point of this child.\n";
        print {$sfh} "\$INC{'Win32/API.pm'} = 'fake-t1009-child';\n";
        print {$sfh} "\$INC{'Win32API/File.pm'} = 'fake-t1009-child';\n";
        print {$sfh} "no warnings qw(once redefine prototype);\n";
        print {$sfh} "*Win32::API::new = sub { return undef; };\n";
        print {$sfh} "*Win32API::File::GetOsFHandle = sub { return undef; };\n";
        print {$sfh} "pipe( my \$r, my \$w ) or die \"cannot pipe: \$!\";\n";
        print {$sfh} "syswrite( \$w, 'FALLBACK' ) or die \"syswrite: \$!\";\n";
        print {$sfh} "my \$sel = IO::Select->new(\$r);\n";
        print {$sfh} "local \$^O = 'MSWin32';\n";
        print {$sfh} "my \$got = Developer::Dashboard::IndicatorStore::Watch::_handle_readable( \$sel, \$r );\n";
        print {$sfh} "my \$can = \$sel->can_read(0) ? 1 : 0;\n";
        print {$sfh} "exit( ( defined \$got && \$got == \$can && \$can == 1 ) ? 0 : 1 );\n";
        close $sfh or die "Unable to close $child_script: $!";
    }
    my $pid = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $child_script ],
        { env => { PERL5LIB => _child_perl5lib( File::Spec->catdir( $Bin, '..' ) ) } },
    );
    BAIL_OUT('GoRoutine spawn failed') if !defined $pid;
    my $rc = _wait_for_exit( $pid, 10 );
    is( $rc, 0, 'a failed PeekNamedPipe import falls back to can_read' );
    my $peek = Developer::Dashboard::IndicatorStore::Watch::_windows_peek_named_pipe();
    ok( defined $peek, 'the parent peek cache is untouched by the child' );
}

# Feature: _drain_child_streams_windows drains both child pipes.
#
# Scenario: both pipes carry data and both writers close. Given the
# peek reports the true byte counts, when the drain runs, then the
# callback gets both chunks, stdout first each round, and the drain
# returns 1.
{
    pipe( my $out_r, my $out_w ) or BAIL_OUT("cannot pipe: $!");
    pipe( my $err_r, my $err_w ) or BAIL_OUT("cannot pipe: $!");
    syswrite( $out_w, 'OUT-DATA' ) or die "syswrite: $!";
    syswrite( $err_w, 'ERR-DATA' ) or die "syswrite: $!";
    close $out_w;
    close $err_w;
    my @got;
    my $rc = Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
        undef, $out_r, $err_r,
        sub { my ( $is_out, $chunk ) = @_; push @got, [ $is_out, $chunk ]; },
        undef,
    );
    is( $rc, 1, 'the drain returns 1 when both streams reach end of file' );
    is( scalar(@got), 2, 'the drain delivers two chunks' );
    is( $got[0][0], 1, 'the first chunk is stdout' );
    is( $got[0][1], 'OUT-DATA', 'the stdout chunk arrives intact' );
    is( $got[1][0], 0, 'the second chunk is stderr' );
    is( $got[1][1], 'ERR-DATA', 'the stderr chunk arrives intact' );
    SKIP: {
        skip 'the peek call count needs the fake modules', 1 if $IS_WINDOWS;
        ok( $FAKE_CALL_COUNT > 0,
            'the peek ran during the drain, not just the fallback read' );
    }
    close $out_r;
    close $err_r;
}

# Scenario: both writers close with nothing written. Given empty
# pipes at end of file, when the drain runs, then it returns 1 and
# calls the callback never.
{
    pipe( my $out_r, my $out_w ) or BAIL_OUT("cannot pipe: $!");
    pipe( my $err_r, my $err_w ) or BAIL_OUT("cannot pipe: $!");
    close $out_w;
    close $err_w;
    my @got;
    my $rc = Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
        undef, $out_r, $err_r, sub { push @got, [@_]; }, undef );
    is( $rc, 1, 'the drain returns 1 on immediate end of file' );
    is( scalar(@got), 0, 'no chunks on immediate end of file' );
    close $out_r;
    close $err_r;
}

# Feature: the caller-supplied deadline ends a hung child on time.
#
# Scenario: the deadline is already past. Given a deadline in the
# past, when the drain runs, then it dies with the streaming timeout
# marker at once, without reading anything.
{
    pipe( my $out_r, my $out_w ) or BAIL_OUT("cannot pipe: $!");
    pipe( my $err_r, my $err_w ) or BAIL_OUT("cannot pipe: $!");
    my $died;
    eval {
        Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
            undef, $out_r, $err_r, sub { }, Time::HiRes::time() - 1 );
        1;
    } or $died = $@;
    like( $died, qr/__STREAMING_COMMAND_TIMEOUT__/,
        'a past deadline dies with the timeout marker' );
    close $out_w;
    close $err_w;
    close $out_r;
    close $err_r;
}

# Scenario: the deadline passes while the drain is polling. Given
# open writers and no data, when the deadline passes mid-drain, then
# it dies with the marker, on time, not after the alarm that never
# fires while blocked in select on Strawberry Perl.
{
    pipe( my $out_r, my $out_w ) or BAIL_OUT("cannot pipe: $!");
    pipe( my $err_r, my $err_w ) or BAIL_OUT("cannot pipe: $!");
    my $t0 = Time::HiRes::time();
    my $died;
    eval {
        Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
            undef, $out_r, $err_r, sub { }, $t0 + 0.3 );
        1;
    } or $died = $@;
    my $elapsed = Time::HiRes::time() - $t0;
    like( $died, qr/__STREAMING_COMMAND_TIMEOUT__/,
        'a mid-drain deadline dies with the timeout marker' );
    ok( $elapsed >= 0.25 && $elapsed < 3,
        "the mid-drain deadline fires on time ($elapsed s)" );
    close $out_w;
    close $err_w;
    close $out_r;
    close $err_r;
}

# Feature: an EINTR-interrupted read is retried, not mistaken for
# end of file (R163 item 6).
#
# Scenario: a signal arrives while sysread is blocked. Given the
# peek reports bytes on an empty pipe, the read blocks; the ALRM
# handler writes the payload and closes both writers, so the blocked
# read is interrupted with EINTR; when the drain retries, then it
# returns those bytes intact. This is the t/177 pattern, moved into
# the Windows drain: the handler supplies the data, so the retry has
# something to find, and a run cannot pass or fail on timing. If the
# retry were missing, the interrupted read would end the stream and
# the payload would never reach the callback.
SKIP: {
    skip 'EINTR cannot interrupt a blocking read on Windows', 5 if $IS_WINDOWS;
    pipe( my $out_r, my $out_w ) or BAIL_OUT("cannot pipe: $!");
    pipe( my $err_r, my $err_w ) or BAIL_OUT("cannot pipe: $!");
    my $PAYLOAD = 'PAYLOAD-AFTER-EINTR-12345';
    my $handler_fired = 0;
    local $SIG{ALRM} = sub {
        $handler_fired++;
        syswrite( $out_w, $PAYLOAD );
        close $out_w;
        close $err_w;
    };
    $FAKE_LIE_ONCE{ fileno($out_r) } = 1;
    alarm 1;
    my @got;
    my @warnings;
    my $rc;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $rc = Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
            undef, $out_r, $err_r,
            sub { my ( $is_out, $chunk ) = @_; push @got, [ $is_out, $chunk ]; },
            undef,
        );
    }
    alarm 0;
    is( $rc, 1, 'the drain returns 1 after the EINTR retry' );
    is( scalar(@got), 1, 'exactly one chunk after the retry' );
    is( $got[0][1], $PAYLOAD,
        'the bytes that arrived during the interrupt are returned intact' );
    ok( $handler_fired >= 1, 'the ALRM handler fired' );
    is( scalar(@warnings), 0,
        'the interrupted read raised no warning: it was retried, not treated as an error' );
    close $out_r;
    close $err_r;
}

# Feature: the drain returns 0 when the Windows primitive is
# unavailable, so the caller falls back to its select loop.
#
# Scenario: the PeekNamedPipe import fails. Given Win32::API->new
# returns undef, when the drain runs, then it returns 0.
# Scenario: no Win32 HANDLE can be reached. Given GetOsFHandle
# returns undef, when the drain runs, then it returns 0.
# Scenario: a handle is missing. Given an undefined stdout handle,
# when the drain runs, then it returns 0 without touching Win32.
# Scenario: a handle has no file descriptor. Given a handle that was
# never opened, when the drain runs, then it returns 0.
{
    pipe( my $out_r, my $out_w ) or BAIL_OUT("cannot pipe: $!");
    pipe( my $err_r, my $err_w ) or BAIL_OUT("cannot pipe: $!");
    my @got;
    my $cb = sub { push @got, [@_]; };
    is( Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
            undef, undef, $err_r, $cb, undef ),
        0, 'an undefined stdout handle returns 0' );
    my $unopened;
    is( Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
            undef, $unopened, $err_r, $cb, undef ),
        0, 'a handle with no file descriptor returns 0' );
    SKIP: {
        skip 'import failure needs the fake Win32 modules', 2 if $IS_WINDOWS;
        $FAKE_NEW_FAIL = 1;
        is( Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
                undef, $out_r, $err_r, $cb, undef ),
            0, 'a failed PeekNamedPipe import returns 0' );
        $FAKE_NEW_FAIL = 0;
        $FAKE_GETHANDLE_FAIL = 1;
        is( Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
                undef, $out_r, $err_r, $cb, undef ),
            0, 'an undefined Win32 handle returns 0' );
        $FAKE_GETHANDLE_FAIL = 0;
    }
    close $out_w;
    close $err_w;
    close $out_r;
    close $err_r;
}

# Feature: StreamDrain _windows_pipe_available reports the waiting
# byte count without blocking (R163 item 2).
#
# Scenario: the handle is undefined. Given undef, when it runs, then
# it returns undef (line 194, the 50% branch).
# Scenario: bytes are waiting. Given a pipe holding five bytes, when
# it runs, then it returns 5.
# Scenario: the pipe is broken. Given the bytes drained and the
# writer closed, when it runs, then it returns undef.
{
    my $peek = bless {}, 'FakePeekNamedPipe';
    is( Developer::Dashboard::StreamDrain::_windows_pipe_available( $peek, undef ),
        undef, 'an undefined handle returns undef' );
    SKIP: {
        skip 'a direct peek needs the fake modules', 3 if $IS_WINDOWS;
        pipe( my $r, my $w ) or BAIL_OUT("cannot pipe: $!");
        syswrite( $w, '12345' ) or die "syswrite: $!";
        my $handle = Win32API::File::GetOsFHandle($r);
        is( Developer::Dashboard::StreamDrain::_windows_pipe_available( $peek, $handle ),
            5, 'the byte count matches what is waiting' );
        my $drained = '';
        sysread( $r, $drained, 100 );
        is( $drained, '12345', 'the waiting bytes drain first' );
        close $w;
        is( Developer::Dashboard::StreamDrain::_windows_pipe_available( $peek, $handle ),
            undef, 'a drained and closed pipe returns undef' );
        close $r;
    }
}

# Feature: Watch _handle_readable on Windows tells a socket from a
# pipe (R163 items 3 and 4).
#
# Scenario: the handle is a socket. Given a socket, getsockopt
# answers SO_TYPE, so the select path is kept: when data is waiting
# it returns 1, when the socket is quiet it returns 0. Watch.pm
# reads $^O directly at line 158, so the M3 pattern (localise $^O)
# drives this branch, not the M4 $OS_NAME pattern.
{
    my ( $reader, $peer ) = _loopback_socketpair();
    my $sel = IO::Select->new($reader);
    {
        local $^O = 'MSWin32';
        syswrite( $peer, 'SOCK-DATA' ) or die "syswrite: $!";
        # macOS TCP loopback has a tiny delay before written data
        # becomes visible to the reader, so wait until the select
        # reports readable (bounded) before asserting. This is the
        # R142 pattern: pump until done, with a bound.
        my $deadline = Time::HiRes::time() + 1;
        while ( Time::HiRes::time() < $deadline ) {
            last if $sel->can_read(0);
            Time::HiRes::sleep(0.01);
        }
        is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $sel, $reader ),
            1, 'a socket with data reads 1 under MSWin32' );
        my $buf = '';
        sysread( $reader, $buf, 100 );
        is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $sel, $reader ),
            0, 'a quiet socket reads 0 under MSWin32' );
    }
    close $peer;
    close $reader;
}

# Scenario: the handle is a pipe. Given a pipe, getsockopt fails, so
# readiness comes from PeekNamedPipe: when data is waiting it returns
# 1, when the pipe is quiet it returns 0.
{
    pipe( my $r, my $w ) or BAIL_OUT("cannot pipe: $!");
    my $sel = IO::Select->new($r);
    {
        local $^O = 'MSWin32';
        syswrite( $w, 'PIPE-DATA' ) or die "syswrite: $!";
        my $calls_before = $FAKE_CALL_COUNT;
        is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $sel, $r ),
            1, 'a pipe with data reads 1 under MSWin32' );
        SKIP: {
            skip 'the peek call count needs the fake modules', 1 if $IS_WINDOWS;
            ok( $FAKE_CALL_COUNT > $calls_before,
                'the peek ran for the pipe, not just can_read' );
        }
        my $buf = '';
        sysread( $r, $buf, 100 );
        is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $sel, $r ),
            0, 'a quiet pipe reads 0 under MSWin32' );
    }
    close $w;
    close $r;
}

# Scenario: the Windows primitive is unavailable. Given
# GetOsFHandle returns undef, when _handle_readable runs, then it
# falls back to can_read and returns what can_read says. This does
# not poison the peek cache: the import succeeded and is cached, only
# the handle lookup fails.
SKIP: {
    skip 'a GetOsFHandle failure needs the fake modules', 2 if $IS_WINDOWS;
    pipe( my $r, my $w ) or BAIL_OUT("cannot pipe: $!");
    my $sel = IO::Select->new($r);
    syswrite( $w, 'FALLBACK-DATA' ) or die "syswrite: $!";
    $FAKE_GETHANDLE_FAIL = 1;
    my $got;
    {
        local $^O = 'MSWin32';
        $got = Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $sel, $r );
    }
    $FAKE_GETHANDLE_FAIL = 0;
    my $can = $sel->can_read(0) ? 1 : 0;
    is( $got, $can,
        'the fallback returns what can_read says when the primitive is unavailable' );
    is( $can, 1, 'can_read itself sees the data' );
    close $w;
    close $r;
}

# Scenario: the pipe is broken. Given the writer closed with nothing
# waiting, the peek fails, so the handle counts as readable and the
# caller's read reports the real end of file instead of silently
# missing the event.
{
    pipe( my $r, my $w ) or BAIL_OUT("cannot pipe: $!");
    close $w;
    my $sel = IO::Select->new($r);
    my $got;
    my $calls_before = $FAKE_CALL_COUNT;
    {
        local $^O = 'MSWin32';
        $got = Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $sel, $r );
    }
    is( $got, 1, 'a broken pipe counts as readable under MSWin32' );
    SKIP: {
        skip 'the peek call count needs the fake modules', 1 if $IS_WINDOWS;
        ok( $FAKE_CALL_COUNT > $calls_before,
            'the peek ran for the broken pipe, not just can_read' );
    }
    close $r;
}

# Feature: the three Watch Windows helper subs, driven directly
# (R163 item 4).
#
# Scenario: the peek import. Given the mocked modules, when
# _windows_peek_named_pipe runs, then it returns the cached function
# object. On Windows this is the real import.
# Scenario: Watch _windows_pipe_available with an undefined handle.
# Given undef, when it runs, then it returns undef.
# Scenario: Watch _windows_pipe_available with bytes waiting. Given
# a pipe holding three bytes, when it runs, then it returns 3.
{
    my $peek = Developer::Dashboard::IndicatorStore::Watch::_windows_peek_named_pipe();
    ok( defined $peek, 'the PeekNamedPipe import succeeds' );
    is( Developer::Dashboard::IndicatorStore::Watch::_windows_pipe_available( $peek, undef ),
        undef, 'Watch _windows_pipe_available with an undefined handle returns undef' );
    SKIP: {
        skip 'a direct peek count needs the fake modules', 1 if $IS_WINDOWS;
        pipe( my $r, my $w ) or BAIL_OUT("cannot pipe: $!");
        syswrite( $w, 'ABC' ) or die "syswrite: $!";
        my $handle = Win32API::File::GetOsFHandle($r);
        is( Developer::Dashboard::IndicatorStore::Watch::_windows_pipe_available( $peek, $handle ),
            3, 'Watch _windows_pipe_available count matches what is waiting' );
        close $w;
        close $r;
    }
}

# Feature: _handle_readable under the native operating system.
#
# Scenario: no Windows simulation. Given the real $^O, when
# _handle_readable runs on a pipe, then it uses can_read directly:
# 1 with data waiting, 0 when quiet. This pins that the $^O
# localisation above is what switches the behaviour.
{
    pipe( my $r, my $w ) or BAIL_OUT("cannot pipe: $!");
    my $sel = IO::Select->new($r);
    syswrite( $w, 'NORMAL-DATA' ) or die "syswrite: $!";
    is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $sel, $r ),
        1, 'a pipe with data reads 1 under the native operating system' );
    my $buf = '';
    sysread( $r, $buf, 100 );
    is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $sel, $r ),
        0, 'a quiet pipe reads 0 under the native operating system' );
    close $w;
    close $r;
}

# Feature: _linux_backend initialize pins the dup failure (R164).
#
# Scenario: R164 ruled Watch line 344 (the inotify open-or-die)
# stands for M7 because it is unreachable, and in its place the dup
# failure at line 341 is pinned. Given a mocked _xs_inotify_init,
# when initialize runs with an invalid fd, then it dies with the
# wrap diagnostic; when it runs with a valid fd, then it returns a
# handle wrapping that fd. The backend is fetched first, because
# _linux_backend runs the HtmlEscape bootstrap that installs the real
# _xs_inotify_init, and a mock installed before that is overwritten.
# The mock is restored afterwards so nothing later sees it.
{
    my $backend = Developer::Dashboard::IndicatorStore::Watch::_linux_backend();
    SKIP: {
        skip '_linux_backend unavailable on this platform', 5
          if !defined $backend;
        my $real_xs_init =
          Developer::Dashboard::IndicatorStore::Watch->can('_xs_inotify_init');
        my $mock_fd;
        {
            no warnings qw(once redefine prototype);
            no strict 'refs';
            *{'Developer::Dashboard::IndicatorStore::Watch::_xs_inotify_init'} =
              sub () { return $mock_fd; };
        }
        $mock_fd = 99999;
        my @warnings;
        my $lived;
        my $err;
        {
            local $SIG{__WARN__} = sub { push @warnings, $_[0]; };
            $lived = eval { $backend->{initialize}->(); 1 };
            $err = $@;
        }
        ok( !$lived, 'initialize dies on an invalid inotify fd' );
        like( $err, qr/Unable to wrap inotify descriptor 99999: Bad file descriptor/,
            'the die carries the wrap diagnostic' );
        is( scalar @warnings, 0,
            'the failed dup raised no warning: it died at once, not through the close' );
        pipe( my $r, my $w ) or BAIL_OUT("cannot pipe: $!");
        $mock_fd = fileno($r);
        my $handle = eval { $backend->{initialize}->() };
        $err = $@;
        ok( !$err && defined $handle, 'initialize returns a handle for a valid fd' );
        is( fileno($handle), fileno($r), 'the handle wraps the same fd' );
        close $handle;
        close $r;
        close $w;
        {
            no warnings qw(once redefine prototype);
            no strict 'refs';
            *{'Developer::Dashboard::IndicatorStore::Watch::_xs_inotify_init'} =
              $real_xs_init;
        }
    }
}

done_testing();

__END__

=head1 NAME

t/1009-streamdrain-watch-m5.t - M5 StreamDrain and Watch coverage tests

=head1 PURPOSE

Covers the StreamDrain.pm and Watch.pm remainder from the R83
coverage programme: the whole _drain_child_streams_windows sub (39
uncovered statements, never called), the _windows_pipe_available
undefined-handle branch, and the Watch Windows readable path (line
158 true side never taken, three helper subs never called). Written
first, before any implementation change, as the M5 milestone
requires. Watch line 344 (the inotify open-or-die) is NOT covered
here: it is unreachable, because the dup probe closes its duplicate
before the open, so any state where the dup succeeds also lets the
open succeed; R164 ruled it stands for M7, and in its place this
file pins the dup failure at line 341 with an invalid fd.

=head1 WHY IT EXISTS

Cover build #16 measured StreamDrain.pm at stmt 46.0, branch 26.4,
cond 25.0, sub 85.7, total 41.0 and Watch.pm at stmt 87.1, branch
84.0, cond 91.9, sub 90.6, total 87.0. Both gaps are Windows paths
never taken on the ARM64 cover run. This file drives them with fake
Win32 modules on Unix and the real primitives on the Windows legs of
the Jenkins proof, so the cover re-measure after M5 shows both files
moving toward the 98.0 gate.

=head1 WHEN TO USE

Run this file whenever StreamDrain.pm or Watch.pm changes. It is
part of the normal suite, not a probe: if it fails, a drain or watch
behaviour regressed.

=head1 HOW TO USE

    prove -v t/1009-streamdrain-watch-m5.t

Two shapes need care. The import-failure test runs in a spawned child
(GoRoutine process API) first, before the parent ever imports the
peek, because Watch caches a failed import and never retries; a
failure there would poison every later test in the process. And the
EINTR test arms a one-shot
lie in the fake peek (five bytes reported on an empty pipe) so the
read blocks and the alarm interrupts it for real; the handler writes
the payload, so the retry has something to find. The socket test
waits (bounded, one second) for the select to report readable after
the write, because macOS TCP loopback delays visibility (R167); the
wait polls, so a genuinely missing write still fails the assertion. Writes to test
pipes use syswrite, never print: print buffers, and a peek taken
before the flush sees an empty pipe while a sysread on it blocks
forever.

=head1 WHAT USES IT

The M5 milestone of the R83 coverage programme, and the cover
re-measure that follows it. The Jenkins proof runs this file on all
five legs.

=head1 EXAMPLES

    make test TEST_FILES=t/1009-streamdrain-watch-m5.t

=cut
