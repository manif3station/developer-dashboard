#!/usr/bin/env perl

# M7 (R178): the whole remaining coverage tail.
#
# Cover build #19 measured the suite at stmt 98.6, branch 96.7, cond
# 95.6, sub 99.4, total 97.6, with the 98.0 gate failing on branch
# and condition only. The remaining gap is 330 uncovered branch
# cells + 177 uncovered condition cells + 14 uncovered subs across
# 35 modules (full inventory in
# hidden_files/m7-prework-gaps-cover19.txt). R178 rules M7 as the
# whole tail: cover every uncovered cell and sub except the five
# carve-outs below. The goal is the gate: branch and condition to
# 98.0. Largest modules first (Platform, RuntimeManager, GoRoutine,
# CollectorRunner, Web/Server, SkillManager), then the rest.
#
# THE FIVE CARVE-OUTS (R178). Uncoverable unless a real trigger is
# found; report with probe evidence, do not fake:
# (1) CommandRunner 126/127, the print/close or die sides.
# (2) OpenFile 562, the or-3 cell ($rc != -1 and $! set).
# (3) OpenFile 558 __ANON__, the warn handler - only runs if
# system() itself warns, and the M7 pre-work probes show it does
# not on the failure paths.
# (4) Watch 344, the open that never fails.
# (5) RuntimeManager 2101, the die with empty/undef $@.
#
# THE METHOD (M5/M6 pattern). Windows-only code is driven with
# mocked Win32 primitives and localised $OS_NAME on Unix; the
# Jenkins proof drives it for real on the Windows legs. Only the
# dispatch gate is platform-specific - the pure-Perl logic under it
# runs unmocked. Private subs are called directly by fully qualified
# name where the public entry cannot reach them on Unix.
#
# THE UNCOVERABLE REMAINDER. Some cells sit behind is_real_windows(),
# which reads a load-time lexical that no test can localise on Unix
# (Platform.pm line 34: my $_REAL_OS_IS_WINDOWS = $^O eq 'MSWin32').
# Those cells - the windows_acl_is_owner_only body past its gate,
# the effective_mode_octal Windows side, the is_real_windows true
# side itself, and their siblings - cannot fire on the ARM64 cover
# run, and the Windows legs run the tests plain, with no coverage.
# They are NOT faked here: each is named in the section header with
# the reason, and reported to Ryan with the probe evidence. R178:
# if after covering the reachable tail the gate still fails on
# uncoverable cells only, report it - do not fake.
#
# THE CHILDREN. A spawned child process does NOT count toward
# coverage on the Jenkins cover run (it execs a fresh perl that
# never loads Devel::Cover - proven by the M6 fd-exhaustion child,
# whose OpenFile 501 cell is still open in cover #19). So a test
# whose whole point is a coverage cell must run IN the test
# process. Tests that only assert behaviour (an exit code, a die)
# may still use spawned children (GoRoutine's native process API,
# R169: t/246 forbids a direct fork() in t/). The _capture
# handle-save probes below run in-process by localising the STDOUT
# or STDERR glob, which makes the save open fail without ever
# touching the real file descriptor.
#
# WRITE WITH SYSWRITE. A print to a pipe handle buffers: the bytes
# sit in Perl's output buffer and never reach the pipe until the
# handle is flushed or closed. Every write to a test pipe below
# uses syswrite, which is unbuffered. (No pipes are used in this
# file; the rule is kept here because the child scripts write
# files, and print to a file handle is checked with `or die`
# wherever it matters.)

use strict;
use warnings;

use Config;
use File::Spec;
use File::Temp qw(tempdir tempfile);
use FindBin qw($Bin);
use Test::More;
use Time::HiRes ();

use lib File::Spec->catdir( $Bin, '..', 'lib' );

use Developer::Dashboard::GoRoutine ();

require_ok('Developer::Dashboard::Platform');

my $IS_WINDOWS = $^O eq 'MSWin32';
my $REPO_ROOT  = File::Spec->catdir( $Bin, '..' );

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
        Time::HiRes::sleep(0.05);
    }
    kill 'KILL', $pid;
    Developer::Dashboard::GoRoutine::wait_process($pid);
    return undef;
}

# _make_executable($path, $content): writes a file and marks it
# executable, so command_in_path and the runnable checks can find it.
# Input: file path and content string.
# Output: none.
sub _make_executable {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print $fh $content or die "Unable to write $path: $!";
    close $fh or die "Unable to write $path: $!";
    chmod 0755, $path or die "Unable to chmod $path: $!";
    return;
}

# =====================================================================
# SECTION 1 - Platform.pm (57 branch + 17 condition cells + 7 subs)
#
# The Windows ACL block (lines 202-291) is pct=0 in cover #19: the
# subs were never called on ARM64. They are called directly here,
# with the $SYSTEM_LAUNCHER primitive stubbed (the M6 shape: fake
# only the launch, drive the pure-Perl parsing and DACL logic for
# real). The uncoverable remainder in this section is the code past
# the is_real_windows() gate - windows_acl_is_owner_only lines
# 260-272, effective_mode_octal lines 337-361, the is_real_windows
# true side itself (line 63), the windows_acl_can_set_owner_only
# real-Windows check (line 330), and the _capture redirect/restore
# opens that can only fail on an OS-level error (lines 148-149,
# 164-168). Each is named where it stands below, with the reason.
# =====================================================================

# _slurp_raw_file: a directory reads as undef, so the
# defined-or-empty side (line 191 false) fires. An empty file
# does NOT do it: in slurp mode readline returns '' for empty
# input, so $contents is defined (probed).
{
    my $dir = tempdir( CLEANUP => 1 );
    my $empty = File::Spec->catfile( $dir, 'empty.txt' );
    open my $fh, '>', $empty or die "Unable to write $empty: $!";
    close $fh or die "Unable to write $empty: $!";
    is( Developer::Dashboard::Platform::_slurp_raw_file($empty), '', 'slurp: empty file returns empty string' );
    my $full = File::Spec->catfile( $dir, 'full.txt' );
    open $fh, '>', $full or die "Unable to write $full: $!";
    print $fh "hello\n" or die "Unable to write $full: $!";
    close $fh or die "Unable to write $full: $!";
    is( Developer::Dashboard::Platform::_slurp_raw_file($full), "hello\n", 'slurp: non-empty file returns its contents' );
    is( Developer::Dashboard::Platform::_slurp_raw_file( File::Spec->catfile( $dir, 'missing.txt' ) ),
        '', 'slurp: missing file returns empty string' );
    is( Developer::Dashboard::Platform::_slurp_raw_file($dir), '',
        'slurp: directory returns empty string through the undef side' );
}

# _capture tempfile reopens (lines 136-137): stub tempfile in the
# Platform namespace so the reopened name sits in a directory that
# does not exist, and the open fails. The die is outside the eval,
# so it propagates out of _capture.
{
    my $dir = tempdir( CLEANUP => 1 );
    my ( $real_fh1, $real_name1 ) = tempfile( DIR => $dir, UNLINK => 0 );
    my ( $real_fh2, $real_name2 ) = tempfile( DIR => $dir, UNLINK => 0 );
    my $call = 0;
    my $died = eval {
        local *Developer::Dashboard::Platform::tempfile = sub {
            $call++;
            return ( $real_fh1, $real_name1 ) if $call == 1;
            return ( $real_fh2, File::Spec->catfile( $dir, 'no-such-dir', 'capture.err' ) );
        };
        Developer::Dashboard::Platform::_capture( sub { 1 } );
        1;
    };
    my $error = $@;
    ok( !$died, 'capture: second tempfile reopen failure dies' );
    like( $error, qr/Unable to open capture file/, 'capture: second reopen die names the capture file' );
    unlink $real_name1;
    unlink $real_name2;
    my ( $real_fh3, $real_name3 ) = tempfile( DIR => $dir, UNLINK => 0 );
    $died = eval {
        local *Developer::Dashboard::Platform::tempfile = sub {
            return ( $real_fh3, File::Spec->catfile( $dir, 'no-such-dir', 'capture.out' ) );
        };
        Developer::Dashboard::Platform::_capture( sub { 1 } );
        1;
    };
    $error = $@;
    ok( !$died, 'capture: first tempfile reopen failure dies' );
    like( $error, qr/Unable to open capture file/, 'capture: first reopen die names the capture file' );
    unlink $real_name3;
}

# _capture handle saves (lines 146-147, 163, 167): localise the
# STDOUT or STDERR glob in-process, open it onto /dev/null and
# close it, so the save open dups a closed handle and RETURNS
# false (the `or die` runs) - without ever touching the real fd,
# which stays open for the harness. A merely localised (never
# opened) glob is NOT enough: the dup open CROAKS with "Bad
# filehandle" instead of returning false, so Devel::Cover never
# counts the branch (probed). The die message names the save;
# the restore is skipped for the handle that never saved.
# (The first version of this probe ran in a spawned child; that
# is wrong for coverage - a child exec does not load Devel::Cover
# on the Jenkins cover run, so its cells never count. Proof: the
# M6 fd-exhaustion child was meant to cover the OpenFile 501
# open-failure cell, and cover #19 still shows C 501 cells=1,0,3.
# Coverage cells must be hit in the test process itself.)
{
    my $died = eval {
        local *STDOUT;
        open STDOUT, '>', '/dev/null' or die "Unable to open /dev/null: $!";
        close STDOUT or die "Unable to close STDOUT: $!";
        Developer::Dashboard::Platform::_capture( sub { 1 } );
        1;
    };
    my $error = $@;
    ok( !$died, 'capture: closed STDOUT makes the save fail' );
    like( $error, qr/Unable to save stdout for capture/, 'capture: closed STDOUT die names the save' );

    $died = eval {
        local *STDERR;
        open STDERR, '>', '/dev/null' or die "Unable to open /dev/null: $!";
        close STDERR or die "Unable to close STDERR: $!";
        Developer::Dashboard::Platform::_capture( sub { 1 } );
        1;
    };
    $error = $@;
    ok( !$died, 'capture: closed STDERR makes the save fail' );
    like( $error, qr/Unable to save stderr for capture/, 'capture: closed STDERR die names the save' );
    print "capture: real STDOUT still works after the closed-glob probes\n";
}

