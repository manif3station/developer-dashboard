use strict;
use warnings;

use Capture::Tiny qw(capture);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use IPC::Open3 qw(open3);
use POSIX qw(WNOHANG);
use Test::More;
use Time::HiRes qw(sleep time);

# The benchmark script under test, and the library it must load.
my $script   = "$Bin/../script/problem48-status-route-benchmark";
my $repo_lib = abs_path("$Bin/../lib");
my $tmpdir   = tempdir( 'micro-t672-portable-XXXXXX', CLEANUP => 1, TMPDIR => 1 );

# _run_capture(@args)
# Runs the benchmark exactly the way t/672 does (Capture::Tiny around a
# list-form system call) and reports the FULL wait status, not just the
# shifted exit code: a child that dies by signal yields ($? >> 8) == 0,
# so the test's exit check passes while stdout stays empty.
# Input: benchmark arguments.
# Output: (raw_wait_status, stdout, stderr).
sub _run_capture {
    my (@args) = @_;
    my ( $stdout, $stderr, $raw ) = capture {
        local $ENV{P48_LIB} = $repo_lib;
        system( $^X, $script, @args );
        return $?;
    };
    return ( $raw, $stdout, $stderr );
}

# _wait_status($raw)
# Decodes a raw wait status into exit code, signal number and core flag.
# Input: raw wait status.
# Output: (exit_code, signal, core_flag).
sub _wait_status {
    my ($raw) = @_;
    return ( ( $raw >> 8 ), ( $raw & 127 ), ( $raw & 128 ) ? 1 : 0 );
}

# _diag_run($label, $raw, $stdout, $stderr)
# Logs one run's full outcome as a heartbeat line.
# Input: label, raw wait status, captured stdout and stderr.
# Output: none.
sub _diag_run {
    my ( $label, $raw, $stdout, $stderr ) = @_;
    my ( $exit, $signal, $core ) = _wait_status($raw);
    my $head = substr( $stdout, 0, 120 );
    $head =~ s/\n/\\n/g;
    diag "# HEARTBEAT: $label exit=$exit signal=$signal core=$core "
      . "stdout_len=" . length($stdout) . " stderr_len=" . length($stderr)
      . " stdout_head=[$head]";
}

my @portable_args = ( '--indicators', 2, '--iterations', 1, '--runs', 3,
    '--portable-config-cache' );
my @plain_args = ( '--indicators', 2, '--iterations', 1, '--runs', 3 );

# Phase A: the exact t/672 portable shape, three repeats, full wait status.
diag '# HEARTBEAT: phase A starting, portable repeat 1';
my ( $r1_raw, $r1_out, $r1_err ) = _run_capture(@portable_args);
_diag_run( 'phase A portable repeat 1', $r1_raw, $r1_out, $r1_err );
my ( $r1_exit, $r1_signal, $r1_core ) = _wait_status($r1_raw);
pass("portable repeat 1: wait status captured (exit=$r1_exit signal=$r1_signal core=$r1_core)");

diag '# HEARTBEAT: phase A starting, portable repeat 2';
my ( $r2_raw, $r2_out, $r2_err ) = _run_capture(@portable_args);
_diag_run( 'phase A portable repeat 2', $r2_raw, $r2_out, $r2_err );
my ( $r2_exit, $r2_signal, $r2_core ) = _wait_status($r2_raw);
pass("portable repeat 2: wait status captured (exit=$r2_exit signal=$r2_signal core=$r2_core)");

diag '# HEARTBEAT: phase A starting, portable repeat 3';
my ( $r3_raw, $r3_out, $r3_err ) = _run_capture(@portable_args);
_diag_run( 'phase A portable repeat 3', $r3_raw, $r3_out, $r3_err );
my ( $r3_exit, $r3_signal, $r3_core ) = _wait_status($r3_raw);
pass("portable repeat 3: wait status captured (exit=$r3_exit signal=$r3_signal core=$r3_core)");

# Phase A determinism: do the repeats agree with each other?
is( $r2_signal, $r1_signal, 'portable repeats 1-2 agree on signal' );
is( $r3_signal, $r1_signal, 'portable repeats 1-3 agree on signal' );
is( ( $r2_out eq '' ) ? 1 : 0, ( $r1_out eq '' ) ? 1 : 0,
    'portable repeats 1-2 agree on stdout emptiness' );
is( ( $r3_out eq '' ) ? 1 : 0, ( $r1_out eq '' ) ? 1 : 0,
    'portable repeats 1-3 agree on stdout emptiness' );

