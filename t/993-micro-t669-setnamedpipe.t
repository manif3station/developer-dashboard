use strict;
use warnings;
use utf8;

use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Handle;
use IO::Select;
use IO::Socket::INET;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

plan tests => 18;

# Micro-probe for round 41, Jenkins build #372: t/669-problem48-inotify-watch.t
# passes 212/212 on all three Unix legs and its four Windows failures
# (tests 13/83/88/89) are fixed by the Watch.pm readiness helper, but the
# file still dies at test 189 (exit 25) in the read-error/eof block setup:
#   Use of uninitialized value in subroutine entry at t/669 line 752. (x2)
#   Unable to make error test pipe nonblocking: Inappropriate I/O control
#   operation at t/669 line 760.
# Line 752 is the SetNamedPipeHandleState call in the test-local
# _windows_pipe_nonblocking (t/669 line 741): Win32::API->new('kernel32',
# 'SetNamedPipeHandleState', 'QPPP', 'I'), mode pack 'L', 0x00000001
# (PIPE_READMODE_BYTE | PIPE_NOWAIT), handle from
# Win32API::File::GetOsFHandle($reader), with undef for the two NULL
# LPDWORD arguments. The Call fails with $! = ENOTTY (25). The two undef
# arguments drew the warnings, but whether they are also the failure is
# unproven - $^E (the Win32 error) was never captured. This micro tries
# every credible shape of the call in spawned child perls with verdict
# files and bounded parent polls, so a hanging variant can only kill the
# child, never the harness, and finds what actually makes an anonymous
# pipe read end nonblocking on Strawberry Perl - or proves that nothing
# in the SetNamedPipeHandleState family does, and that the test fixture
# needs a different shape (a loopback socket pair).

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..' );
require lib;
lib->import( File::Spec->catdir( $repo_root, 'lib' ) );

my $is_windows = $^O eq 'MSWin32' ? 1 : 0;
diag "HEARTBEAT: context perl=$^V os=$^O windows=$is_windows";

my $tmpdir = tempdir( CLEANUP => 1 );
my $child_file = File::Spec->catfile( $tmpdir, 'setpipe_child.pl' );

# One child program, dispatched by $ARGV[0] (the variant name). Every
# variant prints "pid=$$" first so the parent can kill it, then one
# "OUTCOME: <token>" line plus DETAIL lines. A sysread that blocks is
# reported by the parent as 'hung' after the 10-second poll, never by
# a stuck harness: the earlier probe's blocking(0) child hung on Windows
# for exactly this reason, so no variant sysreads without a verdict file
# and a parent kill.
diag 'HEARTBEAT: before writing child program';
open my $child_fh, '>', $child_file or die "Unable to write child probe program: $!";
print {$child_fh} <<'CHILD_EOF';
use strict;
use warnings;

# Child: one SetNamedPipeHandleState variant (or one socket/pipe read
# shape) per run. Every path writes an OUTCOME line to the verdict file
# except a genuinely blocking read, which the parent detects by timeout
# and kills. $^E is captured immediately after every Win32 call: it is
# the real diagnostic, and $! on Windows is unreliable.
my ($variant, $verdict_file) = @ARGV;
open my $vf, '>', $verdict_file or exit 99;
my $selected = select($vf); $| = 1; select($selected);
print {$vf} "pid=$$\n";
my $warn_count = 0;
local $SIG{__WARN__} = sub { $warn_count++ };
my $outcome = 'unknown';
my $detail  = '';

# _set_state_fn($proto)
# Imports SetNamedPipeHandleState once per call (the child is short-lived).
# Input: Win32::API prototype string.
# Output: function object, or undef with $@ holding the import error.
sub _set_state_fn {
    my ($proto) = @_;
    my $fn = eval {
        require Win32API::File;
        require Win32::API;
        Win32::API->new( 'kernel32', 'SetNamedPipeHandleState', $proto, 'I' );
    };
    return $fn;
}

