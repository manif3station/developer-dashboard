use strict;
use warnings;
use utf8;

use Config qw(%Config);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

plan tests => 16;

# Micro-probe for round 40, Jenkins build #364: t/669-problem48-inotify-watch.t
# failed ONLY on the ARM64 leg after all 201 subtests passed. The process
# died at the fake-descriptor block (the test that would have been 202):
#   Out of memory in perl:perlio:more_refcounted_fds
#   refcnt_dec: fd 999999999 >= refcnt_size 32
#   Dubious, test returned 255 (wstat 65280, 0xff00)
# The block stubs _xs_inotify_init to return 999_999_999 and calls the
# product's native-backend initialize, which wraps the descriptor with
#   open my $handle, '<&=', $fd
#     or die "Unable to wrap inotify descriptor $fd: $!";
# (Watch.pm _linux_backend). Perlio grows its fd refcount table to cover
# the descriptor number before the open can fail with EBADF, so a bogus
# descriptor of 999_999_999 asks for a ~4GB table: fatal on the Pi, while
# amd64 and macOS passed t/669 in the same round (their allocation
# succeeds and the open then fails cleanly with the expected diagnostic).
# This micro proves that chain without fixing anything: every dangerous
# wrap runs in a spawned child perl, so an out-of-memory death kills only
# the child and the parent records its exit code and stderr. No product
# code and no test file changes; the child programs are written to a
# tempdir and run through IPC::Open3 with real gensym handles.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..' );
my $lib_dir   = File::Spec->catdir( $repo_root, 'lib' );
my $blib_lib  = File::Spec->catdir( $repo_root, 'blib', 'lib' );
my $blib_arch = File::Spec->catdir( $repo_root, 'blib', 'arch' );

diag "HEARTBEAT: context perl=$^V os=$^O arch=$Config{archname}";
if ( $^O eq 'linux' && open my $meminfo, '<', '/proc/meminfo' ) {
    while ( my $line = <$meminfo> ) {
        diag "HEARTBEAT: $line" if $line =~ /^MemTotal:/;
        last if $line =~ /^MemTotal:/;
    }
    close $meminfo;
}
else {
    diag 'HEARTBEAT: MemTotal not read on this leg';
}

my $tmpdir = tempdir( CLEANUP => 1 );
my $child_file = File::Spec->catfile( $tmpdir, 'child.pl' );
diag 'HEARTBEAT: before writing child program';
open my $child_fh, '>', $child_file
  or die "Unable to write child probe program: $!";
print {$child_fh} <<'CHILD_EOF';
use strict;
use warnings;

# One wrap attempt, then exit. All output goes to STDOUT; a perlio
# out-of-memory death kills this child before it can print OUTCOME.
my ( $mode, $fd_arg ) = @ARGV;
my $fd = 0 + $fd_arg;
print "CHILD: mode=$mode fd=$fd\n";

if ( $mode eq 'direct' ) {
    print "CHILD: before direct open\n";
    my $ok = eval { open my $handle, '<&=', $fd or die "wrap failed: $!"; 1 };
    if ($ok) {
        print "OUTCOME: direct-ok\n";
    }
    else {
        my $error = $@;
        $error =~ s/\n/ /g;
        print "OUTCOME: direct-died $error\n";
    }
    print "CHILD: after direct open\n";
    exit 0;
}

if ( $mode eq 'guard-fcntl' ) {
    print "CHILD: before fcntl guard\n";
    require Fcntl;
    my $flags = fcntl( $fd, Fcntl::F_GETFD(), 0 );
    if ( !defined $flags ) {
        print "OUTCOME: guard-tripped fcntl-EBADF\n";
        exit 0;
    }
    print "CHILD: guard passed, wrapping\n";
    my $ok = eval { open my $handle, '<&=', $fd or die "wrap failed: $!"; 1 };
    if ($ok) {
        print "OUTCOME: guard-passed-wrap-ok\n";
    }
    else {
        my $error = $@;
        $error =~ s/\n/ /g;
        print "OUTCOME: guard-passed-wrap-died $error\n";
    }
    exit 0;
}

if ( $mode eq 'guard-range' ) {
    print "CHILD: before range guard\n";
    if ( $fd > 1_048_575 ) {
        print "OUTCOME: guard-tripped range\n";
        exit 0;
    }
    my $ok = eval { open my $handle, '<&=', $fd or die "wrap failed: $!"; 1 };
    if ($ok) {
        print "OUTCOME: guard-passed-wrap-ok\n";
    }
    else {
        my $error = $@;
        $error =~ s/\n/ /g;
        print "OUTCOME: guard-passed-wrap-died $error\n";
    }
    exit 0;
}