# NOTE (uncoverable, Platform 148-149, 163 false side, 164-168):
# the redirect opens and the restore opens duplicate handles that
# were opened on the lines directly above and are never closed
# before use, so they can only fail on an OS-level error no caller
# can arrange. The false sides (opens succeed) run on every
# _capture call; the true sides stand as uncoverable. The
# `if (defined $saved_out)` false side at line 163 is uncoverable
# for a different reason, proven by probe (/tmp/m7-child-probe,
# replica.pl): a failed dup open leaves the lexical DEFINED - the
# IO object is created and the dup then fails - so $saved_out is
# defined at restore whether the save succeeded or not, and the
# false side can never fire. (The $saved_err false side at line
# 167 IS covered: when the stdout save dies first, the stderr
# save never runs and $saved_err stays undef.) The restore warnings
# the probes print ("Unable to restore stdout", "Unable to restore
# stderr") are the expected noise of the localised-glob probes,
# not failures. No test is faked for any of them.

# _windows_current_user: the environment path (lines 202-203) and
# the whoami fallback (lines 205-208), with the $SYSTEM_LAUNCHER
# primitive stubbed so no real whoami runs.
{
    my $dir = tempdir( CLEANUP => 1 );
    {
        local $ENV{USERNAME}   = 'jsmith';
        local $ENV{USERDOMAIN} = 'ACME';
        is( Developer::Dashboard::Platform::_windows_current_user(), 'ACME\jsmith',
            'current user: domain and user from environment' );
    }
    {
        local $ENV{USERNAME} = 'jsmith';
        local $ENV{USERDOMAIN};
        delete $ENV{USERDOMAIN};
        is( Developer::Dashboard::Platform::_windows_current_user(), 'jsmith',
            'current user: bare user when no domain is set' );
    }
    {
        local $ENV{USERNAME}   = 'jsmith';
        local $ENV{USERDOMAIN} = '';
        is( Developer::Dashboard::Platform::_windows_current_user(), 'jsmith',
            'current user: bare user when the domain is empty' );
    }
    {
        local $ENV{USERNAME} = '';
        local $ENV{USERDOMAIN} = 'ACME';
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
            print "ACME\\jsmith\n";
            $? = 0;
            return 0;
        };
        is( Developer::Dashboard::Platform::_windows_current_user(), 'ACME\jsmith',
            'current user: whoami fallback when USERNAME is empty' );
    }
    {
        local $ENV{USERNAME};
        delete $ENV{USERNAME};
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
            print "ACME\\jsmith\n";
            $? = 0;
            return 0;
        };
        is( Developer::Dashboard::Platform::_windows_current_user(), 'ACME\jsmith',
            'current user: whoami fallback when USERNAME is unset' );
    }
    {
        local $ENV{USERNAME};
        delete $ENV{USERNAME};
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
            $? = 256;
            return 1;
        };
        is( Developer::Dashboard::Platform::_windows_current_user(), undef,
            'current user: undef when whoami fails' );
    }
    {
        local $ENV{USERNAME};
        delete $ENV{USERNAME};
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
            $? = 0;
            return 0;
        };
        is( Developer::Dashboard::Platform::_windows_current_user(), undef,
            'current user: undef when whoami prints nothing' );
    }
    {
        local $ENV{USERNAME};
        delete $ENV{USERNAME};
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
            print "   \n";
            $? = 0;
            return 0;
        };
        is( Developer::Dashboard::Platform::_windows_current_user(), undef,
            'current user: undef when whoami prints only whitespace' );
    }
}

# _windows_icacls_aces: fake icacls output through the stubbed
# launcher - a path-prefixed first line, a plain ACE line, an empty
# line, a non-ACE trailer line, and an inherited ACE.
{
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'file.txt' );
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print $fh "x" or die "Unable to write $path: $!";
    close $fh or die "Unable to write $path: $!";
    my $fake = "$path ACME\\jsmith:(F)\n"
      . "ACME\\other:(DENY)(F)\n"
      . "\n"
      . "Successfully processed 1 files; Failed processing 0 files\n"
      . "BUILTIN\\Administrators:(I)(F)\n";
    local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
        print $fake;
        $? = 0;
        return 0;
    };
    my $aces = Developer::Dashboard::Platform::_windows_icacls_aces($path);
    is_deeply(
        $aces,
        [
            [ 'ACME\jsmith',              '(F)' ],
            [ 'ACME\other',               '(DENY)(F)' ],
            [ 'BUILTIN\Administrators',   '(I)(F)' ],
        ],
        'icacls aces: parses the path-prefixed, plain and inherited lines, skips the rest'
    );
    {
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
            $? = 256;
            return 1;
        };
        is( Developer::Dashboard::Platform::_windows_icacls_aces($path), undef,
            'icacls aces: undef when icacls fails' );
    }
}

# windows_acl_is_owner_only: the guard returns (lines 257-258).
# NOTE (uncoverable, Platform 260-272): everything past line 258
# runs only when is_real_windows() is true, which reads the
# load-time lexical and is always false on Unix. The DACL logic
# itself is driven below through windows_acl_set_owner_only and
# _windows_icacls_aces, which have no such gate.
{
    my $dir = tempdir( CLEANUP => 1 );
    is( Developer::Dashboard::Platform::windows_acl_is_owner_only(undef), undef,
        'acl is owner only: undef path returns undef' );
    is( Developer::Dashboard::Platform::windows_acl_is_owner_only(''), undef,
        'acl is owner only: empty path returns undef' );
    is( Developer::Dashboard::Platform::windows_acl_is_owner_only( File::Spec->catfile( $dir, 'missing.txt' ) ),
        undef, 'acl is owner only: missing path returns undef' );
    my $file = File::Spec->catfile( $dir, 'file.txt' );
    open my $fh, '>', $file or die "Unable to write $file: $!";
    close $fh or die "Unable to write $file: $!";
    is( Developer::Dashboard::Platform::windows_acl_is_owner_only($file), undef,
        'acl is owner only: existing path returns undef off Windows' );
}

# windows_acl_set_owner_only: the guards and both grant shapes,
# with icacls stubbed. The __ANON__ capture closure at line 289
# runs through _capture on every call below.
{
    my $dir = tempdir( CLEANUP => 1 );
    my @seen;
    my $stub_ok = sub {
        push @seen, [@_];
        print "Successfully processed 1 files\n";
        $? = 0;
        return 0;
    };
    {
        local $ENV{USERNAME}   = 'jsmith';
        local $ENV{USERDOMAIN} = 'ACME';
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = $stub_ok;
        my $file = File::Spec->catfile( $dir, 'file.txt' );
        open my $fh, '>', $file or die "Unable to write $file: $!";
        close $fh or die "Unable to write $file: $!";
        is( Developer::Dashboard::Platform::windows_acl_set_owner_only($file), $file,
            'acl set owner only: file returns its path' );
        is( $seen[-1][4], 'ACME\jsmith:F', 'acl set owner only: file grant has no inherit flags' );
        my $subdir = File::Spec->catdir( $dir, 'sub' );
        mkdir $subdir or die "Unable to mkdir $subdir: $!";
        is( Developer::Dashboard::Platform::windows_acl_set_owner_only($subdir), $subdir,
            'acl set owner only: directory returns its path' );
        is( $seen[-1][4], 'ACME\jsmith:(OI)(CI)F', 'acl set owner only: directory grant carries OI and CI' );
    }
    my $died = eval { Developer::Dashboard::Platform::windows_acl_set_owner_only(undef); 1 };
    ok( !$died, 'acl set owner only: undef path dies' );
    like( $@, qr/Missing path for Windows owner-only ACL/, 'acl set owner only: undef path die message' );
    $died = eval { Developer::Dashboard::Platform::windows_acl_set_owner_only(''); 1 };
    ok( !$died, 'acl set owner only: empty path dies' );
    like( $@, qr/Missing path for Windows owner-only ACL/, 'acl set owner only: empty path die message' );
    {
        local $ENV{USERNAME};
        delete $ENV{USERNAME};
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
            $? = 256;
            return 1;
        };
        $died = eval {
            Developer::Dashboard::Platform::windows_acl_set_owner_only( File::Spec->catfile( $dir, 'file.txt' ) );
            1;
        };
        ok( !$died, 'acl set owner only: unknown user dies' );
        like( $@, qr/Unable to determine the current Windows user/, 'acl set owner only: unknown user die message' );
    }
    {
        local $ENV{USERNAME}   = 'jsmith';
        local $ENV{USERDOMAIN} = 'ACME';
        local $Developer::Dashboard::Platform::SYSTEM_LAUNCHER = sub {
            print "Access is denied.\n";
            $? = 256;
            return 1;
        };
        $died = eval {
            Developer::Dashboard::Platform::windows_acl_set_owner_only( File::Spec->catfile( $dir, 'file.txt' ) );
            1;
        };
        ok( !$died, 'acl set owner only: failing icacls dies' );
        like( $@, qr/Unable to set owner-only ACL/, 'acl set owner only: failing icacls die message' );
    }
}