# _call_set_state($fn, $handle, $mode, $null1, $null2)
# Calls SetNamedPipeHandleState and captures every diagnostic at once.
# Input: function object, OS handle, packed mode DWORD, two LPDWORD args.
# Output: (return, errno, winerr, winstr).
sub _call_set_state {
    my ($fn, $handle, $mode, $null1, $null2) = @_;
    $^E = 0;
    $!  = 0;
    my $ret = $fn->Call( $handle, $mode, $null1, $null2 );
    my $errno  = 0 + $!;
    my $winerr = 0 + $^E;
    my $winstr = "$^E";
    $winstr =~ s/\n/ /g;
    return ($ret, $errno, $winerr, $winstr);
}

# _peek_bytes($handle)
# PeekNamedPipe byte count, proving the handle is a valid pipe handle.
# Input: OS handle.
# Output: byte count, or undef when the call fails.
sub _peek_bytes {
    my ($handle) = @_;
    my $peek = eval {
        require Win32API::File;
        require Win32::API;
        my $imported = Win32::API->new( 'kernel32', 'PeekNamedPipe', 'QPIPPP', 'I' );
        die "no PeekNamedPipe\n" if !defined $imported;
        $imported;
    };
    return undef if !$peek;
    $^E = 0;
    my $bytes_read  = pack 'L', 0;
    my $total_avail = pack 'L', 0;
    my $bytes_left  = pack 'L', 0;
    my $ok = $peek->Call( $handle, '', 0, $bytes_read, $total_avail, $bytes_left );
    return undef if !$ok;
    return unpack 'L', $total_avail;
}

# _sysread_empty($reader)
# One sysread on an empty reader with the writer still open.
# Input: pipe/socket read-end filehandle.
# Output: 'nonblocking-eagain', 'sysread-returned-N', or 'sysread-undef ...'.
sub _sysread_empty {
    my ($reader) = @_;
    my $buffer = '';
    my $read = sysread( $reader, $buffer, 4096 );
    if ( defined $read ) {
        return "sysread-returned-$read";
    }
    if ( $!{EAGAIN} || $!{EWOULDBLOCK} ) {
        return 'nonblocking-eagain errno=' . ( 0 + $! );
    }
    my $error = "$!";
    $error =~ s/\n/ /g;
    return 'sysread-undef errno=' . ( 0 + $! ) . " $error";
}

# _sysread_eof($reader)
# One sysread where EOF is expected, retrying EAGAIN briefly: on a
# loopback socket the peer FIN can lag the close by a moment, and a
# single immediate sysread could see EAGAIN instead of 0.
# Input: pipe/socket read-end filehandle.
# Output: 'sysread-returned-N', or the _sysread_empty outcome.
sub _sysread_eof {
    my ($reader) = @_;
    for my $attempt ( 1 .. 5 ) {
        my $buffer = '';
        my $read = sysread( $reader, $buffer, 4096 );
        return "sysread-returned-$read" if defined $read;
        return _sysread_empty($reader) if !( $!{EAGAIN} || $!{EWOULDBLOCK} );
        select( undef, undef, undef, 0.2 );
    }
    return _sysread_empty($reader);
}