# mode eq 'wrap': the exact t/669 shape. The stub and the localized
# operating system must stay installed while initialize runs, exactly
# as the t/669 fake-descriptor block does it.
print "CHILD: before require Watch\n";
my $module = 'Developer::Dashboard::IndicatorStore::Watch';
my $loaded = eval "require $module; 1";
if ( !$loaded ) {
    my $error = $@;
    $error =~ s/\n/ /g;
    print "OUTCOME: load-failed $error\n";
    exit 3;
}
print "CHILD: after require Watch\n";
require Developer::Dashboard::HtmlEscape;
print "CHILD: before native backend\n";
my ( $result, $error, $no_backend );
{
    local $^O = 'linux';
    no warnings qw(redefine once);
    local *Developer::Dashboard::IndicatorStore::Watch::_xs_inotify_init = sub { return $fd; };
    my $backend = $module->_native_backend;
    if ( !defined $backend || ref($backend) ne 'HASH' ) {
        $no_backend = 1;
    }
    else {
        print "CHILD: before initialize\n";
        $result = eval { $backend->{initialize}->(); 1 };
        $error = $@;
    }
}
if ($no_backend) {
    print "OUTCOME: no-backend\n";
    exit 3;
}
if ($result) {
    print "OUTCOME: graceful-ok\n";
}
else {
    $error =~ s/\n/ /g;
    print "OUTCOME: graceful-died $error\n";
}
print "CHILD: after initialize\n";
exit 0;
CHILD_EOF
close $child_fh or die "Unable to close child probe program: $!";
diag 'HEARTBEAT: after writing child program';

my $child_slurp = do {
    open my $slurp_fh, '<', $child_file or die "Unable to re-read child probe program: $!";
    local $/;
    <$slurp_fh>;
};
ok( -f $child_file && $child_slurp =~ /open my \$handle, '<&=', \$fd/,
    'child probe program written with the exact wrap call' );

# run_child($mode, $fd)
# Spawns one child perl running the probe program and returns its exit
# code, signal, stdout, and stderr. A child killed by the out-of-memory
# error dies before printing OUTCOME; the parent classifies it from the
# stderr signature instead. Input: probe mode and descriptor number.
# Output: hash reference with exit, signal, stdout, and stderr.
sub run_child {
    my ( $mode, $fd ) = @_;
    diag "HEARTBEAT: spawning child mode=$mode fd=$fd";
    my ( $in, $out, $err ) = ( gensym, gensym, gensym );
    my $pid = open3(
        $in, $out, $err, $^X,
        '-I' . $lib_dir, '-I' . $blib_lib, '-I' . $blib_arch,
        $child_file, $mode, $fd,
    );
    close $in;
    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    close $out;
    close $err;
    waitpid( $pid, 0 );
    my $status = $?;
    diag "HEARTBEAT: child done mode=$mode fd=$fd status=$status";
    return {
        exit   => $status >> 8,
        signal => $status & 127,
        stdout => defined $stdout ? $stdout : '',
        stderr => defined $stderr ? $stderr : '',
    };
}

# classify($run)
# Names a child outcome from its captured output. Input: a run_child
# result. Output: 'oom' when the child died on the perlio refcount
# allocation, 'graceful' when it caught the wrap failure, anything else
# as 'other' with the raw output in the diagnostics.
sub classify {
    my ($run) = @_;
    return 'oom'
      if $run->{stderr} =~ /Out of memory in perl:perlio:more_refcounted_fds/;
    return 'graceful'
      if $run->{stdout} =~ /OUTCOME: (?:graceful|direct)-died/;
    return 'other';
}

# log_run($label, $run)
# Prints one child outcome verbatim so the console carries the evidence.
# Input: a label and a run_child result. Output: diagnostics only.
sub log_run {
    my ( $label, $run ) = @_;
    diag "$label: exit=$run->{exit} signal=$run->{signal} shape=" . classify($run);
    diag "$label stdout: [$run->{stdout}]";
    diag "$label stderr: [$run->{stderr}]";
}

my $expected_shape = $Config{archname} =~ /aarch64/ ? 'oom' : 'graceful';
diag "HEARTBEAT: phase A starting - exact t/669 shape, fd 999999999, three repeats";
my @phase_a;
for my $repeat ( 1 .. 3 ) {
    diag "HEARTBEAT: phase A repeat $repeat before spawn";
    my $run = run_child( 'wrap', 999_999_999 );
    log_run( "PHASE A repeat $repeat", $run );
    diag "HEARTBEAT: phase A repeat $repeat after spawn";
    push @phase_a, $run;
}
ok( ( grep { classify($_) ne 'other' } @phase_a ) == 3,
    'phase A: all three 999999999 wraps classified as oom or graceful' );
ok( ( grep { classify($_) eq classify( $phase_a[0] ) } @phase_a ) == 3,
    'phase A: all three repeats agree (the outcome is deterministic, not load-dependent)' );
is( classify( $phase_a[0] ), $expected_shape,
    'phase A: outcome matches the round-40 observation for this leg' );
ok(
    ( classify( $phase_a[0] ) eq 'oom'
          && $phase_a[0]{stderr} =~ /Out of memory in perl:perlio:more_refcounted_fds/ )
      || ( classify( $phase_a[0] ) eq 'graceful'
          && $phase_a[0]{stdout} =~ /Unable to wrap inotify descriptor/ ),
    'phase A: child output carries the shape-appropriate diagnostic'
);
is( $phase_a[0]{exit}, classify( $phase_a[0] ) eq 'oom' ? 255 : 0,
    'phase A: child exit code matches the shape' );