# windows_acl_can_set_owner_only and _acl_probe_result: the
# DD_TEST_WINDOWS_ACL hook in both contexts, including the
# defined-but-neither-0-nor-1 value (line 325 cell).
# NOTE (uncoverable, Platform 63, 330, 337-339, 358-361): the
# is_real_windows true side itself, the real-Windows probe in
# windows_acl_can_set_owner_only, and the effective_mode_octal
# Windows side all need a real Windows runtime. On Unix the probe
# answers capable through the mode-bits path.
{
    {
        local $ENV{DD_TEST_WINDOWS_ACL} = '0';
        my ( $ok, $reason ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok, 0, 'acl probe: env 0 is incapable in list context' );
        like( $reason, qr/icacls/, 'acl probe: env 0 reason names icacls' );
        is( scalar Developer::Dashboard::Platform::windows_acl_can_set_owner_only(), 0,
            'acl probe: env 0 is incapable in scalar context' );
    }
    {
        local $ENV{DD_TEST_WINDOWS_ACL} = '1';
        my ( $ok, $reason ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok, 1, 'acl probe: env 1 is capable in list context' );
        is( $reason, undef, 'acl probe: env 1 reason is undef' );
        is( scalar Developer::Dashboard::Platform::windows_acl_can_set_owner_only(), 1,
            'acl probe: env 1 is capable in scalar context' );
    }
    {
        local $ENV{DD_TEST_WINDOWS_ACL} = '2';
        my ( $ok, $reason ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok, 1, 'acl probe: env 2 falls through to the real check and is capable on Unix' );
        is( $reason, undef, 'acl probe: env 2 reason is undef' );
    }
    {
        local $ENV{DD_TEST_WINDOWS_ACL};
        delete $ENV{DD_TEST_WINDOWS_ACL};
        my ( $ok, $reason ) = Developer::Dashboard::Platform::windows_acl_can_set_owner_only();
        is( $ok, 1, 'acl probe: env unset is capable on Unix' );
        is( $reason, undef, 'acl probe: env unset reason is undef' );
    }
}

# command_in_path: the '.' and canonpath '.' skips (line 449),
# and the -f return.
{
    my $dir = tempdir( CLEANUP => 1 );
    _make_executable( File::Spec->catfile( $dir, 'm7probe-tool' ), "#!/bin/sh\nexit 0\n" );
    {
        local $ENV{PATH} = join $Config{path_sep}, '.', $dir;
        is( Developer::Dashboard::Platform::command_in_path('m7probe-tool'),
            File::Spec->catfile( $dir, 'm7probe-tool' ), 'command in path: dot dir is skipped' );
    }
    {
        local $ENV{PATH} = join $Config{path_sep}, './', $dir;
        is( Developer::Dashboard::Platform::command_in_path('m7probe-tool'),
            File::Spec->catfile( $dir, 'm7probe-tool' ), 'command in path: dot-slash dir is skipped' );
    }
    {
        local $ENV{PATH} = join $Config{path_sep}, '', $dir;
        is( Developer::Dashboard::Platform::command_in_path('m7probe-tool'),
            File::Spec->catfile( $dir, 'm7probe-tool' ), 'command in path: empty dir is skipped' );
    }
}

# command_in_path_direct on simulated Windows (lines 476-480):
# the empty-dir and dot-dir skips, and the .exe return through
# the PATHEXT expansion.
# NOTE (uncoverable, Platform 476 cell 1, 624 false side, C 624
# middle cell): File::Spec->path rewrites empty PATH entries to
# '.' on Unix, so the !defined/empty $dir cell can never fire
# (the probe below proves it: the empty entry arrives as '.', and
# the dot skip fires twice). And the _path_candidates early-return
# false side needs is_real_windows() true with is_windows()
# false - probed directly (b624.pl): a simulated-Windows call
# leaves B 624 at 0/0, because Devel::Cover only counts the
# branch when the early return fires; the missing cell is the
# is_real_windows side either way.
{
    my $dir = tempdir( CLEANUP => 1 );
    _make_executable( File::Spec->catfile( $dir, 'wintool.exe' ), "echo hi\n" );
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    local $ENV{PATH} = join $Config{path_sep}, '', '.', $dir;
    is( Developer::Dashboard::Platform::command_in_path_direct('wintool'),
        File::Spec->catfile( $dir, 'wintool.exe' ), 'command in path direct: empty and dot dirs skipped, exe found' );
}

# _is_windows_runnable_candidate: the .go and .java returns
# (lines 663-664), called directly. The files must exist: the
# last check reads the shebang, which dies on a missing file.
{
    my $dir = tempdir( CLEANUP => 1 );
    for my $name (qw(main.go Main.java notes.txt)) {
        my $path = File::Spec->catfile( $dir, $name );
        open my $fh, '>', $path or die "Unable to write $path: $!";
        print $fh "plain\n" or die "Unable to write $path: $!";
        close $fh or die "Unable to write $path: $!";
    }
    is( Developer::Dashboard::Platform::_is_windows_runnable_candidate( File::Spec->catfile( $dir, 'main.go' ) ), 1,
        'runnable candidate: go source counts' );
    is( Developer::Dashboard::Platform::_is_windows_runnable_candidate( File::Spec->catfile( $dir, 'Main.java' ) ), 1,
        'runnable candidate: java source counts' );
    is( Developer::Dashboard::Platform::_is_windows_runnable_candidate( File::Spec->catfile( $dir, 'notes.txt' ) ), 0,
        'runnable candidate: plain text does not count' );
}

# resolve_runnable_file on simulated Windows (line 517): a real
# file that is not a Windows runnable candidate reaches the
# simulation-repair line with is_windows() true.
# NOTE (uncoverable, Platform 517 true side and its l&&r cell):
# the return itself needs is_real_windows() true, which the
# comment on the line says cannot fire on real Linux - and the
# condition cell that is still open in cover #19 is exactly that
# l&&r cell (cells 1,36,0: the !l and l&&!r cells are covered by
# the suite already). The probe below pins the reached-line
# behaviour; it cannot move the cell.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $txt = File::Spec->catfile( $dir, 'notes.txt' );
    open my $fh, '>', $txt or die "Unable to write $txt: $!";
    print $fh "plain\n" or die "Unable to write $txt: $!";
    close $fh or die "Unable to write $txt: $!";
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( Developer::Dashboard::Platform::resolve_runnable_file($txt), undef,
        'resolve runnable: text file is not runnable on simulated Windows' );
}

# command_argv_for_path on simulated Windows: the shebang block
# (lines 549-553). A sh shebang routes through the POSIX shell; a
# python shebang fails the sh/bash match and falls through to the
# extension chain.
# NOTE (uncoverable, Platform 549/552 true sides, 551): the open
# and close of a file that was just resolved can only fail on an
# OS-level error, and the readline // '' side needs a file that
# has a shebang for the first read and nothing for the second.
{
    my $dir = tempdir( CLEANUP => 1 );
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my $sh = File::Spec->catfile( $dir, 'run.sh' );
    _make_executable( $sh, "#!/bin/sh\necho hi\n" );
    my @argv = Developer::Dashboard::Platform::command_argv_for_path($sh);
    is( $argv[1], $sh, 'argv for path: sh shebang routes through the POSIX shell' );
    like( $argv[0], qr/sh\z/, 'argv for path: sh shebang uses a sh binary' );
    my $py = File::Spec->catfile( $dir, 'run2.sh' );
    _make_executable( $py, "#!/usr/bin/env python\nprint(1)\n" );
    @argv = Developer::Dashboard::Platform::command_argv_for_path($py);
    is( $argv[1], $py, 'argv for path: non-shell shebang falls through to the extension chain' );
}

# _git_for_windows_roots: the same root reached twice (lines
# 788, 792) - once from the git on PATH, once from ProgramFiles.
# And the empty-parts cell (line 786): a bare 'git' found through
# an empty PATH entry has no directory part, so @parts is empty.
# NOTE (uncoverable, Platform 767 false, 788 false, 782 cell,
# 786 !l cell): _git_for_windows_roots only returns roots that
# contain usr/bin/sh.exe, so the -f check in
# _git_for_windows_shell can never fail there; the git-derived
# push is first, so its seen guard can never fire;
# command_in_path never returns an empty string, so the
# defined-but-empty git cell cannot fire; and the @parts-empty
# cell needs a git with no directory part, which command_in_path
# can never return - it skips '' and '.' PATH entries, so the
# only such git is '/git' at the filesystem root (probed: PATH ':'
# returns no roots at all).
{
    my $dir  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $dir, 'Git' );
    mkdir $root or die "Unable to mkdir: $!";
    mkdir File::Spec->catdir( $root, 'cmd' ) or die "Unable to mkdir: $!";
    mkdir File::Spec->catdir( $root, 'usr' ) or die "Unable to mkdir: $!";
    mkdir File::Spec->catdir( $root, 'usr', 'bin' ) or die "Unable to mkdir: $!";
    _make_executable( File::Spec->catfile( $root, 'cmd', 'git' ), "#!/bin/sh\nexit 0\n" );
    _make_executable( File::Spec->catfile( $root, 'usr', 'bin', 'sh.exe' ), "fake\n" );
    local $ENV{PATH} = join $Config{path_sep}, File::Spec->catdir( $root, 'cmd' ), $ENV{PATH};
    local $ENV{ProgramFiles} = $dir;
    my @roots = Developer::Dashboard::Platform::_git_for_windows_roots();
    is_deeply( \@roots, [$root], 'git roots: the same root reached twice is listed once' );
    my $shell = Developer::Dashboard::Platform::_git_for_windows_shell('sh');
    is( $shell, File::Spec->catfile( $root, 'usr', 'bin', 'sh.exe' ),
        'git shell: resolves sh.exe under the deduped root' );
}

# _posix_shell_binary: the first term of its fallback chain
# (line 749 cell) - bash on PATH.
{
    my $bash = Developer::Dashboard::Platform::_posix_shell_binary('bash');
    like( $bash, qr/bash\z/, 'posix shell binary: bash on PATH resolves first' );
}

