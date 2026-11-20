use strict;
use warnings;
use utf8;

use Config qw(%Config);
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

plan tests => 28;

# Micro-probe for round 40/41, Jenkins builds #368/#369: t/669-problem48-inotify-watch.t
# fails ONLY on the Windows leg with byte-identical failures on the fix tip
# (b90b8e42d) and the pre-fix tip (0ee917936), so they are pre-existing and
# the t/669 OOM fix caused none of them:
#   not ok 13 - any queued event invalidates the fast path
#   not ok 83 - FSEvents readiness invalidates the cached snapshot
#   not ok 88 - FSEvents read failure invalidates the snapshot
#   not ok 89 - FSEvents read exception is visible
#   Your vendor has not defined Fcntl macro F_SETFL, used at t/669 line 737
#   Dubious, test returned 25 (wstat 6400, 0x1900)
# The hypothesis is that tests 13/83/88/89 are one mechanism: every one of
# them writes to a pipe and expects the read end to show readable, but on
# Windows IO::Select->can_read never fires for a non-socket handle - the
# same root cause as the t/88 SSL hang, fixed in 1c1034de by probing
# getsockopt SO_TYPE first. The product already knows this: StreamDrain.pm
# documents that select() on Windows only works for real sockets, and
# drains Windows pipes with PeekNamedPipe instead. This micro proves the
# chain without fixing anything: the dangerous sysread runs in a spawned
# child perl with a verdict file and a bounded parent poll, so a blocking
# read can only kill the child, never the harness.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..' );
require lib;
lib->import( File::Spec->catdir( $repo_root, 'lib' ) );

my $module = 'Developer::Dashboard::IndicatorStore::Watch';
my $loaded = eval "require $module; 1";
ok( $loaded, 'the indicator watcher module loads' ) or BAIL_OUT($@);

my $is_windows = $^O eq 'MSWin32' ? 1 : 0;
diag "HEARTBEAT: context perl=$^V os=$^O arch=$Config{archname} windows=$is_windows";

# Phase A: raw IO::Select->can_read on a pipe, with a socket contrast.
diag 'HEARTBEAT: phase A starting - raw can_read on a pipe';
my ( $reader, $writer );
pipe( $reader, $writer ) or die "Unable to create phase A pipe: $!";
$writer->autoflush(1);
diag 'HEARTBEAT: phase A pipe created, before write';
print {$writer} "change\n" or die "Unable to write phase A pipe: $!";
diag 'HEARTBEAT: phase A wrote change, before can_read(0)';
my $select = IO::Select->new($reader);
my @ready_now = $select->can_read(0);
diag "HEARTBEAT: phase A can_read(0) after write: " . scalar(@ready_now) . " ready";
is( scalar(@ready_now), $is_windows ? 0 : 1,
    'phase A: pipe can_read(0) after write fires on Unix, never on Windows' );
diag 'HEARTBEAT: phase A before can_read(0.5)';
my @ready_wait = $select->can_read(0.5);
diag "HEARTBEAT: phase A can_read(0.5) after write: " . scalar(@ready_wait) . " ready";
is( scalar(@ready_wait), $is_windows ? 0 : 1,
    'phase A: pipe can_read(0.5) after write fires on Unix, never on Windows' );
diag 'HEARTBEAT: phase A before CORE select vec';
vec( my $bits = '', fileno($reader), 1 ) = 1;
my $selected = select( $bits, undef, undef, 0 );
diag "HEARTBEAT: phase A CORE select returned $selected";
is( $selected, $is_windows ? -1 : 1,
    'phase A: CORE select on a pipe with data fires on Unix, errors (-1) on Windows' );
diag 'HEARTBEAT: phase A before empty-pipe control';
my ( $empty_reader, $empty_writer );
pipe( $empty_reader, $empty_writer ) or die "Unable to create empty control pipe: $!";
my $empty_select = IO::Select->new($empty_reader);
my @empty_ready = $empty_select->can_read(0);
diag "HEARTBEAT: phase A empty pipe can_read(0): " . scalar(@empty_ready) . " ready";
is( scalar(@empty_ready), 0, 'phase A: empty pipe can_read(0) is quiet on every leg' );
diag 'HEARTBEAT: phase A before socket contrast';
my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 1,
    ReuseAddr => 1,
) or die "Unable to create loopback listener: $!";
my $client = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $listener->sockport,
    Proto    => 'tcp',
) or die "Unable to connect loopback client: $!";
my $server = $listener->accept or die "Unable to accept loopback client: $!";
print {$client} "ping\n" or die "Unable to write loopback socket: $!";
my $socket_select = IO::Select->new($server);
my @socket_ready = $socket_select->can_read(0);
diag "HEARTBEAT: phase A socket can_read(0) after write: " . scalar(@socket_ready) . " ready";
is( scalar(@socket_ready), 1,
    'phase A: socket can_read(0) after write fires on every leg, including Windows' );