if ( $variant eq 'exact'
    || $variant eq 'packed-zeros'
    || $variant eq 'nppp'
    || $variant eq 'pppp'
    || $variant eq 'write-end'
    || $variant eq 'mode0' )
{
    pipe( my $reader, my $writer ) or do {
        $outcome = 'pipe-failed';
        $detail  = "$!";
        goto DONE;
    };
    $writer->autoflush(1);
    my $proto = 'QPPP';
    $proto = 'NPPP' if $variant eq 'nppp';
    $proto = 'PPPP' if $variant eq 'pppp';
    my $fn = _set_state_fn($proto);
    if ( !$fn ) {
        my $error = $@;
        $error =~ s/\n/ /g;
        $outcome = 'import-failed';
        $detail  = $error;
        goto DONE;
    }
    # The exact t/669 shape first proves the OS handle is a valid pipe
    # handle at all: if PeekNamedPipe works on it, the failure is in
    # SetNamedPipeHandleState, not in the handle.
    if ( $variant eq 'exact' ) {
        my $os_handle_peek = Win32API::File::GetOsFHandle($reader);
        my $peek_bytes = _peek_bytes($os_handle_peek);
        $detail .= " peek=" . ( defined $peek_bytes ? "$peek_bytes-bytes" : 'failed' );
    }
    my $target = $reader;
    $target = $writer if $variant eq 'write-end';
    my $os_handle = Win32API::File::GetOsFHandle($target);
    if ( !defined $os_handle ) {
        $outcome = 'handle-failed';
        $detail .= ' GetOsFHandle returned undef';
        goto DONE;
    }
    my $mode = pack 'L', 0x00000001;
    $mode = pack 'L', 0 if $variant eq 'mode0';
    my $null1 = undef;
    my $null2 = undef;
    if ( $variant eq 'packed-zeros' ) {
        $null1 = pack 'L', 0;
        $null2 = pack 'L', 0;
    }
    my ($ret, $errno, $winerr, $winstr) = _call_set_state( $fn, $os_handle, $mode, $null1, $null2 );
    $detail .= " ret=" . ( defined $ret ? $ret : 'undef' )
      . " errno=$errno winerr=$winerr winstr=[$winstr] warnings=$warn_count";
    if ( !$ret ) {
        $outcome = 'call-failed';
        goto DONE;
    }
    if ( $variant eq 'mode0' || $variant eq 'write-end' ) {
        # Diagnostic-only variants: the call succeeding is the finding.
        # No sysread here: mode0 leaves the pipe blocking, and the write
        # end is not the handle the test reads from.
        $outcome = 'call-ok';
        goto DONE;
    }
    $outcome = _sysread_empty($reader);
}
elsif ( $variant eq 'named-pipe' ) {
    my $fn = _set_state_fn('QPPP');
    if ( !$fn ) {
        my $error = $@;
        $error =~ s/\n/ /g;
        $outcome = 'import-failed';
        $detail  = $error;
        goto DONE;
    }
    my $create = eval {
        require Win32::API;
        Win32::API->new( 'kernel32', 'CreateNamedPipe', 'PNNNNNNNP', 'Q' );
    };
    if ( !$create ) {
        my $error = $@;
        $error =~ s/\n/ /g;
        $outcome = 'create-import-failed';
        $detail  = $error;
        goto DONE;
    }
    my $pipe_name = '\\\\.\\pipe\\micro993test' . $$;
    $^E = 0;
    $!  = 0;
    my $handle = $create->Call( $pipe_name, 0x00000003, 0, 1, 4096, 4096, 0, undef );
    my $create_errno  = 0 + $!;
    my $create_winerr = 0 + $^E;
    my $create_winstr = "$^E";
    $create_winstr =~ s/\n/ /g;
    $detail .= " create=" . ( defined $handle ? $handle : 'undef' )
      . " errno=$create_errno winerr=$create_winerr winstr=[$create_winstr]";
    if ( !defined $handle ) {
        $outcome = 'named-pipe-create-failed';
        goto DONE;
    }
    my $mode = pack 'L', 0x00000001;
    my ($ret, $errno, $winerr, $winstr) = _call_set_state( $fn, $handle, $mode, undef, undef );
    $detail .= " ret=" . ( defined $ret ? $ret : 'undef' )
      . " errno=$errno winerr=$winerr winstr=[$winstr] warnings=$warn_count";
    my $close = eval {
        require Win32::API;
        Win32::API->new( 'kernel32', 'CloseHandle', 'Q', 'I' );
    };
    $close->Call($handle) if $close;
    $outcome = $ret ? 'call-ok' : 'call-failed';
}
elsif ( $variant eq 'socket-eagain' || $variant eq 'socket-eof' ) {
    require IO::Socket::INET;
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    );
    if ( !$listener ) {
        $outcome = 'listen-failed';
        $detail  = "$!";
        goto DONE;
    }
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $listener->sockport,
        Proto    => 'tcp',
    );
    if ( !$client ) {
        $outcome = 'connect-failed';
        $detail  = "$!";
        goto DONE;
    }
    my $server = $listener->accept;
    if ( !$server ) {
        $outcome = 'accept-failed';
        $detail  = "$!";
        goto DONE;
    }
    $server->blocking(0);
    if ( $variant eq 'socket-eof' ) {
        close $client;
        close $listener;
        $outcome = _sysread_eof($server);
    }
    else {
        $outcome = _sysread_empty($server);
    }
}
elsif ( $variant eq 'pipe-eof' ) {
    pipe( my $reader, my $writer ) or do {
        $outcome = 'pipe-failed';
        $detail  = "$!";
        goto DONE;
    };
    close $writer;
    $outcome = _sysread_eof($reader);
}
else {
    $outcome = 'unknown-variant';
    $detail  = $variant;
}