# _is_msys_shell: the undef and empty guards (line 805).
{
    is( Developer::Dashboard::Platform::_is_msys_shell(undef), 0, 'msys shell: undef is not an MSYS shell' );
    is( Developer::Dashboard::Platform::_is_msys_shell(''),    0, 'msys shell: empty string is not an MSYS shell' );
    is( Developer::Dashboard::Platform::_is_msys_shell('/c/Git/usr/bin/sh.exe'), 1,
        'msys shell: Git for Windows sh counts' );
    is( Developer::Dashboard::Platform::_is_msys_shell('/usr/bin/sh'), 1,
        'msys shell: the match is suffix-based, so a Unix usr/bin/sh counts too' );
    is( Developer::Dashboard::Platform::_is_msys_shell('/usr/local/bin/sh'), 0,
        'msys shell: a sh outside usr/bin does not count' );
    is( Developer::Dashboard::Platform::_is_msys_shell('C:\tools\bash.exe'), 0,
        'msys shell: a bash outside usr/bin does not count' );
}

# =====================================================================
# SECTION 2 - RuntimeManager.pm (43 branch + 33 condition cells + 1 sub)
#
# The supervisor child (lines 1954-1963) never runs in the suite, so
# it is driven in-process with a runner whose running_loops dies on
# its first two calls and the shutdown stubbed to die instead of
# exiting (POSIX::_exit would end the test process). The Windows
# process-tree rows, the watcher stop and the send-signal wait are
# driven with fake powershell and taskkill scripts on PATH (the M6
# shape: fake only the launch, drive the pure-Perl logic for real).
# The _same_pid_namespace false side (line 4216) is driven with a
# fixture proc tree: ProcessSupervision::$PROCFS_ROOT localised to a
# directory holding symlinks for $$ (the real namespace id) and
# 999999 (a different one). No real process in another namespace
# exists on the cover host (probed: every pid shares one id), so the
# fixture is the only way the comparison can answer false.
#
# UNCOVERABLE IN THIS SECTION (probed, not faked):
# - B 2101 / C 2101 (carve-out 5) and B 2614 / C 2614 and C 2590:
#   all three need $@ undef or empty after an eval dies. Probed
#   (/tmp/m7-rm-probe/die-undef.pl): die undef leaves $@ as
#   "Died at ...", 46 chars, defined; a clean eval leaves $@ as
#   the empty string, defined. A die always leaves a defined
#   non-empty $@, and a clean eval never reaches the line because
#   the !$finished guard skips it. No real trigger exists.
# - C 2495 l&&!r: _resolved_home_from_env never returns the empty
#   string (source-read: every return checks ne "" first, and the
#   fallthrough returns undef). The defined-but-empty home cannot
#   occur.
# - B 3817: Capture::Tiny always returns a defined stdout string
#   (probed: true, false, missing command and closed STDOUT all
#   return ""), so the !defined $stdout side can never fire.
# - C 2380 l&&!r: parsed tree rows always carry a defined started
#   (the (\d*) capture matches empty, never undef).
# - C 2247 !l&&r: same Capture::Tiny reason as B 3817 - stdout is
#   never undef on an exit-0 run.
# - B 2312 true: the || true side inside the sort comparator is
#   never recorded by Devel::Cover. Probed three ways (the G3 test
#   with five same-depth children, an isolated module probe with
#   mixed depths whose comparator demonstrably reordered, and a
#   plain-script sort probe): the false side records, the true side
#   never does, even when equal-depth comparisons run. The G3 test
#   stays as a behaviour check on the ordering.
# - C 662 l&&!r: the constructor dies without a path registry
#   (Missing path registry), so the runtime root is never empty.
# - B 2358: the branch row stays at 50% locally (T untaken) even
#   though the condition truth table records both paths (the
#   fallback combinations and the all-true combination are all
#   covered) and the fallback and looks-loop assertions pass. The
#   line is a De Morgan-normalised if displayed as unless; the
#   branch row does not follow the condition table here. Verify
#   it moves in cover #20 rather than chasing the display.
# =====================================================================

# Section 2 shared runtime: one temp home and one manager for the
# whole section, so state files written in one block are read in
# another. The runner is a stub whose running_loops dies while
# die_calls lasts, then returns the configured loops; stop_loop
# records the names it is asked to stop.
require Developer::Dashboard::Collector;
require Developer::Dashboard::Config;
require Developer::Dashboard::FileRegistry;
require Developer::Dashboard::PathRegistry;
require Developer::Dashboard::RuntimeManager;
require IO::Socket::INET;
my $M7_HOME = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $M7_HOME;

my $M7_PATHS  = Developer::Dashboard::PathRegistry->new( home => $M7_HOME );
my $M7_FILES  = Developer::Dashboard::FileRegistry->new( paths => $M7_PATHS );
my $M7_CONFIG = Developer::Dashboard::Config->new( files => $M7_FILES, paths => $M7_PATHS );

{
    package Local::RMRunner;
    sub new {
        my ($class) = @_;
        return bless { die_calls => 0, loops => [], stopped => [] }, $class;
    }
    sub running_loops {
        my ($self) = @_;
        if ( $self->{die_calls} > 0 ) {
            $self->{die_calls}--;
            die "boom\n";
        }
        return @{ $self->{loops} };
    }
    sub loop_state { return undef }
    sub stop_loop {
        my ( $self, $name ) = @_;
        push @{ $self->{stopped} }, $name;
        return 1;
    }

    package Local::DyingFiles;
    sub new {
        my ( $class, $real ) = @_;
        return bless { real => $real }, $class;
    }
    sub web_state { die "Unable to read web state: No such file or directory\n" }
    sub AUTOLOAD {
        my ($self) = @_;
        my $method = $Local::DyingFiles::AUTOLOAD;
        $method =~ s/.*:://;
        return if $method eq 'DESTROY';
        return $self->{real}->$method(@_);
    }
}

my $M7_RUNNER = Local::RMRunner->new;
my $M7_MANAGER = Developer::Dashboard::RuntimeManager->new(
    app_builder => sub { die "the M7 section never serves\n" },
    collectors  => Developer::Dashboard::Collector->new( paths => $M7_PATHS ),
    config      => $M7_CONFIG,
    files       => $M7_FILES,
    paths       => $M7_PATHS,
    runner      => $M7_RUNNER,
);

# _m7_sleep_script: one small script file every spawned section-2
# child runs. A script file, not -e: assigning $0 inside a -e child
# leaves the -e source text in /proc/<pid>/cmdline after the title,
# so a title read never starts with the title. From a file, $0
# rewrites the whole command line to the title alone. A child sets
# $0 ONLY when a title is passed: a $0 assignment rewrites the argv
# area, and the /proc/<pid>/environ view of the child environment
# is lost with it, so a child that must carry environment markers
# (the ajax and web-service children) must never set $0, and a child
# that must carry a title must never carry markers.
my $M7_SLEEP_SCRIPT = File::Spec->catfile( $M7_HOME, 'm7-sleep-child.pl' );
{
    open my $sfh, '>', $M7_SLEEP_SCRIPT or die "Unable to write $M7_SLEEP_SCRIPT: $!";
    print {$sfh} "my (\$title, \$ignore) = \@ARGV;\n";
    print {$sfh} "\$0 = \$title if defined \$title && length \$title;\n";
    print {$sfh} "\$SIG{TERM} = 'IGNORE' if \$ignore;\n";
    print {$sfh} "select undef, undef, undef, 30;\n";
    close $sfh or die "Unable to close $M7_SLEEP_SCRIPT: $!";
}

# _m7_spawn_sleep(%args): a real long-lived child process, spawned
# the GoRoutine way (never fork(), which t/246 forbids in t/). $0
# and the environment are the child own: $0 rewrites the Unix
# command line the title readers see, and the env markers are read
# from /proc. The settle matters: the markers and the title are
# only visible once the child has execd, so this helper waits for
# the title or one marker to actually appear (bounded at 5s) instead
# of trusting a fixed sleep - under Devel::Cover the child starts
# too slowly for 0.3s to be enough.
# Input: title string, env hash reference, ignore_term boolean.
# Output: spawned process id.
sub _m7_spawn_sleep {
    my (%args) = @_;
    die 'a section-2 child cannot carry both a title and env markers'
      if defined $args{title} && length $args{title} && $args{env};
    my $title = $args{title} || '';
    my $pid = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $M7_SLEEP_SCRIPT, $title, $args{ignore_term} ? 1 : 0 ],
        { $args{env} ? ( env => $args{env} ) : () },
    );
    die 'GoRoutine spawn failed' if !defined $pid;
    # The settle matters: the markers and the title are only visible
    # once the child has execd, and a read in the same instant as the
    # spawn can still see the pre-exec state. A fixed 0.3s sleep is
    # not enough under Devel::Cover, where the child perl starts
    # slowly: the cover run read two titled children before their $0
    # was assigned, and the starman worker before its title was set.
    # So wait for the title or the markers to actually appear, with
    # a bounded budget, and only then return. Where /proc is absent
    # the markers cannot be observed, so a plain child there keeps
    # the fixed sleep.
    my $deadline = time() + 5;
    if ( defined $args{title} && length $args{title} ) {
        while ( time() < $deadline ) {
            my $seen = $M7_MANAGER->_read_process_title($pid);
            last if defined $seen && $seen eq $args{title};
            Time::HiRes::sleep(0.05);
        }
    }
    elsif ( $args{env} ) {
        if ( -r "/proc/$pid/environ" ) {
            my ($key) = keys %{ $args{env} };
            while ( time() < $deadline ) {
                my $seen = $M7_MANAGER->_read_process_env_marker( $pid, $key );
                last if defined $seen;
                Time::HiRes::sleep(0.05);
            }
        }
        else {
            Time::HiRes::sleep(0.3);
        }
    }
    else {
        Time::HiRes::sleep(0.3);
    }
    return $pid;
}

