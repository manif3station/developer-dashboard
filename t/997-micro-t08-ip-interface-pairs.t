use strict;
use warnings;
use utf8;

use Capture::Tiny qw(capture);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test::More;

plan tests => 12;

# Micro-probe for round 41, Jenkins build #376: t/08-web-update-coverage.t
# fails on Windows only, tests 132-133, both clean assertions:
#   not ok 132 - _ip_interface_pairs falls back to ifconfig parsing when
#     the ip command yields no candidates (t/08 line 607)
#       $got->[0]{ip} = '100.73.80.14' (the node's real Tailscale IP)
#       $expected->[0]{ip} = '10.0.0.4'
#   not ok 133 - _ip_interface_pairs falls back to ipconfig parsing when
#     Windows ipconfig output is available (t/08 line 654)
#       $got->[0]{ip} = '100.73.80.14'
#       $expected->[0]{ip} = '10.20.30.40'
# Both tests stub _ip_pairs_from_ip to () and put a fake ifconfig/ipconfig
# FIRST on PATH, so the product should only ever see the stubbed output.
# It sees the machine's real address instead. The leading hypothesis is
# a resolution split: command_in_path('ipconfig') finds the fake .cmd
# first on PATH (PATHEXT-aware, PATH order), so the product's gate
# passes - but the product then runs a BARE system 'ipconfig', which
# Perl resolves through CreateProcess: System32 comes before PATH in
# that search order, and CreateProcess does not run .cmd files, so the
# real C:\Windows\System32\ipconfig.exe runs and returns the real
# addresses. That is the same class as the t/09 taskkill lesson (bare
# taskkill in system() is resolved by CreateProcess, which never runs
# the fake taskkill.bat). Test 132 has a second layer: on Windows
# _ip_interface_pairs tries ipconfig BEFORE ifconfig, so while a real
# ipconfig exists the ifconfig fallback is unreachable no matter what
# the fake ifconfig prints. This micro proves each link with marker
# files (did the fake actually execute?) and the parsed pairs, and
# tests whether resolving the command first (the t/09 fix shape) makes
# the fake win.

my $repo_root = File::Spec->catdir( $FindBin::Bin, '..' );
require lib;
lib->import( File::Spec->catdir( $repo_root, 'lib' ) );

use Developer::Dashboard::PerlEnv;
use Developer::Dashboard::Platform qw(command_in_path);
use Developer::Dashboard::Web::App;

my $is_windows = $^O eq 'MSWin32' ? 1 : 0;
diag "HEARTBEAT: context perl=$^V os=$^O windows=$is_windows";

# The methods under test never deref $self (they only dispatch through
# it), so a blessed empty hash is the whole fixture; t/08 builds a full
# App, this micro does not need one.
my $app = bless {}, 'Developer::Dashboard::Web::App';

my $tmpdir  = tempdir( CLEANUP => 1 );
my $fake_bin = File::Spec->catdir( $tmpdir, 'fake-bin' );
make_path($fake_bin);

my $ipconfig_marker = File::Spec->catfile( $tmpdir, 'ipconfig-ran.txt' );
my $ifconfig_marker = File::Spec->catfile( $tmpdir, 'ifconfig-ran.txt' );
$ENV{MICRO_IPCONFIG_MARKER} = $ipconfig_marker;
$ENV{MICRO_IFCONFIG_MARKER} = $ifconfig_marker;

# _write_fake($name, $windows_body, $unix_body)
# Writes one fake command into fake-bin: a .cmd file on Windows, a
# #!/bin/sh script elsewhere. Both bodies start by writing their marker
# file, so marker existence proves that exact file executed.
# Input: command name and the two platform bodies.
# Output: absolute path of the fake file.
sub _write_fake {
    my ( $name, $windows_body, $unix_body ) = @_;
    my $path = File::Spec->catfile( $fake_bin, $is_windows ? "$name.cmd" : $name );
    open my $fh, '>', $path or die "Unable to write fake $name: $!";
    print {$fh} $is_windows ? $windows_body : $unix_body;
    close $fh or die "Unable to close fake $name: $!";
    chmod 0755, $path or die "Unable to chmod fake $name: $!" if !$is_windows;
    return $path;
}