DONE:
print {$vf} "OUTCOME: $outcome\n";
print {$vf} "DETAIL: $detail\n" if $detail ne '';
close $vf;
exit 0;
CHILD_EOF
close $child_fh or die "Unable to close child probe program: $!";
diag 'HEARTBEAT: after writing child program';

my $child_slurp = do {
    open my $slurp_fh, '<', $child_file or die "Unable to re-read child probe program: $!";
    local $/;
    <$slurp_fh>;
};
ok( -f $child_file && $child_slurp =~ /OUTCOME: nonblocking-eagain/ && $child_slurp =~ /SetNamedPipeHandleState/,
    'child probe program written with the variant dispatch' );

# run_child($tag, $variant)
# Runs one child variant with a verdict file and a bounded 10-second
# parent poll, then kills the child if it produced no verdict (a hanging
# read is a verdict, never a stuck harness).
# Input: tag for the verdict file, variant name passed to the child.
# Output: hashref with verdict, detail, timed_out and exit code.
sub run_child {
    my ( $tag, $variant ) = @_;
    my $verdict_file = File::Spec->catfile( $tmpdir, "verdict-$tag.txt" );
    diag "HEARTBEAT: spawning child for variant $variant";
    my ( $in, $out, $err ) = ( gensym, gensym, gensym );
    my $pid = open3( $in, $out, $err, $^X, $child_file, $variant, $verdict_file );
    close $in;
    my $verdict = '';
    my $detail  = '';
    my $timed_out = 0;
    my $deadline = time() + 10;
    my $polls = 0;
    while ( time() < $deadline ) {
        if ( open my $vf, '<', $verdict_file ) {
            local $/;
            my $content = <$vf>;
            close $vf;
            if ( defined $content && $content =~ /OUTCOME: (\S+)/ ) {
                $verdict = $1;
                ($detail) = $content =~ /DETAIL: (.*)/;
                $detail = '' if !defined $detail;
                last;
            }
        }
        $polls++;
        diag "HEARTBEAT: waiting for child verdict variant=$variant poll=$polls" if $polls % 10 == 0;
        select( undef, undef, undef, 0.2 );
    }
    if ( !$verdict ) {
        diag "HEARTBEAT: child for variant $variant produced no verdict in 10s, killing pid=$pid";
        kill 9, $pid;
        $verdict   = 'hung';
        $timed_out = 1;
    }
    waitpid( $pid, 0 );
    my $exit = $? >> 8;
    close $out;
    close $err;
    diag "HEARTBEAT: variant $variant verdict=$verdict polls=$polls exit=$exit"
      . ( $detail ne '' ? " detail=[$detail]" : '' );
    return { verdict => $verdict, detail => $detail, timed_out => $timed_out, exit => $exit };
}

# Phase A: the Fcntl macros. Already proven by the t/995 probe (all three
# undefined on Strawberry Perl); re-confirmed here so this micro stands
# alone as the evidence for the t/669 fix.
diag 'HEARTBEAT: phase A starting - Fcntl macro defined-ness';
my $f_setfl_defined = eval { my $v = Fcntl::F_SETFL(); 1 } ? 1 : 0;
my $f_getfl_defined = eval { my $v = Fcntl::F_GETFL(); 1 } ? 1 : 0;
my $o_nonblock_defined = eval { my $v = Fcntl::O_NONBLOCK(); 1 } ? 1 : 0;
diag "HEARTBEAT: phase A F_SETFL=$f_setfl_defined F_GETFL=$f_getfl_defined O_NONBLOCK=$o_nonblock_defined";
is( $f_setfl_defined, $is_windows ? 0 : 1,
    'phase A: F_SETFL is undefined on Strawberry Perl, defined on Unix' );
is( $f_getfl_defined, $is_windows ? 0 : 1,
    'phase A: F_GETFL is undefined on Strawberry Perl, defined on Unix' );
is( $o_nonblock_defined, $is_windows ? 0 : 1,
    'phase A: O_NONBLOCK is undefined on Strawberry Perl, defined on Unix' );
diag 'HEARTBEAT: phase A complete';