# _m7_kill_child($pid): ends a spawned section-2 child and reaps
# it, so no test child outlives its block.
# Input: spawned process id.
# Output: none.
sub _m7_kill_child {
    my ($pid) = @_;
    return if !defined $pid || !$pid;
    kill 'TERM', $pid;
    _wait_for_exit( $pid, 5 );
    return;
}

# _m7_iso_at($epoch): an ISO-8601 UTC timestamp for one epoch, the
# shape _iso8601_to_epoch parses.
# Input: epoch integer.
# Output: timestamp string.
sub _m7_iso_at {
    my ($epoch) = @_;
    return POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime($epoch) );
}

# _m7_read_file($path): slurps one file, or undef when it is absent.
# Input: file path string.
# Output: file content string or undef.
sub _m7_read_file {
    my ($path) = @_;
    return if !-f $path;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $content;
}

# --- Numeric validators (lines 2921, 2936) ---------------------------
# _collector_supervisor_poll_interval,
# _collector_supervisor_parent_grace_seconds and
# _collector_supervisor_quiesce_seconds were never called in cover
# #19 (pct=0): the supervisor child never runs in the suite. A
# valid env value is returned, anything else falls to the default.
# The quiesce validator is also called by the supervisor child
# loop in block C, but only with a valid env value, so its default
# side is covered here.
{
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL} = '2.5';
        is( $M7_MANAGER->_collector_supervisor_poll_interval(), '2.5',
            'poll interval: a valid env value is returned' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL} = 'abc';
        is( $M7_MANAGER->_collector_supervisor_poll_interval(), 5,
            'poll interval: a non-numeric env value falls to the default' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL} = '0';
        is( $M7_MANAGER->_collector_supervisor_poll_interval(), 5,
            'poll interval: a zero env value falls to the default' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL};
        delete $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL};
        is( $M7_MANAGER->_collector_supervisor_poll_interval(), 5,
            'poll interval: an unset env value falls to the default' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_PARENT_GRACE_SECONDS} = '1.5';
        is( $M7_MANAGER->_collector_supervisor_parent_grace_seconds(), '1.5',
            'parent grace: a valid env value is returned' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_PARENT_GRACE_SECONDS} = 'abc';
        is( $M7_MANAGER->_collector_supervisor_parent_grace_seconds(), 30,
            'parent grace: a non-numeric env value falls to the default' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_PARENT_GRACE_SECONDS};
        delete $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_PARENT_GRACE_SECONDS};
        is( $M7_MANAGER->_collector_supervisor_parent_grace_seconds(), 30,
            'parent grace: an unset env value falls to the default' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS} = '0.001';
        is( $M7_MANAGER->_collector_supervisor_quiesce_seconds(), '0.001',
            'quiesce seconds: a valid env value is returned' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS} = 'abc';
        is( $M7_MANAGER->_collector_supervisor_quiesce_seconds(), 600,
            'quiesce seconds: a non-numeric env value falls to the default' );
    }
    {
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS};
        delete $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS};
        is( $M7_MANAGER->_collector_supervisor_quiesce_seconds(), 600,
            'quiesce seconds: an unset env value falls to the default' );
    }
}

# --- _collector_stalled_for_watchdog, started_at (lines 1625-1627) -----
# The started_at guard only runs for a loop with a usable progress
# timestamp. An empty started_at takes the defined-but-empty side;
# an unparsable started_at makes the eval return false, so the
# started_epoch is zero and the fresh-loop return is skipped.
{
    my $job    = { schedule => 'interval', interval => 1, timeout_ms => 100 };
    my $status = { last_run => _m7_iso_at( time() ) };
    my $empty_started = { state => { started_at => '' } };
    is( $M7_MANAGER->_collector_stalled_for_watchdog( $job, $status, $empty_started ), 0,
        'watchdog: an empty started_at is judged on the fresh progress alone' );
    my $bad_started = { state => { started_at => 'not-a-date' } };
    is( $M7_MANAGER->_collector_stalled_for_watchdog( $job, $status, $bad_started ), 0,
        'watchdog: an unparsable started_at is judged on the fresh progress alone' );
    my $fresh_started = { state => { started_at => _m7_iso_at( time() ) } };
    is( $M7_MANAGER->_collector_stalled_for_watchdog( $job, $status, $fresh_started ), 0,
        'watchdog: a freshly started loop is not stalled' );
}

# --- _run_collector_supervisor_child, quiesce (lines 1954-1963) --------
# The child loop never runs in the suite, so its quiesce branches
# are driven in-process. The runner dies on its first two
# running_loops calls: the supervise eval catches the first death
# (B 1954), the quiesce scan eval catches the second (C 1957 left
# cell, B 1958 true - a failed scan keeps the supervisor alive).
# After that the runner returns no loops, so the quiesce timer
# starts, and on the third pass it has run past the tiny quiesce
# period (B 1963 true). The shutdown is stubbed to die instead of
# exiting, so the loop ends in the test process.
{
    $M7_RUNNER->{die_calls} = 2;
    $M7_RUNNER->{loops}     = [];
    $M7_RUNNER->{stopped}   = [];
    $M7_MANAGER->_write_collector_supervisor_state( { watched_names => ['alpha'], status => 'running' } );
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL}   = '0.01';
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS} = '0.001';
    my $died;
    my $error;
    {
        no warnings qw(redefine prototype);
        local *Developer::Dashboard::RuntimeManager::_shutdown_collector_supervisor
          = sub { my ( $self, $status ) = @_; die "SHUTDOWN:$status\n"; };
        $died = eval {
            $M7_MANAGER->_run_collector_supervisor_child( daemonize => 0, redirect => 0 );
            1;
        };
        $error = $@;
    }
    ok( !$died, 'supervisor child: the quiesce shutdown dies out of the loop' );
    like( $error, qr/^SHUTDOWN:quiesced/, 'supervisor child: the shutdown names quiesced' );
    is( $M7_RUNNER->{die_calls}, 0,
        'supervisor child: both dying runner calls were consumed' );
}

# --- _check_collector_supervisor_parent (lines 2021-2059) ---------------
# C 2021: web_state dying is simulated with a files object whose
# web_state dies - the real trigger is an unreadable state file,
# and the logic under test (do not adopt when the state read fails)
# runs for real. C 2039: an adopted parent that is dead does not
# keep the supervisor from the worker branch. C 2047: a defined
# parent skips the dead-adoption block. B 2058: a missing
# dead_since is stamped now. B 2059: an expired grace shuts down
# (stubbed to die, so it ends in the test process).
{
    my $dying_manager = Developer::Dashboard::RuntimeManager->new(
        app_builder => sub { die "the M7 section never serves\n" },
        collectors  => Developer::Dashboard::Collector->new( paths => $M7_PATHS ),
        config      => $M7_CONFIG,
        files       => Local::DyingFiles->new($M7_FILES),
        paths       => $M7_PATHS,
        runner      => $M7_RUNNER,
    );
    my $parent = {};
    is( $dying_manager->_check_collector_supervisor_parent( ['alpha'], $parent ), undef,
        'supervisor parent: a dying web_state leaves the parent unadopted' );
    is_deeply( $parent, {}, 'supervisor parent: no parent is adopted when web_state dies' );
}
{
    my $web_state_file = $M7_FILES->web_state;
    unlink $web_state_file if -f $web_state_file;

    my $worker = _m7_spawn_sleep( title => 'starman worker test' );
    $M7_MANAGER->_write_web_state( { pid => $worker, status => 'running' } );
    SKIP: {
        skip 'the starman title does not read back on Windows', 2
          if $^O eq 'MSWin32';
        my $kept = { pid => 999998, dead_since => undef };
        is( $M7_MANAGER->_check_collector_supervisor_parent( ['alpha'], $kept ), undef,
            'supervisor parent: a dead adopted parent does not keep the worker branch' );
        ok( $kept->{pid} == 999998 && defined $kept->{dead_since},
            'supervisor parent: the dead parent is kept and dead_since is stamped' );
    }
    _m7_kill_child($worker);

    $M7_MANAGER->_write_web_state( { pid => 999999, status => 'running' } );
    my $dead_parent = { pid => 999998, dead_since => undef };
    is( $M7_MANAGER->_check_collector_supervisor_parent( ['alpha'], $dead_parent ), undef,
        'supervisor parent: a defined parent skips the dead-adoption block' );
    ok( $dead_parent->{pid} == 999998 && defined $dead_parent->{dead_since},
        'supervisor parent: the defined parent is kept and dead_since is stamped' );

    $M7_RUNNER->{stopped} = [];
    my $gone_parent = { pid => 999998, dead_since => time() - 3600 };
    my $died;
    my $error;
    {
        no warnings qw(redefine prototype);
        local *Developer::Dashboard::RuntimeManager::_shutdown_collector_supervisor
          = sub { my ( $self, $status ) = @_; die "SHUTDOWN:$status\n"; };
        local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_PARENT_GRACE_SECONDS} = '0.001';
        $died = eval {
            $M7_MANAGER->_check_collector_supervisor_parent( ['alpha'], $gone_parent );
            1;
        };
        $error = $@;
    }
    ok( !$died, 'supervisor parent: an expired grace shuts down' );
    like( $error, qr/^SHUTDOWN:parent-gone/, 'supervisor parent: the shutdown names parent-gone' );
    is_deeply( $M7_RUNNER->{stopped}, ['alpha'],
        'supervisor parent: the watched loops are stopped on the way out' );
    unlink $web_state_file if -f $web_state_file;
}

