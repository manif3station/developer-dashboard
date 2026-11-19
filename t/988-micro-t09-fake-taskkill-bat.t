use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes qw(sleep);

use lib 'lib';

use Developer::Dashboard::Config;
use Developer::Dashboard::Collector;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;

# Micro: find out why the fake taskkill.bat from the t/09 test 395
# block does not produce its args file on the real Windows host.
# Build #269 (t/09 solo at 506feb09) died reading the args file
# after test 395 passed, so _send_signal returned 2 via its forgive
# path for the nonexistent pids without the fake ever running. The
# suspects are: system() does not find or run a .bat on PATH; the
# .bat runs but its redirect fails; or the file lands elsewhere.
# This micro isolates the mechanism: it builds the same fake, first
# runs system() on it directly, then runs _send_signal, and reports
# after each step whether the args file exists and what it holds,
# plus the raw system() return and $?. It only makes sense on
# Windows; on other hosts it proves the shell-script fake instead.

my $IS_WINDOWS = $^O eq 'MSWin32';
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = File::Spec->catdir( $home, 'state' );
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
my $files = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $manager = Developer::Dashboard::RuntimeManager->new(
    app_builder => sub { die "app builder should not run here\n" },
    config      => $config,
    files       => $files,
    paths       => $paths,
    runner      => bless( {}, 'Local::SignalTestRunner' ),
);

plan tests => 3;

my $fakebin = tempdir( CLEANUP => 1 );
my $taskkill = File::Spec->catfile( $fakebin, $IS_WINDOWS ? 'taskkill.bat' : 'taskkill' );
my $args_file = File::Spec->catfile( $fakebin, 'taskkill.args' );
diag "before - writing the fake to $taskkill";
open my $taskkill_fh, '>', $taskkill or die "Unable to write $taskkill: $!";
if ($IS_WINDOWS) {
    print {$taskkill_fh} "\@echo off\r\n";
    print {$taskkill_fh} 'echo %* > "' . $args_file . "\"\r\n";
    print {$taskkill_fh} "exit /b 0\r\n";
}
else {
    print {$taskkill_fh} <<"SCRIPT";
#!/bin/sh
printf '%s\n' "\$*" > "$args_file"
exit 0
SCRIPT
}
close $taskkill_fh or die "Unable to close $taskkill: $!";
chmod 0755, $taskkill or die "Unable to chmod $taskkill: $!";
diag "after - fake written, exists=" . ( -f $taskkill ? 1 : 0 );
ok( -f $taskkill, 'fake taskkill file exists' );
diag 'before - reading the fake back';
open my $read_fh, '<', $taskkill or die "Unable to read $taskkill: $!";
local $/;
my $fake_content = <$read_fh>;
close $read_fh or die "Unable to close $taskkill: $!";
diag "after - fake content=[$fake_content]";

my $path_sep = $IS_WINDOWS ? ';' : ':';
local $ENV{PATH} = join( $path_sep, $fakebin, ( $ENV{PATH} || '' ) );
diag 'before - direct system() call to the fake';
my $sys_rc = system( 'taskkill', '/PID', '2372', '/PID', '5868', '/T', '/F' );
my $sys_status = $? >> 8;
diag "after - system() returned $sys_rc status=$sys_status args_exists=" . ( -f $args_file ? 1 : 0 );
my $direct_args = '';
if ( -f $args_file ) {
    open my $afh, '<', $args_file or die "Unable to read $args_file: $!";
    local $/;
    $direct_args = <$afh> // '';
    close $afh or die "Unable to close $args_file: $!";
}
diag "after - direct args=[$direct_args]";
ok( $direct_args =~ m{/PID 2372 /PID 5868 /T /F}, 'direct system() runs the fake taskkill and records its arguments' );

unlink $args_file if -f $args_file;
diag 'before - _send_signal through the product';
# _send_signal takes the Windows branch only when is_windows() is
# true; on a Unix host that needs the same OS_NAME forcing the t/09
# block uses, or it takes the POSIX kill path and never runs taskkill.
my $send_result;
{
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    $send_result = $manager->_send_signal( 'TERM', 2372, 5868 );
}
diag "after - _send_signal returned $send_result args_exists=" . ( -f $args_file ? 1 : 0 );
my $send_args = '';
if ( -f $args_file ) {
    open my $afh, '<', $args_file or die "Unable to read $args_file: $!";
    local $/;
    $send_args = <$afh> // '';
    close $afh or die "Unable to close $args_file: $!";
}
diag "after - _send_signal args=[$send_args]";
ok( $send_result == 2 && $send_args =~ m{/PID 2372 /PID 5868 /T /F}, '_send_signal shells out to the fake taskkill with every requested pid plus tree and force flags' );

__END__

=head1 NAME

t/988-micro-t09-fake-taskkill-bat.t - find out why the fake taskkill.bat never runs

=head1 PURPOSE

Build #269 died reading the fake taskkill's args file after test 395
passed, so _send_signal returned 2 through its forgive path for the
nonexistent pids without the fake ever running. This micro isolates
the mechanism: it builds the same fake taskkill (a .bat on Windows,
a shell script elsewhere), runs system() on it directly, then runs
_send_signal, and reports after each step whether the args file
exists and what it holds, plus the raw system() return and status.

=head1 WHY IT EXISTS

The t/09 test 395 block was fixed to use a .bat on Windows (commit
506feb09) on the assumption that system() finds and runs a .bat on
PATH. Build #269 proved that assumption wrong somewhere - the args
file was never created - but the failure does not say whether
system() failed to find it, failed to run it, or ran it and the
redirect failed. Guessing again would burn another solo; measuring
first is cheaper.

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/988-micro-t09-fake-taskkill-bat.t)
on the loop branch, or locally with prove after make. Remove the file
in a cleanup commit when the t/09 fix is verified.

=head1 HOW TO USE

Commit it to windows/loop6-combined, push, then trigger a solo with
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined
t/988-micro-t09-fake-taskkill-bat.t 1. Read the diag lines: the fake
content as written, the direct system() return and status, and the
args file contents after the direct call and after _send_signal.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a diagnostic micro for
the t/09 test 395 failure in build #269, in the testing-v1 loop.

=head1 EXAMPLES

If the direct system() call creates the args file but _send_signal
does not, the difference is in how _send_signal invokes it (its
capture wrapper, or the argument list it builds). If even the direct
call creates nothing, system() itself does not run a .bat from PATH
on this host, and the test needs a different fake (for example a
real executable, or a stubbed capture).

=cut