# Phase B: SetNamedPipeHandleState variants on an anonymous pipe (and one
# real named pipe). Windows-only: the Win32 calls do not exist elsewhere.
# Each test asserts only that the variant produced a verdict - the verdict
# itself is the finding, recorded in the diag lines and the parent report.
# A 'hung' verdict is a measurement (the call left the pipe blocking),
# not a harness failure.
my %verdicts;
SKIP: {
    skip 'SetNamedPipeHandleState is Windows-only', 7 if !$is_windows;
    diag 'HEARTBEAT: phase B starting - SetNamedPipeHandleState variants';
    my @variants = qw(exact packed-zeros nppp pppp write-end mode0 named-pipe);
    for my $variant (@variants) {
        my $result = run_child( $variant, $variant );
        $verdicts{$variant} = $result;
        ok( defined $result->{verdict} && $result->{verdict} ne '' && $result->{verdict} ne 'no-verdict',
            "phase B: variant $variant produced a verdict ($result->{verdict})" );
    }
    diag 'HEARTBEAT: phase B complete';
}

# Phase C: what the test actually needs - a read that returns promptly
# with no data queued. The socket pair and the pipe EOF shape run on
# every leg as controls; the PeekNamedPipe check is Windows-only.
diag 'HEARTBEAT: phase C starting - prompt-read alternatives';
my $socket_eagain = run_child( 'socket-eagain', 'socket-eagain' );
is( $socket_eagain->{verdict}, 'nonblocking-eagain',
    'phase C: loopback socket read end goes nonblocking and returns EAGAIN with no data queued' );
my $socket_eof = run_child( 'socket-eof', 'socket-eof' );
is( $socket_eof->{verdict}, 'sysread-returned-0',
    'phase C: loopback socket read returns 0 once the peer closes' );
SKIP: {
    skip 'PeekNamedPipe is Windows-only', 2 if !$is_windows;
    diag 'HEARTBEAT: phase C PeekNamedPipe starting';
    my $peek = eval {
        require Win32API::File;
        require Win32::API;
        my $imported = Win32::API->new( 'kernel32', 'PeekNamedPipe', 'QPIPPP', 'I' );
        die "Could not import PeekNamedPipe from kernel32\n" if !defined $imported;
        $imported;
    };
    ok( defined $peek, 'phase C: PeekNamedPipe imports from kernel32' );
    my ( $peek_reader, $peek_writer );
    pipe( $peek_reader, $peek_writer ) or die "Unable to create peek test pipe: $!";
    $peek_writer->autoflush(1);
    my $os_handle = Win32API::File::GetOsFHandle($peek_reader);
    $^E = 0;
    my $bytes_read  = pack 'L', 0;
    my $total_avail = pack 'L', 0;
    my $bytes_left  = pack 'L', 0;
    my $peek_ok = $peek->Call( $os_handle, '', 0, $bytes_read, $total_avail, $bytes_left );
    my $avail_empty = $peek_ok ? unpack 'L', $total_avail : undef;
    diag "HEARTBEAT: phase C PeekNamedPipe empty pipe: "
      . ( defined $avail_empty ? "$avail_empty bytes" : 'undef' );
    is( $avail_empty, 0, 'phase C: PeekNamedPipe reports 0 bytes on an empty pipe' );
    close $peek_writer;
    close $peek_reader;
}
my $pipe_eof = run_child( 'pipe-eof', 'pipe-eof' );
is( $pipe_eof->{verdict}, 'sysread-returned-0',
    'phase C: pipe read returns 0 once the writer closes, with no nonblocking flag at all' );
diag 'HEARTBEAT: phase C complete';