# --- _managed_ajax_processes (lines 660-666) ----------------------------
# The first loop needs a process with no runtime-root marker: a
# plain sleep child, matched by a fabricated prefix row, whose
# /proc environ carries no marker. The second loop needs processes
# with both markers set: their titles are stubbed to undef and to
# the empty string, because a live process always has a readable
# command line - the stub stands in for the race where the process
# exits between the marker read and the title read, and the
# fallback to the scanned args runs for real. A third child carries
# a singleton marker but no runtime-root marker, so the second
# loop skips it at line 662 (B 662 true); the constructor requires
# a path registry, so the runtime root is never empty and the
# C 662 l&&!r cell is uncoverable.
{
    my $plain = _m7_spawn_sleep();
    my @matches = $M7_MANAGER->_managed_ajax_processes(
        [ { pid => $plain, uid => $<, args => 'd2 ajax: singleton' } ] );
    is( scalar(@matches), $M7_MANAGER->_procfs_available ? 0 : 1,
        'ajax processes: a process with no marker is skipped where procfs reads it' );
    _m7_kill_child($plain);

    my $root = $M7_MANAGER->{paths}->state_root;
    my $one = _m7_spawn_sleep(
        env => {
            DEVELOPER_DASHBOARD_AJAX_SINGLETON    => 'alpha',
            DEVELOPER_DASHBOARD_RUNTIME_ROOT      => $root,
        } );
    my $two = _m7_spawn_sleep(
        env => {
            DEVELOPER_DASHBOARD_AJAX_SINGLETON    => 'beta',
            DEVELOPER_DASHBOARD_RUNTIME_ROOT      => $root,
        } );
    my $three = _m7_spawn_sleep(
        env => {
            DEVELOPER_DASHBOARD_AJAX_SINGLETON => 'gamma',
        } );
    my @rows = (
        { pid => $one, uid => $<, args => 'perl sleep-one.pl' },
        { pid => $two, uid => $<, args => 'perl sleep-two.pl' },
        { pid => $three, uid => $<, args => 'perl sleep-three.pl' },
    );
    my @found;
    {
        my $orig_title = \&Developer::Dashboard::RuntimeManager::_read_process_title;
        no warnings qw(redefine);
        local *Developer::Dashboard::RuntimeManager::_read_process_title = sub {
            my ( $self, $pid ) = @_;
            return undef if defined $pid && $pid == $one;
            return q{}    if defined $pid && $pid == $two;
            return $orig_title->( $self, $pid );
        };
        @found = $M7_MANAGER->_managed_ajax_processes( \@rows );
    }
    if ( $M7_MANAGER->_procfs_available ) {
        is( scalar(@found), 2, 'ajax processes: two marked processes are found' );
        is_deeply( [ map { $_->{args} } @found ], [ 'perl sleep-one.pl', 'perl sleep-two.pl' ],
            'ajax processes: an unreadable title falls back to the scanned args' );
        is( scalar( grep { $_->{pid} == $three } @found ), 0,
            'ajax processes: a singleton marker with no runtime root is skipped' );
    }
    else {
        is( scalar(@found), 0, 'ajax processes: no marker scan runs without procfs' );
    }
    _m7_kill_child($one);
    _m7_kill_child($two);
    _m7_kill_child($three);
}

# --- _windows_process_tree_rows (lines 2236-2253) ----------------------
# _powershell_command returns "" on Unix even simulated, so the
# empty-powershell side is reached by pointing PATH at an empty
# directory. A fake powershell that exits 1 takes the failed-run
# side; one that prints tab-separated rows takes the parsed-rows
# side. _process_started_not_before is driven directly: a parent
# that is not all digits takes the undefined-parent side.
{
    my $empty_dir = tempdir( CLEANUP => 1 );
    local $ENV{PATH} = $empty_dir;
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( $M7_MANAGER->_windows_process_tree_rows(), undef,
        'tree rows: no powershell means no listing' );
}
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    _make_executable( File::Spec->catfile( $fakebin, 'powershell' ),
        "#!/bin/sh\nexit 1\n" );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( $M7_MANAGER->_windows_process_tree_rows(), undef,
        'tree rows: a failing powershell means no listing' );
}
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    _make_executable( File::Spec->catfile( $fakebin, 'powershell' ),
        "#!/bin/sh\nprintf '123\\t456\\t789\\n456\\t123\\t790\\n'\n" );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    SKIP: {
        skip 'the fake powershell uses printf, which cmd cannot run', 1
          if $^O eq 'MSWin32';
        is_deeply( $M7_MANAGER->_windows_process_tree_rows(),
            [ { pid => 123, ppid => 456, started => '789' }, { pid => 456, ppid => 123, started => '790' } ],
            'tree rows: tab-separated rows are parsed' );
    }
}
{
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( '123', 'abc' ), 0,
        'started not before: a non-numeric parent start proves nothing' );
    is( Developer::Dashboard::RuntimeManager::_process_started_not_before( '123', '122' ), 1,
        'started not before: a child starting after its parent counts' );
}

# --- _looks_like_collector_supervisor_process (line 2750) --------------
# The helper-command shape for a booting supervisor.
{
    is( $M7_MANAGER->_looks_like_collector_supervisor_process(
            { args => 'developer-dashboard collector-supervisor-foreground' } ),
        1, 'supervisor shape: the helper foreground command matches' );
    is( $M7_MANAGER->_looks_like_collector_supervisor_process(
            { args => 'developer-dashboard collector-supervisor-foreground --verbose' } ),
        1, 'supervisor shape: the helper foreground command with args matches' );
    is( $M7_MANAGER->_looks_like_collector_supervisor_process( { args => 'plain process' } ), 0,
        'supervisor shape: an unrelated command does not match' );
}

# --- _descendant_pids_sparing (lines 2292-2312) -----------------------
# The walk is pure: fabricated rows and roots drive it. No rows and
# no roots take the empty sides; a duplicated child pid takes the
# seen side; five children of one root at the same depth force the
# sort comparator to compare equal depths.
{
    my ( $found, $refused ) = $M7_MANAGER->_descendant_pids_sparing( undef, undef, undef );
    is_deeply( $found,   [], 'descendants: no rows and no roots find nothing' );
    is_deeply( $refused, [], 'descendants: no rows and no roots refuse nothing' );
}
{
    my ( $found, $refused ) = $M7_MANAGER->_descendant_pids_sparing(
        [
            { pid => 10, ppid => 1,  started => '100' },
            { pid => 11, ppid => 10, started => '150' },
            { pid => 11, ppid => 10, started => '150' },
        ],
        { 10 => '100' },
        undef,
    );
    is_deeply( $found, [ [ 11, '150' ] ], 'descendants: a duplicated child pid is walked once' );
    is_deeply( $refused, [], 'descendants: a duplicated child pid is refused nowhere' );
}
{
    my ( $found, $refused ) = $M7_MANAGER->_descendant_pids_sparing(
        [
            { pid => 10, ppid => 1,  started => '100' },
            { pid => 11, ppid => 10, started => '150' },
            { pid => 12, ppid => 10, started => '151' },
            { pid => 13, ppid => 10, started => '152' },
            { pid => 14, ppid => 10, started => '153' },
            { pid => 15, ppid => 10, started => '154' },
        ],
        { 10 => '100' },
        undef,
    );
    is_deeply(
        $found,
        [ [ 11, '150' ], [ 12, '151' ], [ 13, '152' ], [ 14, '153' ], [ 15, '154' ] ],
        'descendants: same-depth children are ordered by pid'
    );
    is_deeply( $refused, [], 'descendants: same-depth children are refused nowhere' );
}

# --- _kill_exact_pids, not-found (line 2331) --------------------------
# A fake taskkill that exits 1 while printing "not found" takes the
# middle side of the exit-or-not-found condition: the pid counts as
# ended even though taskkill failed.
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    _make_executable( File::Spec->catfile( $fakebin, 'taskkill' ),
        "#!/bin/sh\necho 'ERROR: The process \"999999\" not found.'\nexit 1\n" );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( $M7_MANAGER->_kill_exact_pids(999999), 1,
        'kill exact: a not-found report counts the pid as ended' );
}