close $client;
close $server;
close $listener;
close $writer;
close $reader;
close $empty_writer;
close $empty_reader;
diag 'HEARTBEAT: phase A complete';

# Phase B: the product call site for test 13 - Watch::unchanged over an
# injected descriptor backend, the exact t/669 shape.
diag 'HEARTBEAT: phase B starting - Watch unchanged over an injected pipe backend';
my ( @writers, @added, $initializations );
my $backend = {
    initialize => sub {
        pipe( my $r, my $w ) or die "Unable to create test pipe: $!";
        $w->autoflush(1);
        push @writers, $w;
        $initializations++;
        return $r;
    },
    add_watch => sub {
        my ( $handle, $path, $mask ) = @_;
        push @added, [ $path, $mask ];
        return scalar @added;
    },
    close => sub {
        my ($handle) = @_;
        return close $handle;
    },
};
my $watcher = $module->new( backend => $backend );
ok( $watcher->configure( 'inventory-a', [ '/root', '/root/one' ] ),
    'phase B: injected pipe backend configures' );
diag 'HEARTBEAT: phase B before quiet unchanged';
ok( $watcher->unchanged('inventory-a'), 'phase B: quiet pipe backend reports unchanged' );
diag 'HEARTBEAT: phase B before write';
print { $writers[0] } "change\n" or die "Unable to signal fake event: $!";
diag 'HEARTBEAT: phase B wrote change, before unchanged';
my $after_write = $watcher->unchanged('inventory-a') ? 1 : 0;
diag "HEARTBEAT: phase B unchanged after write: $after_write";
is( $after_write, $is_windows ? 1 : 0,
    'phase B: queued pipe event invalidates the fast path on Unix, not on Windows' );
is( $watcher->last_error, undef,
    'phase B: the missed event leaves no error diagnostic on either leg' );
ok( $watcher->close, 'phase B: watcher closes' );
diag 'HEARTBEAT: phase B complete';

# Phase C: the product call site for tests 83/88/89 - the macOS FSEvents
# backend over a pipe fixture, called directly exactly as t/669 does it.
diag 'HEARTBEAT: phase C starting - macOS backend over a pipe fixture';
my ( $mac_read_fh, $mac_write_fh );
pipe( $mac_read_fh, $mac_write_fh ) or die "Unable to create FSEvents fixture pipe: $!";
$mac_write_fh->autoflush(1);
our $micro995_read_events_called = 0;
my $mac_backend;
my ( $mac_handle, $mac_error );
my ( $quiet_state, $quiet_error );
my ( $event_state, $event_error );
{
    # The stub must stay installed while configure_paths runs: it calls
    # Mac::FSEvents->new, and once this block ends the localization is
    # undone and setup fails. (Solo #370 red on every leg for exactly
    # this: configure was called outside the stub block.)
    no warnings qw(redefine once);
    local $INC{'Mac/FSEvents.pm'} = __FILE__;
    local *Mac::FSEvents::new = sub {
        return bless { fh => $mac_read_fh }, 'Local::Micro995FSEvents';
    };
    $mac_backend = $module->_macos_backend;
    ( $mac_handle, $mac_error ) = $mac_backend->{configure_paths}->(['/one']);
    diag "HEARTBEAT: phase C configure error=" . ( defined $mac_error ? $mac_error : 'undef' );
}
ok( ref($mac_backend) eq 'HASH', 'phase C: macOS backend loads with the stubbed module' );
ok( defined $mac_handle, 'phase C: macOS backend configures over the pipe fixture' );
diag 'HEARTBEAT: phase C before quiet unchanged';
( $quiet_state, $quiet_error ) = $mac_backend->{unchanged}->($mac_handle);
is( $quiet_state, 1, 'phase C: quiet FSEvents stream reports unchanged on every leg' );
diag 'HEARTBEAT: phase C before write';
print {$mac_write_fh} "event\n" or die "Unable to signal FSEvents fixture: $!";
diag 'HEARTBEAT: phase C wrote event, before unchanged';
( $event_state, $event_error ) = $mac_backend->{unchanged}->($mac_handle);
diag "HEARTBEAT: phase C unchanged after write: state="
  . ( defined $event_state ? $event_state : 'undef' );