# Phase A control: the plain (non-portable) shape, which passed on ARM64
# in round 41. It must still produce the automatic report everywhere.
diag '# HEARTBEAT: phase A starting, plain control run';
my ( $c_raw, $c_out, $c_err ) = _run_capture(@plain_args);
_diag_run( 'phase A plain control', $c_raw, $c_out, $c_err );
my ( $c_exit, $c_signal, $c_core ) = _wait_status($c_raw);
is( $c_signal, 0, 'plain control: child did not die by signal' );
like( $c_out, qr/config_snapshot=automatic\b/,
    'plain control: stdout carries the automatic report' );

# Phase B: the same portable invocation through IPC::Open3 with stdout and
# stderr on separate files (not Capture::Tiny), polled with a hard cap.
# This separates "Capture::Tiny lost the output" from "the script printed
# nothing": if both channels agree, the loss is not in the capture layer.
# The handles must be passed in the ">&fd" dup form: a bare handle is
# replaced by open3 with a pipe (the child then writes to the pipe, whose
# read end is never read and the file stays empty - proven in a minimal
# probe: trivial child, exit 0, both files empty with bare handles, both
# correct with the dup form).
my $b_out_file = "$tmpdir/open3-stdout.txt";
my $b_err_file = "$tmpdir/open3-stderr.txt";
open my $b_out_fh, '>', $b_out_file or die "Unable to open $b_out_file: $!";
open my $b_err_fh, '>', $b_err_file or die "Unable to open $b_err_file: $!";
diag '# HEARTBEAT: phase B starting, open3 portable run';
my $b_pid;
{
    local $ENV{P48_LIB} = $repo_lib;
    $b_pid = open3( undef, '>&' . fileno($b_out_fh), '>&' . fileno($b_err_fh),
        $^X, $script, @portable_args );
}
my $b_raw     = 0;
my $b_reaped  = 0;
my $b_started = time;
my $b_polls   = 0;
while (1) {
    my $done = waitpid( $b_pid, WNOHANG );
    if ( $done == $b_pid ) {
        $b_raw    = $?;
        $b_reaped = 1;
        last;
    }
    if ( $done == -1 ) {
        diag '# HEARTBEAT: phase B waitpid returned -1, falling back to blocking waitpid';
        my $blocked = waitpid( $b_pid, 0 );
        if ( $blocked == $b_pid ) {
            $b_raw    = $?;
            $b_reaped = 1;
        }
        last;
    }
    $b_polls++;
    if ( $b_polls % 30 == 0 ) {
        diag "# HEARTBEAT: phase B still waiting for open3 child after ${b_polls} polls";
    }
    if ( time - $b_started > 120 ) {
        diag '# HEARTBEAT: phase B cap reached, killing open3 child';
        kill 9, $b_pid;
        waitpid( $b_pid, 0 );
        last;
    }
    sleep 0.5;
}
close $b_out_fh;
close $b_err_fh;
my $b_out = do {
    open my $fh, '<', $b_out_file or die "Unable to read $b_out_file: $!";
    local $/;
    <$fh>;
};
my $b_err = do {
    open my $fh, '<', $b_err_file or die "Unable to read $b_err_file: $!";
    local $/;
    <$fh>;
};
$b_out = '' if !defined $b_out;
$b_err = '' if !defined $b_err;
_diag_run( 'phase B open3 portable', $b_raw, $b_out, $b_err );
my ( $b_exit, $b_signal, $b_core ) = _wait_status($b_raw);
ok( $b_reaped, 'open3 portable run: child reaped before the cap' );
is( $b_signal, $r1_signal, 'open3 and capture agree on the portable signal' );
is( ( $b_out eq '' ) ? 1 : 0, ( $r1_out eq '' ) ? 1 : 0,
    'open3 and capture agree on portable stdout emptiness' );

# Phase C: the same portable invocation with stdout/stderr inherited, so
# anything the child prints lands in the prove log directly. Runs last:
# it blocks, and if the child ever hung the watchdog would trip here
# after everything else has already reported.
diag '# HEARTBEAT: phase C starting, inherited portable run';
my $c2_raw;
{
    local $ENV{P48_LIB} = $repo_lib;
    system( $^X, $script, @portable_args );
    $c2_raw = $?;
}
_diag_run( 'phase C inherited portable', $c2_raw, '', '' );
my ( $c2_exit, $c2_signal, $c2_core ) = _wait_status($c2_raw);
pass("inherited portable run: wait status captured (exit=$c2_exit signal=$c2_signal core=$c2_core)");
is( $c2_signal, $r1_signal, 'inherited and capture agree on the portable signal' );