# --- _stop_web_pid_as_its_watcher (lines 2354-2390) -------------------
# The guard first: a pid with no process behind it is left alone.
# Then the tree paths, each with its own fake powershell and fake
# taskkill. The killing fake ends the pid it is given (its second
# argument) and exits 1, so the send-signal wait sees a dead pid;
# the no-op fake exits 0 without ending anything, so the wait runs
# its full budget and the pid is still alive at the end.
{
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( $M7_MANAGER->_stop_web_pid_as_its_watcher( 999999, undef, q{} ), undef,
        'watcher stop: a pid with no process behind it is left alone' );
}
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    _make_executable( File::Spec->catfile( $fakebin, 'powershell' ),
        "#!/bin/sh\nexit 0\n" );
    _make_executable( File::Spec->catfile( $fakebin, 'taskkill' ),
        "#!/bin/sh\nkill \"\$2\" 2>/dev/null\nexit 1\n" );
    my $log_path = File::Spec->catfile( $dir, 'watcher.log' );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    SKIP: {
        skip 'the killing fake taskkill uses kill, which cmd cannot run', 3
          if $^O eq 'MSWin32';
        my $web = _m7_spawn_sleep(
            env => { DEVELOPER_DASHBOARD_WEB_SERVICE => '1' } );
        is( $M7_MANAGER->_stop_web_pid_as_its_watcher( $web, $log_path, undef ), $web,
            'watcher stop: an undefined prefix is set to empty and the stop returns the pid' );
        my $gone = 0;
        for my $i ( 1 .. 20 ) {
            if ( !$M7_MANAGER->_pid_is_running($web) ) { $gone = 1; last }
            Time::HiRes::sleep(0.1);
        }
        ok( $gone, 'watcher stop: the web is gone after the fallback stop' );
        like( _m7_read_file($log_path), qr/web tree not listed: the process tree of web pid $web/,
            'watcher stop: the fallback logs that the web tree was not listed' );
    }
}
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    _make_executable( File::Spec->catfile( $fakebin, 'powershell' ),
        "#!/bin/sh\nprintf '111\\t1\\t100\\n222\\t1\\t100\\n'\n" );
    _make_executable( File::Spec->catfile( $fakebin, 'taskkill' ),
        "#!/bin/sh\nkill \"\$2\" 2>/dev/null\nexit 1\n" );
    my $log_path = File::Spec->catfile( $dir, 'watcher.log' );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    SKIP: {
        skip 'the tree fake uses printf and the killing fake uses kill, which cmd cannot run', 2
          if $^O eq 'MSWin32';
        my $web = _m7_spawn_sleep(
            env => { DEVELOPER_DASHBOARD_WEB_SERVICE => '1' } );
        is( $M7_MANAGER->_stop_web_pid_as_its_watcher( $web, $log_path, q{} ), $web,
            'watcher stop: a listing without the web pid falls back and returns the pid' );
        my $gone = 0;
        for my $i ( 1 .. 20 ) {
            if ( !$M7_MANAGER->_pid_is_running($web) ) { $gone = 1; last }
            Time::HiRes::sleep(0.1);
        }
        ok( $gone, 'watcher stop: the web is gone after the no-root fallback stop' );
    }
}
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    my $counter = File::Spec->catfile( $dir, 'calls.txt' );
    my $rows_script = "#!/bin/sh\n"
      . "c=\$(cat '$counter' 2>/dev/null || echo 0)\n"
      . "c=\$((c + 1))\n"
      . "echo \$c > '$counter'\n"
      . "if [ \$c -eq 1 ]; then printf 'WEBPID\\t1\\t100\\nCHILD\\tWEBPID\\t150\\n'; fi\n"
      . "exit 0\n";
    _make_executable( File::Spec->catfile( $fakebin, 'powershell' ), $rows_script );
    _make_executable( File::Spec->catfile( $fakebin, 'taskkill' ),
        "#!/bin/sh\nkill \"\$2\" 2>/dev/null\nexit 1\n" );
    my $log_path = File::Spec->catfile( $dir, 'watcher.log' );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    SKIP: {
        skip 'the tree fake uses shell arithmetic and printf, which cmd cannot run', 1
          if $^O eq 'MSWin32';
        my $web = _m7_spawn_sleep(
            env => { DEVELOPER_DASHBOARD_WEB_SERVICE => '1' } );
        my $child = _m7_spawn_sleep();
        my $script = _m7_read_file( File::Spec->catfile( $fakebin, 'powershell' ) );
        $script =~ s/WEBPID/$web/g;
        $script =~ s/CHILD/$child/g;
        _make_executable( File::Spec->catfile( $fakebin, 'powershell' ), $script );
        is( $M7_MANAGER->_stop_web_pid_as_its_watcher( $web, $log_path, q{} ), $web,
            'watcher stop: a second listing that fails ends the looks loop' );
        _m7_kill_child($child);
    }
}
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    # The 999 row is not a web descendant and is never in %known, so
    # the look-2 grep tests a row that does not match (B 2380 false);
    # a row whose pid is known but whose started is undef cannot
    # occur, because the tree parser always sets started, so the
    # C 2380 l&&!r cell is uncoverable.
    my $rows_script = "#!/bin/sh\nprintf 'WEBPID\\t1\\t100\\nCHILD\\tWEBPID\\t150\\n999\\t1\\t100\\n'\n";
    _make_executable( File::Spec->catfile( $fakebin, 'powershell' ), $rows_script );
    _make_executable( File::Spec->catfile( $fakebin, 'taskkill' ),
        "#!/bin/sh\nexit 0\n" );
    my $log_path = File::Spec->catfile( $dir, 'watcher.log' );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    SKIP: {
        skip 'the tree fake uses printf, which cmd cannot run', 2
          if $^O eq 'MSWin32';
        my $web = _m7_spawn_sleep(
            env => { DEVELOPER_DASHBOARD_WEB_SERVICE => '1' } );
        my $child = _m7_spawn_sleep();
        my $script = _m7_read_file( File::Spec->catfile( $fakebin, 'powershell' ) );
        $script =~ s/WEBPID/$web/g;
        $script =~ s/CHILD/$child/g;
        _make_executable( File::Spec->catfile( $fakebin, 'powershell' ), $script );
        is( $M7_MANAGER->_stop_web_pid_as_its_watcher( $web, $log_path, q{} ), $web,
            'watcher stop: a web that survives the kill still returns its pid' );
        is( $M7_MANAGER->_pid_is_running($web), 1,
            'watcher stop: the web is still running after the no-op kill' );
        _m7_kill_child($web);
        _m7_kill_child($child);
    }
}

# --- _log_web_lifetime_owner_stop (line 2428) -------------------------
# A missing owner or web pid writes nothing.
{
    my $log_path = File::Spec->catfile( $M7_HOME, 'lifetime-stop.log' );
    is( $M7_MANAGER->_log_web_lifetime_owner_stop( $log_path, undef, 123 ), undef,
        'lifetime stop log: an undefined owner pid writes nothing' );
    is( $M7_MANAGER->_log_web_lifetime_owner_stop( $log_path, 123, undef ), undef,
        'lifetime stop log: an undefined web pid writes nothing' );
}

# --- _run_web_lifetime_owner_watcher, guard (line 2584) ----------------
# A non-numeric web pid is refused at once, before any loop runs.
{
    my $log_path = File::Spec->catfile( $M7_HOME, 'watcher-guard.log' );
    is( $M7_MANAGER->_run_web_lifetime_owner_watcher( 'abc', $log_path ), 0,
        'watcher run: a non-numeric web pid returns at once' );
}

# --- _send_signal, Windows wait (lines 3470-3474) ----------------------
# The fake taskkill ends the pid it is given and exits 1, so the
# TERM wait sees a dead target at once. The no-op fake exits 1
# without ending anything, so the wait runs its full budget, the
# target is still running, and the stop dies.
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    _make_executable( File::Spec->catfile( $fakebin, 'taskkill' ),
        "#!/bin/sh\nkill \"\$2\" 2>/dev/null\nexit 1\n" );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    SKIP: {
        skip 'the killing fake taskkill uses kill, which cmd cannot run', 2
          if $^O eq 'MSWin32';
        my $victim = _m7_spawn_sleep();
        is( $M7_MANAGER->_send_signal( 'TERM', $victim ), 1,
            'send signal: a dead target after the wait returns the count' );
        is( $M7_MANAGER->_pid_is_running($victim), 0,
            'send signal: the target is gone after the killing taskkill' );
        # No _m7_kill_child here: the wait above already reaped the
        # victim through _pid_is_running, so a second wait would croak
        # with no child processes to wait for.
    }
}
{
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    _make_executable( File::Spec->catfile( $fakebin, 'taskkill' ),
        "#!/bin/sh\nexit 1\n" );
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my $victim = _m7_spawn_sleep();
    my $died = eval { $M7_MANAGER->_send_signal( 'TERM', $victim ); 1 };
    ok( !$died, 'send signal: a surviving target makes the stop die' );
    like( $@, qr/Failed to stop Windows process ids $victim/,
        'send signal: the die names the surviving pid' );
    _m7_kill_child($victim);
}

# --- _find_processes_by_prefix (lines 3686-3697) ----------------------
# A fabricated row whose args carry a $0 assignment naming the
# prefix takes the assignment side. A real titled child takes the
# title-fallback side: one whose title starts with the prefix, and
# one whose title only carries the assignment after other text.
{
    my $child = _m7_spawn_sleep();
    my @found = $M7_MANAGER->_find_processes_by_prefix(
        'd2 ajax:',
        [ { pid => $child, uid => $<, args => '$0 = "d2 ajax: test"' } ] );
    is( scalar(@found), 1, 'find by prefix: a $0 assignment naming the prefix matches' );
    is( $found[0]{args}, '$0 = "d2 ajax: test"',
        'find by prefix: the assignment row is returned as scanned' );
    _m7_kill_child($child);
}
{
    my $one = _m7_spawn_sleep( title => 'd2 ajax: singleton' );
    my $two = _m7_spawn_sleep( title => 'w $0 = "d2 ajax: t"' );
    my @rows = (
        { pid => $one, uid => $<, args => 'perl sleep-one.pl' },
        { pid => $two, uid => $<, args => 'perl sleep-two.pl' },
    );
    SKIP: {
        skip 'the $0 title does not read back on Windows', 2
          if $^O eq 'MSWin32';
        my @found = $M7_MANAGER->_find_processes_by_prefix( 'd2 ajax:', \@rows );
        is( scalar(@found), 2, 'find by prefix: two titled processes are found' );
        is_deeply( [ map { $_->{args} } @found ], [ 'd2 ajax: singleton', 'w $0 = "d2 ajax: t"' ],
            'find by prefix: the title replaces the scanned args' );
    }
    _m7_kill_child($one);
    _m7_kill_child($two);
}

# --- _find_web_processes and _looks_like_web_process (lines 3722-3774) --
# Fabricated rows drive both: one whose $0 assignment adopts to a
# d2 web title, and one whose args pass the helper-command shape
# while adopting to something else. _looks_like_web_process is also
# called directly for its $0-assignment shape.
{
    my $one = _m7_spawn_sleep();
    my $two = _m7_spawn_sleep();
    my @rows = (
        { pid => $one, uid => $<, args => 'perl x.pl $0 = "d2 web: host:1234"' },
        { pid => $two, uid => $<, args => 'perl _dashboard-core serve $0 = "other title"' },
    );
    my @found = $M7_MANAGER->_find_web_processes( \@rows );
    is( scalar(@found), 2, 'find web: two fabricated web processes are found' );
    is( $found[0]{args}, 'd2 web: host:1234',
        'find web: the adopted title replaces the scanned args' );
    _m7_kill_child($one);
    _m7_kill_child($two);
}
{
    is( $M7_MANAGER->_looks_like_web_process( { pid => 1, args => 'x $0 = "d2 web: h:1"' } ), 1,
        'looks like web: a $0 assignment to a d2 web title matches' );
    is( $M7_MANAGER->_looks_like_web_process( { pid => 1, args => 'plain process' } ), 0,
        'looks like web: a plain process does not match' );
}