diag 'HEARTBEAT: phase B starting - threshold sweep over descriptor size';
my @sweep_fds = ( 1_024, 65_536, 1_000_000, 100_000_000, 999_999_999 );
my %sweep_shapes;
for my $fd (@sweep_fds) {
    diag "HEARTBEAT: phase B fd=$fd before spawn";
    my $run = run_child( 'wrap', $fd );
    my $shape = classify($run);
    $sweep_shapes{$fd} = $shape;
    log_run( "PHASE B fd=$fd", $run );
    diag "HEARTBEAT: phase B fd=$fd after spawn";
    ok( $shape ne 'other', "phase B: fd $fd classified as $shape" );
}
diag 'HEARTBEAT: phase B sweep table: '
  . join( ', ', map { "$_=$sweep_shapes{$_}" } @sweep_fds );

diag 'HEARTBEAT: phase E starting - bare perlio open, no product code';
my $direct_run = run_child( 'direct', 999_999_999 );
log_run( 'PHASE E direct', $direct_run );
ok( classify($direct_run) ne 'other', 'phase E: direct open classified as oom or graceful' );
is( classify($direct_run), classify( $phase_a[0] ),
    'phase E: direct open matches the product-wrap shape (perlio, not product logic)' );

diag 'HEARTBEAT: phase D starting - guard shapes that never reach the wrap';
my $fcntl_run = run_child( 'guard-fcntl', 999_999_999 );
log_run( 'PHASE D fcntl guard', $fcntl_run );
ok( $fcntl_run->{exit} == 0 && $fcntl_run->{stdout} =~ /OUTCOME: guard-tripped fcntl-EBADF/,
    'phase D: fcntl guard trips before any wrap' );
my $range_run = run_child( 'guard-range', 999_999_999 );
log_run( 'PHASE D range guard', $range_run );
ok( $range_run->{exit} == 0 && $range_run->{stdout} =~ /OUTCOME: guard-tripped range/,
    'phase D: range guard trips before any wrap' );
ok( $fcntl_run->{stderr} !~ /Out of memory/
      && $range_run->{stderr} !~ /Out of memory/,
    'phase D: neither guard child touched the perlio refcount table' );

diag 'HEARTBEAT: micro complete';

__END__

=pod

=head1 NAME

996-micro-t669-fake-fd-oom.t - probe the ARM64 t/669 out-of-memory death

=head1 DESCRIPTION

This micro proves the mechanism behind the round-40 failure of
t/669-problem48-inotify-watch.t on the ARM64 leg. All 201 subtests passed
and the process then died at the fake-descriptor block with "Out of memory
in perl:perlio:more_refcounted_fds" and "refcnt_dec: fd 999999999 >=
refcnt_size 32". Every dangerous wrap runs in a spawned child perl, so an
out-of-memory death kills only the child and the parent records its exit
code and stderr.

=for comment FULL-POD-DOC START

=head1 PURPOSE

This micro is the executable evidence for the t/669 ARM64 out-of-memory
mechanism. Read it when you need to know whether the death is perlio
growing its descriptor refcount table for a bogus descriptor, whether it
is deterministic, where the size threshold sits, and which guard shape
avoids it, instead of guessing from the two-line diagnostic.

=head1 WHY IT EXISTS

It exists because the failure is a known pre-existing ARM64-only failure
whose mechanism was never proven: the test passes on amd64 and macOS and
dies on the Pi after 201 passing tests. A micro that runs the exact wrap
in an isolated child on all four legs, sweeps the descriptor size, and
tries both guard shapes settles whether the fix belongs in the product
wrap path and what shape it should take.

=head1 WHEN TO USE

Use this file while deciding the t/669 ARM64 out-of-memory fix, and delete
it in the cleanup commit once the fix is solo-verified, like every other
probe micro.

=head1 HOW TO USE

Run it as a Jenkins solo with TEST_FILE=t/996-micro-t669-fake-fd-oom.t,
then read the per-leg child outcomes and the threshold table from the
console output. Do not run it by hand outside Jenkins. The child programs
are written to a temporary directory and run through IPC::Open3 with real
gensym handles; no test file and no product code is changed by this probe.

=head1 WHAT USES IT

The loop owner uses it to choose the t/669 fix: a descriptor validity
check before the wrap in the Linux native backend, or a range bound on
the descriptor, with the measured threshold as the evidence. Nothing else
uses it.

=head1 EXAMPLES

Example 1:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/996-micro-t669-fake-fd-oom.t 1

Trigger the probe solo and read the child outcomes per leg.

Example 2:

  grep -n "PHASE B" ~/workspace/goals/developer-dashboard-pr-73-windows-support/hidden_files/jenkins-build-<n>-console.txt

Read the threshold sweep table per leg from the saved console.

=for comment FULL-POD-DOC END

=cut