is( $event_state, $is_windows ? 1 : 0,
    'phase C: FSEvents readiness invalidates the snapshot on Unix, not on Windows' );
my ( $unread_read_fh, $unread_write_fh );
pipe( $unread_read_fh, $unread_write_fh ) or die "Unable to create unreadable fixture pipe: $!";
$unread_write_fh->autoflush(1);
my $unread_backend;
my ( $unread_handle, $unread_setup_error );
my ( $unread_state, $unread_error );
{
    # Same stub-scope rule as the readable fixture above: configure_paths
    # calls Mac::FSEvents->new, so it must run inside this block.
    no warnings qw(redefine once);
    local $INC{'Mac/FSEvents.pm'} = __FILE__;
    local *Mac::FSEvents::new = sub {
        return bless { fh => $unread_read_fh }, 'Local::Micro995UnreadableFSEvents';
    };
    $unread_backend = $module->_macos_backend;
    ( $unread_handle, $unread_setup_error ) = $unread_backend->{configure_paths}->(['/one']);
    diag "HEARTBEAT: phase C unreadable configure error="
      . ( defined $unread_setup_error ? $unread_setup_error : 'undef' );
}
ok( defined $unread_handle, 'phase C: unreadable FSEvents fixture configures' );
$micro995_read_events_called = 0;
print {$unread_write_fh} "event\n" or die "Unable to signal unreadable fixture: $!";
diag 'HEARTBEAT: phase C wrote unreadable event, before unchanged';
( $unread_state, $unread_error ) = $unread_backend->{unchanged}->($unread_handle);
diag "HEARTBEAT: phase C unreadable unchanged: state="
  . ( defined $unread_state ? $unread_state : 'undef' )
  . " error=" . ( defined $unread_error ? $unread_error : 'undef' )
  . " read_events_called=$micro995_read_events_called";
is( $micro995_read_events_called, $is_windows ? 0 : 1,
    'phase C: the read path runs on Unix, but the can_read gate stops it on Windows' );
if ($is_windows) {
    is( $unread_error, undef,
        'phase C: on Windows the read exception is never reached, so the error is undef' );
}
else {
    like( $unread_error, qr/synthetic FSEvents read failure/,
        'phase C: on Unix the read exception is visible' );
}
my ( $mac_closed ) = $mac_backend->{close}->($mac_handle);
ok( $mac_closed, 'phase C: macOS backend closes' );
close $mac_write_fh;
close $unread_write_fh;
diag 'HEARTBEAT: phase C complete';

# Phase D: the F_SETFL death and the portable nonblocking shape.
diag 'HEARTBEAT: phase D starting - Fcntl macros and portable nonblocking';
my $f_setfl_error;
my $f_setfl_defined = eval { my $f_setfl_value = Fcntl::F_SETFL(); 1 } ? 1 : 0;
$f_setfl_error = $@ if !$f_setfl_defined;
diag "HEARTBEAT: phase D F_SETFL defined=$f_setfl_defined"
  . ( $f_setfl_defined ? '' : " error=[$f_setfl_error]" );
is( $f_setfl_defined, $is_windows ? 0 : 1,
    'phase D: F_SETFL is defined on Unix and undefined on Strawberry Perl' );