# --- _adopted_process_title (lines 4466-4467) -------------------------
# An undefined or empty args string adopts nothing; a $0
# assignment adopts the quoted title.
{
    is( $M7_MANAGER->_adopted_process_title(undef), undef,
        'adopted title: undefined args adopt nothing' );
    is( $M7_MANAGER->_adopted_process_title(q{}), undef,
        'adopted title: empty args adopt nothing' );
    is( $M7_MANAGER->_adopted_process_title('$0 = "d2 web: h:1"'), 'd2 web: h:1',
        'adopted title: a $0 assignment adopts its title' );
    is( $M7_MANAGER->_adopted_process_title('plain process'), undef,
        'adopted title: args without an assignment adopt nothing' );
}

# --- _read_process_title, Windows branch (lines 4512-4518) ------------
# With procfs pointed at a missing directory, the title read takes
# the Windows branch and works from the passed rows alone: an
# undefined pid is refused, a row list is honoured, a non-matching
# row is skipped, a $0 assignment is adopted, and an undefined or
# empty args string reads as no title.
{
    my $missing = File::Spec->catdir( $M7_HOME, 'no-such-procfs' );
    local $Developer::Dashboard::RuntimeManager::PROCFS_ROOT = $missing;
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( $M7_MANAGER->_read_process_title(undef), undef,
        'read title: an undefined pid reads nothing on the Windows branch' );
    is( $M7_MANAGER->_read_process_title( 'abc', [ { pid => 123, args => 'the title' } ] ), undef,
        'read title: a non-numeric pid reads nothing on the Windows branch' );
    is( $M7_MANAGER->_read_process_title( 123,
            [ { pid => 111, args => 'other' }, { pid => 123, args => 'the title' } ] ),
        'the title', 'read title: a matching row returns its args' );
    is( $M7_MANAGER->_read_process_title( 123,
            [ { pid => 123, args => 'perl x $0 = "d2 web: h:1"' } ] ),
        'd2 web: h:1', 'read title: a $0 assignment in the row is adopted' );
    is( $M7_MANAGER->_read_process_title( 123, [ { pid => 123, args => undef } ] ), undef,
        'read title: an undefined args string reads nothing' );
    is( $M7_MANAGER->_read_process_title( 124, [ { pid => 124, args => q{} } ] ), undef,
        'read title: an empty args string reads nothing' );
}

# --- _listener_pids_for_port_via_lsof (line 3957) ----------------------
# The capture block is the uncovered sub: calling the lsof path
# runs it, whatever lsof itself reports.
{
    is_deeply( [ $M7_MANAGER->_listener_pids_for_port_via_lsof(1) ], [],
        'listener pids via lsof: no listener on a closed port' );
}

# --- _web_runtime_ready, Windows branch (lines 4216-4220) ------------
# The two missing cells at 4216 are the two sides of the
# namespace/match decision in the Windows branch. C 4216 [or 3]
# !l&&!r needs a listener pid whose runtime does not match and
# whose namespace is foreign: a dead pid under a fake proc tree
# (the only way, since every pid on this VM shares one namespace
# id, pid:[4026532498] - probe /tmp/m7-rm-probe/ns-tree.pl). C
# 4216 [and 3] l&&r needs a listener pid whose runtime does not
# match but whose web state exists: a live pid with a stale web
# state (a dead pid and an old port), which the elsif then adopts
# to the real listener pid. The fake powershell maps -LocalPort to
# a pid from a map file (probe /tmp/m7-rm-probe/fake-powershell.pl);
# netstat cannot answer here because it only matches the Windows
# LISTENING line shape, so on this VM it always returns empty and
# the fallback runs. Two real listeners: P1 owned by a spawned
# child, P2 owned by this process. SKIP on Windows: the fake is a
# perl script, which cmd cannot run.
SKIP: {
    skip 'the port-map fake powershell is a perl script, which cmd cannot run', 4
      if $^O eq 'MSWin32';
    my $dir     = tempdir( CLEANUP => 1 );
    my $fakebin = File::Spec->catdir( $dir, 'fakebin' );
    mkdir $fakebin or die "Unable to mkdir $fakebin: $!";
    _make_executable( File::Spec->catfile( $fakebin, 'powershell' ),
        "#!/usr/bin/env perl\n"
      . "use strict;\n"
      . "use warnings;\n"
      . "my \$args = join ' ', \@ARGV;\n"
      . "exit 0 if \$args !~ /Get-NetTCPConnection/;\n"
      . "my (\$port) = \$args =~ /-LocalPort\\s+(\\d+)/;\n"
      . "exit 0 if !defined \$port;\n"
      . "my \$mapfile = \$ENV{M7_PS_MAP} || '';\n"
      . "open my \$fh, '<', \$mapfile or exit 1;\n"
      . "while ( my \$line = <\$fh> ) {\n"
      . "    chomp \$line;\n"
      . "    my ( \$p, \$pid ) = split /:/, \$line;\n"
      . "    if ( defined \$p && defined \$pid && \$p == \$port ) { print \"\$pid\\n\"; exit 0; }\n"
      . "}\n"
      . "exit 0;\n" );
    my $listener_script = File::Spec->catfile( $dir, 'listener-child.pl' );
    {
        open my $lfh, '>', $listener_script or die "Unable to write $listener_script: $!";
        print {$lfh} "use strict;\nuse warnings;\nuse IO::Socket::INET;\n";
        print {$lfh} "my (\$portfile) = \@ARGV;\n";
        print {$lfh} "my \$sock = IO::Socket::INET->new(\n";
        print {$lfh} "    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp', ReuseAddr => 1,\n";
        print {$lfh} ") or die \"listen: \$!\";\n";
        print {$lfh} "open my \$fh, '>', \$portfile or die \"Unable to write \$portfile: \$!\";\n";
        print {$lfh} "print {\$fh} \$sock->sockport, \"\\n\";\n";
        print {$lfh} "close \$fh or die \"Unable to close \$portfile: \$!\";\n";
        print {$lfh} "select undef, undef, undef, 30;\n";
        close $lfh or die "Unable to close $listener_script: $!";
    }
    my $portfile = File::Spec->catfile( $dir, 'p1.txt' );
    my $listener = Developer::Dashboard::GoRoutine::spawn( [ $^X, $listener_script, $portfile ], {} );
    die 'GoRoutine spawn failed' if !defined $listener;
    my $p1;
    for my $i ( 1 .. 100 ) {
        if ( -f $portfile ) {
            open my $pfh, '<', $portfile or die "Unable to read $portfile: $!";
            $p1 = <$pfh>;
            close $pfh or die "Unable to close $portfile: $!";
            chomp $p1 if defined $p1;
            last if defined $p1 && $p1 ne '';
        }
        Time::HiRes::sleep(0.05);
    }
    die 'no P1 port' if !$p1;
    my $self_listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp', ReuseAddr => 1,
    ) or die "self listen: $!";
    my $p2      = $self_listener->sockport;
    my $mapfile = File::Spec->catfile( $dir, 'map.txt' );
    {
        open my $mfh, '>', $mapfile or die "Unable to write $mapfile: $!";
        print {$mfh} "$p1:$listener\n$p2:$$\n";
        close $mfh or die "Unable to close $mapfile: $!";
    }
    local $ENV{M7_PS_MAP} = $mapfile;
    local $ENV{PATH} = join $Config{path_sep}, $fakebin, $ENV{PATH};
    local $ENV{DEVELOPER_DASHBOARD_RUNTIME_STABILITY_POLLS}     = '2';
    local $ENV{DEVELOPER_DASHBOARD_RUNTIME_CONFIRMATION_POLLS}  = '1';
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    {
        my $fakeroot = File::Spec->catdir( $dir, 'fakeproc' );
        mkdir $fakeroot or die "Unable to mkdir $fakeroot: $!";
        my $real_ns = readlink '/proc/self/ns/pid';
        mkdir File::Spec->catdir( $fakeroot, $$ ) or die "Unable to mkdir $$: $!";
        mkdir File::Spec->catdir( $fakeroot, $$, 'ns' ) or die "Unable to mkdir $$/ns: $!";
        symlink $real_ns, File::Spec->catfile( $fakeroot, $$, 'ns', 'pid' )
          or die "Unable to symlink $$: $!";
        mkdir File::Spec->catdir( $fakeroot, '999999' ) or die 'Unable to mkdir 999999: $!';
        mkdir File::Spec->catdir( $fakeroot, '999999', 'ns' ) or die 'Unable to mkdir 999999/ns: $!';
        symlink 'pid:[4026539999]', File::Spec->catfile( $fakeroot, '999999', 'ns', 'pid' )
          or die 'Unable to symlink 999999: $!';
        local $Developer::Dashboard::ProcessSupervision::PROCFS_ROOT = $fakeroot;
        is( $M7_MANAGER->_web_runtime_ready( 999999, $p2 ), 1,
            'web runtime ready: a dead pid in a foreign namespace reads ready when its port listens' );
        is( $M7_MANAGER->_same_pid_namespace(999999), 0,
            'web runtime ready: the fake tree makes the dead pid foreign' );
    }
    $M7_MANAGER->_write_web_state( { pid => 111111, port => $p1, host => '127.0.0.1', status => 'running' } );
    is( $M7_MANAGER->_web_runtime_ready( $$, $p2 ), 1,
        'web runtime ready: a live pid with a stale web state reads ready and adopts the listener' );
    is( $M7_MANAGER->web_state->{pid}, $$,
        'web runtime ready: the web state pid becomes the listener pid' );
    my $web_state_file = $M7_FILES->web_state;
    unlink $web_state_file if -f $web_state_file;
    _m7_kill_child($listener);
}
