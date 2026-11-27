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