if ( !$is_windows ) {
    ok( defined eval { my $f_getfl_value = Fcntl::F_GETFL(); 1 }, 'phase D: F_GETFL is defined on Unix' );
    ok( defined eval { my $o_nonblock_value = Fcntl::O_NONBLOCK(); 1 }, 'phase D: O_NONBLOCK is defined on Unix' );
}
else {
    my $f_getfl_defined = eval { my $f_getfl_value = Fcntl::F_GETFL(); 1 } ? 1 : 0;
    my $o_nonblock_defined = eval { my $o_nonblock_value = Fcntl::O_NONBLOCK(); 1 } ? 1 : 0;
    diag "HEARTBEAT: phase D Windows F_GETFL defined=$f_getfl_defined "
      . "O_NONBLOCK defined=$o_nonblock_defined";
    ok( 1, 'phase D: Windows F_GETFL/O_NONBLOCK defined-ness recorded, not asserted' );
    ok( 1, 'phase D: Windows F_GETFL/O_NONBLOCK defined-ness recorded, not asserted' );
}
diag 'HEARTBEAT: phase D before blocking(0) on a pipe';
my ( $nb_reader, $nb_writer );
pipe( $nb_reader, $nb_writer ) or die "Unable to create nonblocking test pipe: $!";
$nb_writer->autoflush(1);
my $blocking_ok = eval { $nb_reader->blocking(0); 1 } ? 1 : 0;
my $blocking_error = $@ if !$blocking_ok;
diag "HEARTBEAT: phase D blocking(0) ok=$blocking_ok"
  . ( $blocking_ok ? '' : " error=[$blocking_error]" );
ok( $blocking_ok, 'phase D: IO::Handle->blocking(0) runs on a pipe without dying' );
print {$nb_writer} "data\n" or die "Unable to write nonblocking test pipe: $!";
my $nb_buffer = '';
my $nb_read = sysread( $nb_reader, $nb_buffer, 4096 );
diag "HEARTBEAT: phase D sysread after blocking(0) with data queued: "
  . ( defined $nb_read ? "read=$nb_read [$nb_buffer]" : "undef errno=" . ( 0 + $! ) );
is( $nb_buffer, "data\n", 'phase D: sysread after blocking(0) returns queued data' );
close $nb_writer;
close $nb_reader;

# Phase D child: sysread on an EMPTY pipe after blocking(0). A blocking
# read would hang the harness, so it runs in a child perl with a verdict
# file and a bounded parent poll; the parent kills the child past 10s.
diag 'HEARTBEAT: phase D child starting - empty-pipe sysread after blocking(0)';
my $tmpdir = tempdir( CLEANUP => 1 );
my $child_file = File::Spec->catfile( $tmpdir, 'child.pl' );
my $verdict_file = File::Spec->catfile( $tmpdir, 'verdict.txt' );
diag 'HEARTBEAT: before writing child program';
open my $child_fh, '>', $child_file or die "Unable to write child probe program: $!";
print {$child_fh} <<'CHILD_EOF';
use strict;
use warnings;

# Child: pipe, blocking(0), then sysread on the empty reader. Every path
# writes an OUTCOME line to the verdict file except a genuinely blocking
# read, which the parent detects by timeout and kills.
my ($verdict_file) = @ARGV;
open my $vf, '>', $verdict_file or exit 99;
my $selected = select($vf); $| = 1; select($selected);
print {$vf} "pid=$$\n";
require IO::Handle;
pipe( my $reader, my $writer ) or do {
    print {$vf} "OUTCOME: pipe-failed $!\n";
    close $vf;
    exit 2;
};
$writer->autoflush(1);
my $blocking_ok = eval { $reader->blocking(0); 1 } ? 1 : 0;
print {$vf} "blocking=$blocking_ok\n";
if ( !$blocking_ok ) {
    my $error = $@;
    $error =~ s/\n/ /g;
    print {$vf} "OUTCOME: blocking-died $error\n";
    close $vf;
    exit 0;
}
my $buffer = '';
my $read = sysread( $reader, $buffer, 4096 );
if ( defined $read ) {
    print {$vf} "OUTCOME: sysread-returned-$read\n";
}
elsif ( $!{EAGAIN} || $!{EWOULDBLOCK} ) {
    print {$vf} "OUTCOME: nonblocking-eagain errno=" . ( 0 + $! ) . "\n";
}
else {
    my $error = "$!";
    $error =~ s/\n/ /g;
    print {$vf} "OUTCOME: sysread-undef errno=" . ( 0 + $! ) . " $error\n";
}
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
ok( -f $child_file && $child_slurp =~ /OUTCOME: nonblocking-eagain/,
    'child probe program written with the verdict shapes' );