diag 'HEARTBEAT: before writing fake commands';
_write_fake( 'ipconfig',
    "\@echo off\n"
      . "echo FAKE-RAN > %MICRO_IPCONFIG_MARKER%\n"
      . "echo.\n"
      . "echo Ethernet adapter Ethernet:\n"
      . "echo.\n"
      . "echo    IPv4 Address. . . . . . . . . . . : 10.20.30.40\n"
      . "echo.\n"
      . "echo Wireless LAN adapter Loopback:\n"
      . "echo.\n"
      . "echo    IPv4 Address. . . . . . . . . . . : 127.0.0.1\n",
    "#!/bin/sh\n"
      . "echo FAKE-RAN > \"\$MICRO_IPCONFIG_MARKER\"\n"
      . "cat <<'EOF'\n"
      . "\n"
      . "Ethernet adapter Ethernet:\n"
      . "\n"
      . "   IPv4 Address. . . . . . . . . . . : 10.20.30.40\n"
      . "\n"
      . "Wireless LAN adapter Loopback:\n"
      . "\n"
      . "   IPv4 Address. . . . . . . . . . . : 127.0.0.1\n"
      . "EOF\n",
);
_write_fake( 'ifconfig',
    "\@echo off\n"
      . "echo FAKE-RAN > %MICRO_IFCONFIG_MARKER%\n"
      . "echo eth0: flags=4163^<UP,BROADCAST,RUNNING,MULTICAST^>  mtu 1500\n"
      . "echo     inet 10.0.0.4  netmask 255.255.255.0  broadcast 10.0.0.255\n"
      . "echo lo: flags=73^<UP,LOOPBACK,RUNNING^>  mtu 65536\n"
      . "echo     inet 127.0.0.1  netmask 255.0.0.0\n",
    "#!/bin/sh\n"
      . "echo FAKE-RAN > \"\$MICRO_IFCONFIG_MARKER\"\n"
      . "cat <<'EOF'\n"
      . "eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500\n"
      . "    inet 10.0.0.4  netmask 255.255.255.0  broadcast 10.0.0.255\n"
      . "lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536\n"
      . "    inet 127.0.0.1  netmask 255.0.0.0\n"
      . "EOF\n",
);
diag 'HEARTBEAT: after writing fake commands';

# The fake bin goes FIRST on PATH, exactly as t/08 does it.
local $ENV{PATH} = $fake_bin . Developer::Dashboard::PerlEnv::path_separator() . $ENV{PATH};

# _pair_ips(@pairs)
# Joins the ip values of a pair list for diag output.
# Input: list of { iface, ip } hashes.
# Output: comma-joined ip strings, or '(none)'.
sub _pair_ips {
    my (@pairs) = @_;
    return '(none)' if !@pairs;
    return join ',', map { $_->{ip} } @pairs;
}