# Phase D: the measurement is complete and the recommendation is on the
# record. Which shape the fix takes is decided from the verdict table
# in the parent report, not from these assertions.
diag 'HEARTBEAT: phase D starting - verdict table';
my $recommendation;
if ($is_windows) {
    my $working = grep {
        defined $verdicts{$_}
          && ( $verdicts{$_}->{verdict} eq 'nonblocking-eagain'
            || $verdicts{$_}->{verdict} eq 'call-ok' )
    } qw(exact packed-zeros nppp pppp named-pipe);
    $recommendation
      = $working ? 'setnamedpipestate-works'
      : $socket_eagain->{verdict} eq 'nonblocking-eagain' ? 'socket-fixture'
      : 'none';
}
else {
    $recommendation = 'windows-only';
}
diag "HEARTBEAT: phase D recommendation=$recommendation";
for my $variant ( sort keys %verdicts ) {
    diag "HEARTBEAT: verdict $variant = $verdicts{$variant}->{verdict}"
      . ( $verdicts{$variant}->{detail} ne '' ? " [$verdicts{$variant}->{detail}]" : '' );
}
diag "HEARTBEAT: verdict socket-eagain = $socket_eagain->{verdict}";
diag "HEARTBEAT: verdict socket-eof = $socket_eof->{verdict}";
diag "HEARTBEAT: verdict pipe-eof = $pipe_eof->{verdict}";
is( scalar( keys %verdicts ), $is_windows ? 7 : 0,
    'phase D: all seven SetNamedPipeHandleState variants produced a verdict on Windows' );
ok( defined $recommendation && $recommendation ne '',
    'phase D: recommendation recorded' );
diag 'HEARTBEAT: micro complete';

__END__

=pod

=head1 NAME

993-micro-t669-setnamedpipe.t - probe the failed SetNamedPipeHandleState replacement in t/669

=head1 DESCRIPTION

This micro proves what actually makes an anonymous pipe read end
nonblocking on Strawberry Perl. Solo #372 verified the Watch.pm
readiness fix on Windows (t/669 tests 13/83/88/89 pass on all four legs,
zero not-ok lines) but the file still dies at test 189 (exit 25) in the
read-error/eof block setup: the test-local _windows_pipe_nonblocking
(t/669 line 741) calls SetNamedPipeHandleState with PIPE_NOWAIT and the
Call fails with $! = ENOTTY (25), after two "uninitialized value in
subroutine entry" warnings for the two undef NULL-pointer arguments.
$^E (the Win32 error) was never captured, so whether the failure is the
undef arguments, the 'QPPP' prototype, or PIPE_NOWAIT being inapplicable
to anonymous pipes is unproven. This micro tries every credible shape of
the call in spawned child perls, captures return value, $! and $^E for
each, and proves the alternatives the test fixture actually needs.

=for comment FULL-POD-DOC START

=head1 PURPOSE

This micro is the executable evidence for the t/669 F_SETFL replacement.
Read it when you need to know whether SetNamedPipeHandleState can be
made to work on an anonymous pipe read end, which argument or prototype
shape (if any) succeeds, what the real Win32 error is for the shapes
that fail, and what fixture shape the read-error/eof block should use
instead if none of them works.

=head1 WHY IT EXISTS

It exists because the "shape to try" from the t/995 probe did not hold:
SetNamedPipeHandleState with PIPE_NOWAIT failed on the anonymous pipe
in solo #372, and guessing another shape without measuring it would
repeat the same failure. The micro separates the three suspects - the
undef NULL arguments, the prototype, and the anonymous-pipe handle kind -
and measures the socket-pair and pipe-EOF alternatives the test could
use instead, so the fix is chosen from evidence rather than from the
Win32 documentation alone.

=head1 WHEN TO USE

Use this file while deciding the t/669 F_SETFL replacement, and delete
it in the cleanup commit once the fix is solo-verified, like every other
probe micro.

=head1 HOW TO USE

Run it as a Jenkins solo with TEST_FILE=t/993-micro-t669-setnamedpipe.t,
then read the per-variant verdicts from the console output. Do not run
it by hand outside Jenkins. Every variant runs in a spawned child perl
with a verdict file and a bounded 10-second parent poll, so a blocking
read can only kill the child, never the harness.

=head1 WHAT USES IT

The loop owner uses it to choose the t/669 F_SETFL replacement: a
working SetNamedPipeHandleState shape, a socket-pair fixture, or a
restructured read-error/eof block. Nothing else uses it.

=head1 EXAMPLES

Example 1:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/993-micro-t669-setnamedpipe.t 1

Trigger the probe solo and read the per-variant verdicts from the console.

Example 2:

  grep -n "verdict" ~/workspace/goals/developer-dashboard-pr-73-windows-support/hidden_files/jenkins-build-<n>-console.txt

Read the variant verdicts per leg from the saved console.

=for comment FULL-POD-DOC END

=cut