diag 'HEARTBEAT: spawning child for the empty-pipe read';
my ( $in, $out, $err ) = ( gensym, gensym, gensym );
my $pid = open3( $in, $out, $err, $^X, $child_file, $verdict_file );
close $in;
my $verdict = '';
my $deadline = time() + 10;
my $polls = 0;
while ( time() < $deadline ) {
    if ( open my $vf, '<', $verdict_file ) {
        local $/;
        my $content = <$vf>;
        close $vf;
        if ( defined $content && $content =~ /OUTCOME: (\S+)/ ) {
            $verdict = $1;
            last;
        }
    }
    $polls++;
    diag "HEARTBEAT: waiting for child verdict poll=$polls" if $polls % 10 == 0;
    select( undef, undef, undef, 0.2 );
}
if ( !$verdict ) {
    my $child_pid = '';
    if ( open my $vf, '<', $verdict_file ) {
        local $/;
        my $content = <$vf>;
        close $vf;
        ($child_pid) = defined $content ? $content =~ /pid=(\d+)/ : ();
    }
    diag "HEARTBEAT: child produced no verdict in 10s, killing pid=$child_pid";
    kill 9, $child_pid if $child_pid ne '';
    $verdict = 'hung';
}
waitpid( $pid, 0 );
close $out;
close $err;
diag "HEARTBEAT: child verdict=$verdict polls=$polls";
if ($is_windows) {
    ok( $verdict eq 'nonblocking-eagain' || $verdict eq 'hung',
        "phase D: Windows empty-pipe verdict is $verdict (eagain proves blocking(0) works, hung proves it does not)" );
}
else {
    is( $verdict, 'nonblocking-eagain',
        'phase D: empty-pipe sysread after blocking(0) returns EAGAIN on Unix' );
}

# Phase D PeekNamedPipe: the established product primitive for Windows
# pipe readiness (StreamDrain.pm). Skipped off Windows.
SKIP: {
    skip 'PeekNamedPipe is Windows-only', 2 if !$is_windows;
    diag 'HEARTBEAT: phase D PeekNamedPipe starting';
    my $peek = eval {
        require Win32API::File;
        require Win32::API;
        my $imported = Win32::API->new( 'kernel32', 'PeekNamedPipe', 'QPIPPP', 'I' );
        die "Could not import PeekNamedPipe from kernel32\n" if !defined $imported;
        $imported;
    };
    ok( defined $peek, 'phase D: PeekNamedPipe imports from kernel32' );
    my ( $peek_reader, $peek_writer );
    pipe( $peek_reader, $peek_writer ) or die "Unable to create peek test pipe: $!";
    $peek_writer->autoflush(1);
    my $os_handle = Win32API::File::GetOsFHandle($peek_reader);
    my $avail_empty = _peek_available( $peek, $os_handle );
    diag "HEARTBEAT: phase D PeekNamedPipe empty pipe: "
      . ( defined $avail_empty ? "$avail_empty bytes" : 'undef' );
    print {$peek_writer} "change\n" or die "Unable to write peek test pipe: $!";
    my $avail_full = _peek_available( $peek, $os_handle );
    diag "HEARTBEAT: phase D PeekNamedPipe after write: "
      . ( defined $avail_full ? "$avail_full bytes" : 'undef' );
    is( $avail_full, 7, 'phase D: PeekNamedPipe reports 7 bytes after writing "change\\n"' );
    close $peek_writer;
    close $peek_reader;
}

diag 'HEARTBEAT: micro complete';

# _peek_available($peek, $handle)
# Reports how many bytes are waiting on one Windows pipe, without blocking.
# Input: imported PeekNamedPipe function object and one real Win32 HANDLE.
# Output: byte count, or undef when the call fails. Copied from
# StreamDrain::_windows_pipe_available, the product's established shape.
sub _peek_available {
    my ( $peek, $handle ) = @_;
    return undef if !defined $handle;
    $^E = 0;
    my $bytes_read  = pack 'L', 0;
    my $total_avail = pack 'L', 0;
    my $bytes_left  = pack 'L', 0;
    my $ok = $peek->Call( $handle, '', 0, $bytes_read, $total_avail, $bytes_left );
    return undef if !$ok;
    return unpack 'L', $total_avail;
}

package Local::Micro995FSEvents;

# watch()
# Returns the injected event stream descriptor used by the adapter test.
# Input: fake FSEvents object.
# Output: readable event stream filehandle.
sub watch { return $_[0]->{fh} }