# Phase A - the resolution gap: does the gate see the fake, and does
# the bare system() call run it?
diag 'HEARTBEAT: phase A command_in_path';
my $resolved_ipconfig = command_in_path('ipconfig');
my $resolved_ifconfig = command_in_path('ifconfig');
diag "HEARTBEAT: phase A resolved ipconfig=" . ( $resolved_ipconfig // '(undef)' );
diag "HEARTBEAT: phase A resolved ifconfig=" . ( $resolved_ifconfig // '(undef)' );
like( $resolved_ipconfig // '', qr/^\Q$fake_bin\E/, 'phase A: command_in_path(ipconfig) resolves under fake-bin' );
like( $resolved_ifconfig // '', qr/^\Q$fake_bin\E/, 'phase A: command_in_path(ifconfig) resolves under fake-bin' );

diag 'HEARTBEAT: phase A _ip_pairs_from_ipconfig';
my @ipconfig_pairs = $app->_ip_pairs_from_ipconfig;
my $ipconfig_marker_ran = -f $ipconfig_marker ? 1 : 0;
diag "HEARTBEAT: phase A ipconfig marker ran=$ipconfig_marker_ran pairs=" . _pair_ips(@ipconfig_pairs);
is( $ipconfig_marker_ran, $is_windows ? 0 : 1,
    'phase A: fake ipconfig runs on Unix, never on Windows (bare system resolves to System32)' );
my $ipconfig_has_stub = ( grep { $_->{ip} eq '10.20.30.40' } @ipconfig_pairs ) ? 1 : 0;
is( $ipconfig_has_stub, $is_windows ? 0 : 1,
    'phase A: stubbed 10.20.30.40 parsed on Unix, absent on Windows (real ipconfig ran)' );

diag 'HEARTBEAT: phase A _ip_pairs_from_ifconfig';
my @ifconfig_pairs = $app->_ip_pairs_from_ifconfig;
my $ifconfig_marker_ran = -f $ifconfig_marker ? 1 : 0;
diag "HEARTBEAT: phase A ifconfig marker ran=$ifconfig_marker_ran pairs=" . _pair_ips(@ifconfig_pairs);
ok( !$ifconfig_marker_ran || ( grep { $_->{ip} eq '10.0.0.4' } @ifconfig_pairs ),
    'phase A: if a fake ifconfig ran, its output was parsed into 10.0.0.4' );
ok( $ifconfig_marker_ran || !@ifconfig_pairs,
    'phase A: if no fake ifconfig ran, no pairs were returned' );

# Phase B - the fallback order: reproduce t/08 tests 132 and 133
# exactly, with the same stubs and the same fake-bin-first PATH.
diag 'HEARTBEAT: phase B t/08 test 132 shape';
{
    no warnings 'redefine';
    local *Developer::Dashboard::Web::App::_ip_pairs_from_ip = sub { return (); };
    my @pairs = $app->_ip_interface_pairs;
    diag 'HEARTBEAT: phase B test 132 pairs=' . _pair_ips(@pairs);
    my $first_ip = @pairs ? $pairs[0]{ip} : '';
    if ($is_windows) {
        ok( $first_ip ne '10.0.0.4',
            'phase B: t/08 test 132 shape on Windows returns a real address, never the stubbed 10.0.0.4' );
    }
    else {
        is( $first_ip, '10.0.0.4', 'phase B: t/08 test 132 shape on Unix returns the stubbed 10.0.0.4' );
    }
    my $has_stub = ( grep { $_->{ip} eq '10.0.0.4' } @pairs ) ? 1 : 0;
    is( $has_stub, $is_windows ? 0 : 1,
        'phase B: t/08 test 132 shape has the stubbed address on Unix only' );
}

diag 'HEARTBEAT: phase B t/08 test 133 shape';
{
    no warnings 'redefine';
    local *Developer::Dashboard::Web::App::_ip_pairs_from_ip       = sub { return (); };
    local *Developer::Dashboard::Web::App::_ip_pairs_from_ifconfig = sub { return (); };
    local *Developer::Dashboard::Web::App::is_windows              = sub { return 1; };
    my @pairs = $app->_ip_interface_pairs;
    diag 'HEARTBEAT: phase B test 133 pairs=' . _pair_ips(@pairs);
    my $first_ip = @pairs ? $pairs[0]{ip} : '';
    if ($is_windows) {
        ok( $first_ip ne '10.20.30.40',
            'phase B: t/08 test 133 shape on Windows returns a real address, never the stubbed 10.20.30.40' );
    }
    else {
        is( $first_ip, '10.20.30.40', 'phase B: t/08 test 133 shape on Unix returns the stubbed 10.20.30.40' );
    }
}

# Phase C - the fix-shape primitive: resolve first (the t/09
# taskkill pattern), then execute the resolved absolute path.
diag 'HEARTBEAT: phase C resolved-path system()';
unlink $ipconfig_marker;
my $resolved = command_in_path('ipconfig');
my ($captured) = capture { system $resolved; };
my $resolved_marker_ran = -f $ipconfig_marker ? 1 : 0;
diag "HEARTBEAT: phase C resolved marker ran=$resolved_marker_ran captured="
  . ( defined $captured ? substr( $captured, 0, 80 ) : '(undef)' );
ok( $resolved_marker_ran, 'phase C: system() on the resolved ipconfig path runs the fake on every leg' );
like( $captured // '', qr/10\.20\.30\.40/, 'phase C: resolved-path capture contains the stubbed 10.20.30.40' );

# Phase D - the System32 premise, stated directly.
diag 'HEARTBEAT: phase D System32 ipconfig';
my $system32_ipconfig = File::Spec->catfile( $ENV{SystemRoot} // 'C:\\Windows', 'System32', 'ipconfig.exe' );
diag "HEARTBEAT: phase D system32 ipconfig=$system32_ipconfig exists=" . ( -f $system32_ipconfig ? 1 : 0 );
is( -f $system32_ipconfig ? 1 : 0, $is_windows ? 1 : 0,
    'phase D: a real ipconfig.exe sits in System32 on Windows, nowhere on Unix' );

diag 'HEARTBEAT: micro complete';

=head1 NAME

997-micro-t08-ip-interface-pairs.t - probe the Windows t/08 _ip_interface_pairs failures from round 41

=head1 DESCRIPTION

Round 41 (build #376) fails on Windows only, t/08-web-update-coverage.t
tests 132-133: both tests stub _ip_pairs_from_ip to () and put a fake
ifconfig/ipconfig FIRST on PATH, expecting only the stubbed addresses
(10.0.0.4 / 10.20.30.40), but the product returns the node's real
Tailscale IP 100.73.80.14. The leading hypothesis is a resolution split:
command_in_path('ipconfig') finds the fake .cmd first on PATH, so the
gate passes, but the bare system 'ipconfig' is resolved through
CreateProcess, where System32 comes before PATH and .cmd files do not
run, so the real System32 ipconfig.exe executes. Test 132 has a second
layer: on Windows _ip_interface_pairs tries ipconfig BEFORE ifconfig,
so while a real ipconfig exists the ifconfig fallback is unreachable.
This micro proves each link with marker files (did the fake actually
execute?) and the parsed pairs, reproduces both t/08 shapes exactly,
and tests whether resolving the command first (the t/09 taskkill fix
shape) makes the fake win.

=for comment FULL-POD-DOC START

=head1 PURPOSE

This micro is the executable evidence for the round-41 t/08 failures.
Read it when you need to know why the stubbed ifconfig/ipconfig output
never reaches the product on Windows, which call lets the real address
in, whether the stubbed parsing works on its own, and whether the
resolve-first fix shape makes the fake win.

=head1 WHY IT EXISTS

It exists because the two failures look like a stub that does not take
hold, and the fix depends entirely on which link breaks: a gate that
does not see the fake, a system() call that does not run the fake, or
a fallback order that never reaches the fake. Guessing wrong would
repeat the t/09 lesson (the gate and the execution resolved the same
bare name through two different mechanisms).

=head1 WHEN TO USE

Use this file while deciding the t/08 fix, and delete it in the cleanup
commit once the fix is solo-verified, like every other probe micro.

=head1 HOW TO USE

Run it as a Jenkins solo with TEST_FILE=t/997-micro-t08-ip-interface-pairs.t,
then read the per-phase verdicts from the console output. Do not run it
by hand outside Jenkins. Every phase prints HEARTBEAT diags, and no
phase can block: the only external calls are the fake/real ipconfig and
ifconfig invocations, each of which returns at once.

=head1 WHAT USES IT

The loop owner uses it to choose the t/08 fix: resolve-first execution
in the product, a fallback-order change, or a test-side change to the
two fixtures. Nothing else uses it.

=head1 EXAMPLES

Example 1:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/997-micro-t08-ip-interface-pairs.t 1

Trigger the probe solo and read the per-phase verdicts from the console.

Example 2:

  grep -n "HEARTBEAT: phase" ~/workspace/goals/developer-dashboard-pr-73-windows-support/hidden_files/jenkins-build-<n>-console.txt

Read the phase verdicts per leg from the saved console.

=for comment FULL-POD-DOC END

=cut