# Phase D: environment diagnostics, and a compile check on the script.
my $arch = $^O eq 'MSWin32' ? ( $ENV{PROCESSOR_ARCHITECTURE} || 'windows' ) : do {
    my $u = `uname -m 2>/dev/null`;
    chomp $u if defined $u;
    $u || $^O;
};
my $load = 'n/a';
if ( open my $lfh, '<', '/proc/loadavg' ) {
    $load = <$lfh>;
    chomp $load if defined $load;
    close $lfh;
}
my $mem = 'n/a';
if ( open my $mfh, '<', '/proc/meminfo' ) {
    while ( my $line = <$mfh> ) {
        if ( $line =~ /^MemTotal:\s+(\d+)/ ) { $mem = "total ${1}kB"; last; }
    }
    close $mfh;
}
diag "# HEARTBEAT: environment perl=$] arch=$arch load=[$load] mem=[$mem] script=$script";
pass('environment recorded');
diag '# HEARTBEAT: phase D starting, script compile check';
my ( $cc_out, $cc_err, $cc_raw ) = capture {
    local $ENV{P48_LIB} = $repo_lib;
    system( $^X, '-c', $script );
    return $?;
};
my ( $cc_exit, $cc_signal, $cc_core ) = _wait_status($cc_raw);
diag "# HEARTBEAT: compile check exit=$cc_exit signal=$cc_signal stderr=[$cc_err]";
is( $cc_exit, 0, 'benchmark script compiles' );

# Outcome lines: the verdicts the parent adjudicates from.
diag "OUTCOME: portable capture signal=$r1_signal stdout_len=" . length($r1_out)
  . " stderr_len=" . length($r1_err) . " repeats_agree_signal="
  . ( ( $r2_signal == $r1_signal && $r3_signal == $r1_signal ) ? 1 : 0 );
diag "OUTCOME: portable open3 signal=$b_signal stdout_len=" . length($b_out)
  . " inherited signal=$c2_signal plain signal=$c_signal";
diag "OUTCOME: portable stdout empty in capture=" . ( ( $r1_out eq '' ) ? 1 : 0 )
  . " open3=" . ( ( $b_out eq '' ) ? 1 : 0 )
  . " plain stdout carries automatic=" . ( ( $c_out =~ /config_snapshot=automatic/ ) ? 1 : 0 );

done_testing;

__END__

=pod

=head1 NAME

997-micro-t672-portable-empty-output.t - probe the ARM64 portable benchmark's empty output

=head1 PURPOSE

Round 41 failed on ARM64 in t/672 tests 14-15: the portable-config
benchmark subprocess exited 0 with empty stdout and empty stderr, so the
C<config_snapshot=portable> and C<exact_response_parity=yes> assertions saw
nothing. This micro reproduces the exact t/672 portable invocation and
reports the FULL wait status (a child that dies by signal yields
C<< ($? >> 8) == 0 >>, so the test's exit check passes while stdout stays
empty), compares the Capture::Tiny channel against separate-file Open3
capture and inherited handles, and checks determinism across repeats.

=head1 WHY IT EXISTS

The round-41 console proves only that the test saw empty stdout with a
zero shifted exit code. That shape fits at least three different
mechanisms: the child died by signal (masked by the shift), the capture
layer lost the output, or the script really printed nothing. A fix chosen
without distinguishing them would guess. This micro separates the three
before any fix is attempted.

=head1 WHEN TO USE

Run it as a Jenkins solo when the t/672 portable failure needs a mechanism
before a fix, or when re-checking whether the failure still reproduces on
ARM64 after a change elsewhere in the status-route code.

=head1 HOW TO USE

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/997-micro-t672-portable-empty-output.t 1

The micro runs the benchmark six times (three portable repeats through
Capture::Tiny, one plain control, one Open3 run, one inherited run) plus a
compile check. Each run is bounded: the Open3 run polls with a 120-second
cap and a hard kill; the inherited run is last so a hang there loses
nothing already reported.

=head1 WHAT USES IT

The t/672 fix decision uses this probe's verdict: signal death, capture
loss, or genuine empty output each point at a different file and a
different change shape.

=head1 EXAMPLES

  prove -lv t/997-micro-t672-portable-empty-output.t

=cut