# read_events()
# Drains a readiness signal in the fake event stream.
# Input: fake FSEvents object.
# Output: empty event list after consuming queued bytes.
sub read_events {
    my ($self) = @_;
    my $buffer = '';
    sysread( $self->{fh}, $buffer, 4096 );
    return ();
}

# stop()
# Closes the injected descriptor when the adapter is shut down.
# Input: fake FSEvents object.
# Output: true when the descriptor closes successfully.
sub stop { return CORE::close( $_[0]->{fh} ) }

package Local::Micro995UnreadableFSEvents;

# watch()
# Returns the event descriptor supplied by the test fixture.
# Input: fake stream object with an open descriptor.
# Output: descriptor watched by IO::Select.
sub watch { return $_[0]->{fh} }

# read_events()
# Simulates a native FSEvents read failure after readiness.
# Input: fake stream object.
# Output: never returns; throws an explicit fixture error.
sub read_events {
    $main::micro995_read_events_called++;
    die "synthetic FSEvents read failure\n";
}

# stop()
# Closes the test descriptor when the adapter is shut down.
# Input: fake stream object.
# Output: true when the descriptor closes successfully.
sub stop { return CORE::close( $_[0]->{fh} ) }

__END__

=pod

=head1 NAME

995-micro-t669-windows-pipe.t - probe the Windows t/669 pipe-readability failures

=head1 DESCRIPTION

This micro proves the mechanism behind the Windows-only failures of
t/669-problem48-inotify-watch.t in Jenkins builds #368 and #369, byte-identical
on the fix tip and the pre-fix tip, so they are pre-existing and the t/669
OOM fix caused none of them: tests 13, 83, 88 and 89 fail, and the file then
dies at line 737 because Strawberry Perl does not define the Fcntl macro
F_SETFL. Every one of the four failures writes to a pipe and expects the
read end to show readable. The product already knows the underlying fact:
StreamDrain.pm documents that select() on Windows only works for real
sockets, and drains Windows pipes with PeekNamedPipe instead.

=for comment FULL-POD-DOC START

=head1 PURPOSE

This micro is the executable evidence for the Windows t/669 pipe failures.
Read it when you need to know whether IO::Select->can_read on a pipe never
fires on Windows, which product call sites return the wrong answer there,
whether the four failures are one mechanism, and what portable shape
replaces the F_SETFL nonblocking setup that Strawberry Perl cannot express.

=head1 WHY IT EXISTS

It exists because the four Windows failures in t/669 share one suspected
mechanism that was never proven: IO::Select->can_read on a pipe handle.
The same root cause killed the t/88 SSL hang, fixed in 1c1034de by probing
getsockopt SO_TYPE first, and the product already works around it in
StreamDrain, PageRuntime, SkillDispatcher and SkillManager. A micro that
runs the exact write-then-poll shape on all four legs, drives both product
call sites with the t/669 fixtures, and measures the F_SETFL alternatives
settles whether the fix belongs in the product readiness check, in the
test fixtures, or both.

=head1 WHEN TO USE

Use this file while deciding the t/669 Windows fix, and delete it in the
cleanup commit once the fix is solo-verified, like every other probe micro.

=head1 HOW TO USE

Run it as a Jenkins solo with TEST_FILE=t/995-micro-t669-windows-pipe.t,
then read the per-leg outcomes from the console output. Do not run it by
hand outside Jenkins. The empty-pipe sysread runs in a spawned child perl
with a verdict file and a bounded 10-second parent poll, so a blocking
read can only kill the child, never the harness.

=head1 WHAT USES IT

The loop owner uses it to choose the t/669 Windows fix: a pipe-aware
readiness check in Watch.pm (PeekNamedPipe on Windows, following
StreamDrain.pm), a test-fixture change, or both, plus the portable
replacement for the F_SETFL nonblocking setup. Nothing else uses it.

=head1 EXAMPLES

Example 1:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/995-micro-t669-windows-pipe.t 1

Trigger the probe solo and read the per-leg outcomes from the console.

Example 2:

  grep -n "PHASE" ~/workspace/goals/developer-dashboard-pr-73-windows-support/hidden_files/jenkins-build-<n>-console.txt

Read the phase outcomes per leg from the saved console.

=for comment FULL-POD-DOC END

=cut
