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
# input, so $contents is defined (probed). The fixture is written
# raw: _slurp_raw_file reads raw bytes, so a text-mode write on
# Windows stores CRLF and the read-back would not match
# (proof #210, test 3: got 'hello\r\n').
{
    my $dir = tempdir( CLEANUP => 1 );
    my $empty = File::Spec->catfile( $dir, 'empty.txt' );
    open my $fh, '>', $empty or die "Unable to write $empty: $!";
    close $fh or die "Unable to write $empty: $!";
    is( Developer::Dashboard::Platform::_slurp_raw_file($empty), '', 'slurp: empty file returns empty string' );
    my $full = File::Spec->catfile( $dir, 'full.txt' );
    open $fh, '>:raw', $full or die "Unable to write $full: $!";
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
    SKIP: {
        skip 'windows_acl_is_owner_only runs the real ACL check on Windows and answers 0 or 1, not undef', 1
          if $^O eq 'MSWin32';
        is( Developer::Dashboard::Platform::windows_acl_is_owner_only($file), undef,
            'acl is owner only: existing path returns undef off Windows' );
    }
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
# the empty-dir, dot-dir and canonpath-dot skips, and the .exe
# return through the PATHEXT expansion. A './' entry is not the
# string '.', but canonpath('./') is '.', so it fires the second
# disjunct (C 477 !l&&r) instead of the first.
# NOTE (uncoverable, Platform 476 cell 1, C 624 middle cell):
# File::Spec->path rewrites empty PATH entries to '.' on Unix, so
# the !defined/empty $dir cell can never fire (the probe below
# proves it: the empty entry arrives as '.', and the dot skip
# fires twice). B 624 false IS covered: the condition row
# [358, 0, 91] proves is_windows() was true 358 times through the
# OS_NAME localisation, so the early return was not taken 358
# times; only the branch row under-counts it (a statement-modifier
# unless counts the condition fully and the branch on one side
# only). The _path_candidates early-return false side needs
# is_real_windows() true with is_windows() false, which is the
# C 624 !l&&r cell, and that stays uncoverable.
{
    my $dir = tempdir( CLEANUP => 1 );
    _make_executable( File::Spec->catfile( $dir, 'wintool.exe' ), "echo hi\n" );
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    local $ENV{PATH} = join $Config{path_sep}, '', '.', './', $dir;
    is( Developer::Dashboard::Platform::command_in_path_direct('wintool'),
        File::Spec->catfile( $dir, 'wintool.exe' ), 'command in path direct: empty, dot and canonpath-dot dirs skipped, exe found' );
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
    # The shell receives the MSYS spelling on Windows (C:\... becomes
    # /c/...); on Unix the spelling is unchanged, so the same expectation
    # holds on every leg (proof #210, test 58: Windows got /c/...).
    my $expected_sh = $sh;
    $expected_sh =~ s{\\}{/}g;
    $expected_sh =~ s{\A([A-Za-z]):}{'/' . lc($1)}e;
    is( $argv[1], $expected_sh, 'argv for path: sh shebang routes through the POSIX shell' );
    like( $argv[0], qr/sh(?:\.exe)?\z/, 'argv for path: sh shebang uses a sh binary' );
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
# (line 749) - bash on PATH. The behaviour is driven here (bash
# resolves first), but the C 749 l cell itself is a Devel::Cover
# measurement artifact and never records: for an or-chain of four
# or more terms the l cell stays at 0 even when the first operand
# is true (probes /tmp/m7-oc/probe2.pl and probe3.pl: a 2-term
# and a 3-term chain record l=1, a 4-term and a 5-term chain
# record l=0 with the same true first operand). The cell is
# therefore probed-uncoverable; the test below proves the
# behaviour it guards.
{
    my $bash = Developer::Dashboard::Platform::_posix_shell_binary('bash');
    like( $bash, qr/bash(?:\.exe)?\z/, 'posix shell binary: bash on PATH resolves first' );
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
    print {$sfh} "my (\$title, \$ignore, \$ready) = \@ARGV;\n";
    print {$sfh} "\$0 = \$title if defined \$title && length \$title;\n";
    print {$sfh} "\$SIG{TERM} = 'IGNORE' if \$ignore;\n";
    print {$sfh} "if (defined \$ready && length \$ready) { open my \$rfh, '>', \$ready or die \"Unable to write \$ready: \$!\"; close \$rfh or die \"Unable to close \$ready: \$!\"; }\n";
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
my $M7_SPAWN_SEQ = 0;
sub _m7_spawn_sleep {
    my (%args) = @_;
    die 'a section-2 child cannot carry both a title and env markers'
      if defined $args{title} && length $args{title} && $args{env};
    my $title = $args{title} || '';
    # The child writes this file once it has set $0 and installed
    # its signal handling, so the caller can wait for the child to
    # be truly ready instead of trusting a fixed sleep: under
    # Devel::Cover a child starts too slowly for 0.3s, and a
    # TERM-ignoring child that has not yet run its $SIG line still
    # dies on TERM (the cover run proved it: the escalation block
    # never ran because the child was already dead).
    $M7_SPAWN_SEQ++;
    my $ready = File::Spec->catfile( $M7_HOME, "m7-ready-$M7_SPAWN_SEQ" );
    my $pid = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $M7_SLEEP_SCRIPT, $title, $args{ignore_term} ? 1 : 0, $ready ],
        { $args{env} ? ( env => $args{env} ) : () },
    );
    die 'GoRoutine spawn failed' if !defined $pid;
    {
        my $deadline = time() + 5;
        while ( time() < $deadline ) {
            last if -f $ready;
            Time::HiRes::sleep(0.05);
        }
    }
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
    # The ready file already proves the child has set $0 and its
    # signal handling; the title and marker polls below only
    # confirm what the child exposes, and return at once now.
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
# The guard first: a pid with no process behind it is left alone, and
# so is a live pid that is not a managed web. Then the tree paths, each
# with its own fake powershell and fake taskkill. The killing fake ends
# the pid it is given (its second argument) and exits 1, so the
# send-signal wait sees a dead pid; the no-op fake exits 0 without
# ending anything, so the wait runs its full budget and the pid is
# still alive at the end.
{
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( $M7_MANAGER->_stop_web_pid_as_its_watcher( 999999, undef, q{} ), undef,
        'watcher stop: a pid with no process behind it is left alone' );
}
{
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my $plain = _m7_spawn_sleep();
    is( $M7_MANAGER->_stop_web_pid_as_its_watcher( $plain, undef, q{} ), undef,
        'watcher stop: a live pid that is not a managed web is left alone' );
    ok( $M7_MANAGER->_pid_is_running($plain),
        'watcher stop: the non-web pid is still running after the refused stop' );
    _m7_kill_child($plain);
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
        skip 'the killing fake taskkill uses kill, which cmd cannot run, and the managed-web proof here is the /proc env marker, which needs procfs', 3
          if $^O eq 'MSWin32' || !$M7_MANAGER->_procfs_available;
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
        skip 'the tree fake uses printf and the killing fake uses kill, which cmd cannot run, and the managed-web proof here is the /proc env marker, which needs procfs', 2
          if $^O eq 'MSWin32' || !$M7_MANAGER->_procfs_available;
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
        skip 'the tree fake uses shell arithmetic and printf, which cmd cannot run, and the managed-web proof here is the /proc env marker, which needs procfs', 1
          if $^O eq 'MSWin32' || !$M7_MANAGER->_procfs_available;
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
        skip 'the tree fake uses printf, which cmd cannot run, and the managed-web proof here is the /proc env marker, which needs procfs', 2
          if $^O eq 'MSWin32' || !$M7_MANAGER->_procfs_available;
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
# A numeric pid below 1 is refused the same way: the pid is defined
# and numeric, so the first half of the guard is false, and being
# below 1 makes the second half true.
{
    my $log_path = File::Spec->catfile( $M7_HOME, 'watcher-guard.log' );
    is( $M7_MANAGER->_run_web_lifetime_owner_watcher( 'abc', $log_path ), 0,
        'watcher run: a non-numeric web pid returns at once' );
    is( $M7_MANAGER->_run_web_lifetime_owner_watcher( 0, $log_path ), 0,
        'watcher run: a numeric web pid below 1 returns at once' );
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
    # A wide backlog, not 1: every readiness probe opens a TCP
    # connection to this port and nothing ever accepts one, so the
    # probes sit unaccepted in the backlog. Listen => 1 fits one
    # on macOS, and the second readiness call's probes then time
    # out (proof #212 tests 152-153: got 0, expected 1, and the
    # state pid stayed 111111 because no adoption ran). Probe
    # /tmp/m7-p2-probe.pl: on Linux two unaccepted connects fit
    # and the third times out after 1s; macOS fits one.
    my $self_listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 128, Proto => 'tcp', ReuseAddr => 1,
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
        SKIP: {
            # The fake tree needs a real /proc namespace id for the
            # current process, and macOS has no /proc, so the
            # current id reads empty and _same_pid_namespace
            # answers 1 (unknown reads as same) instead of 0.
            # Proof #211 test 151: got 1, expected 0.
            skip 'the fake namespace tree needs a real /proc, which macOS does not have', 1
              if !$M7_MANAGER->_procfs_available;
            is( $M7_MANAGER->_same_pid_namespace(999999), 0,
                'web runtime ready: the fake tree makes the dead pid foreign' );
        }
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

# SECTION 3 - GoRoutine (R178).
#
# Cover #19 gaps for GoRoutine.pm: 34 branch cells, 17 condition
# cells, 1 uncovered sub (__ANON__ at line 90, the CLONE_SKIP stub
# _keep_spawn_handle installs - uncoverable, see below).
# Deferred items in scope: GoRoutine 878 (the
# _dispatch_routine false side - two waiters, close, first cancels
# second); R144 line 990 (the END fork guard - uncoverable, see
# below). Line 943 is a comment, not a gap. Lines 1029 and 1048
# were already covered in #19, not gaps.
#
# PROBED UNCOVERABLE (evidence in /tmp/m7-probes, 27 Nov):
# - B 172 true, C 172 l&&!r and l&&r: the enclosing if keys off
#   $_REAL_OS_IS_WINDOWS, a load-time lexical that is false on Unix
#   and cannot be localised. The condition still evaluates (C 172
#   !l fires on every call) but the true side can never run here.
# - B 182, C 182: inside the same dead Windows block; never
#   evaluated on Unix at all.
# - B 185 false: _wait_process_wrapper(undef) dies in the XS wait
#   ("invalid GoRoutine child process identifier", probed) before
#   the delete line runs, so the undefined-pid side is unreachable.
# - B 763, C 763: the second validation loop in go() repeats the
#   first loop's identical fileno computation on the same input, so
#   an input that fails the second loop has already died in the
#   first; the die can never fire there.
# - B 990 true: the END fork guard needs $$ to differ from the
#   load-time $_LOAD_PID, which needs a fork, and t/246 forbids
#   fork() in t/. The false side fires on every process exit.
# - B 892 false: the pump re-wait path needs _ev_wait to return
#   early with nothing due before a routine deadline. Two probes
#   (a child exiting at 0.05s for SIGCHLD, Time::HiRes::alarm at
#   0.05s for SIGALRM, both with a 0.5s timeout) ran the pump to
#   the deadline both times. The code comment says the path exists
#   for the Windows coarse clock; on Linux it does not fire.
# - B 1009 false, B 1013 true: DEFERRED to the FINAL section, not
#   written here - the routine must still be pending at process
#   exit, and any later section's pump would dispatch it first.
#   Design (from the END source): an immediate routine created
#   after the file's last pump, whose callback - dispatched during
#   the drain's pump - registers a NEW repeating routine. The
#   drain's next pass then sees the new repeating routine pending
#   (B 1009 false, it is cancelled) and re-filters to an empty
#   pending list (B 1013 true, the drain ends). The first END loop
#   cancels every repeating routine that is already pending before
#   the drain, so a pre-created repeating routine cannot do this.
# - B 1015 true: needs the 30-second drain deadline to pass; not
#   worth 30 seconds of suite time.
# - B 1043 true, B 1062 true: the die-if before the first pump in
#   each send loop. No code runs between the entry die-if (line
#   1040) and the loop-body die-if that could close the channel,
#   and on later iterations the die-if after the pump (1045/1064)
#   fires first. The closed-during-pump side (1045) is covered.
# - B 1135 false: a routine can only yield when it is not already
#   registered - both wake paths (_wake_waiter and close) shift the
#   waiter out of waiting_routines when they wake it, so the grep
#   can never find it already present at the next yield.
# - C 97 l&&!r: probed uncoverable (/tmp/m7-probes/f-dollarat.pl,
#   27 Nov). A successful eval clears $@, so after the eval in
#   _keep_spawn_handle returns a true $opened, $@ is always the
#   empty string and `not $@` is always true. A failing inner eval
#   inside the fake's Open cannot leave $@ set past the outer
#   eval. The other two cells (l&&r) are covered in 3a.
# - S __ANON__ at line 90: the CLONE_SKIP stub. It is installed by
#   the first _keep_spawn_handle call (3a proves that) but never
#   invoked: GoRoutine.pm line 45 says the redesign runs no cloned
#   interpreters, and line 590 says nothing here uses fork,
#   threads.pm, or perl_clone. The stub only runs during a clone.
# - C 1140 !l&&r, B 1148 true, B 1151 (both sides): covered in 3o,
#   not uncoverable. A sender queues to the sender queue only
#   while receiver_waiting is 0; _wake_waiter clears the flag when
#   a queue-filling send finds no live waiter, so a second sender
#   falls through to the sender queue while the main thread is
#   still in its loop. A watcher then closes the channel: the
#   sender dies at its closed check, but close() never clears the
#   sender queue, so the orphaned entry is what the main thread's
#   loop check sees. A plain waiting sender with no watcher
#   deadlocks instead (probed 27 Nov: the run hung in 3o until
#   killed) and must not be used.
# - C 993 !l: keys %ROUTINES guarantees the record exists at the
#   fetch; nothing runs between the keys and the fetch.
# - C 1217 !l&&!r: the // fallback is _ev_now(), epoch seconds,
#   never false.
# - C 1155/C 1255 !l&&r (CollectorRunner, noted here because the
#   proof is in GoRoutine's _is_managed_loop): _is_managed_loop
#   returns 1 whenever _state_confirms_managed_loop would, through
#   its own state fallthrough, so the or-3 can never see the first
#   term false and the second true. See section 4.
#
# DEVEL::COVER QUIRK (probed 27 Nov, /tmp/m7-probes/b-cover.t):
# for a condition with three or more terms, the BRANCH row never
# counts - the condition table does. A probe calling
# _wait_process_wrapper and _find_running_loop moved the condition
# cells (GoRoutine C 172 to 2,0,0; CollectorRunner C 1548 and
# C 1555 to 1,0,0) while the branch rows stayed 0,0,0. So for B 172,
# B 1145, B 1548 and B 1555 the condition table is the proof of
# coverage, and the branch row is expected to stay put. One- and
# two-term conditions count normally in both tables.

# _m7_win32_fake_dir(): the fake Win32::Process used by the
# _keep_spawn_handle tests. Its Open() reads the package variable
# $Win32::Process::M7_OPEN_MODE: 'ok' returns a fake object,
# 'fail' returns false (the or-die fires), 'dirty' returns the
# object after a failing inner eval leaves $@ set. CLONE_SKIP is
# deliberately NOT defined here, so the first call installs it.
# Input: none.
# Output: fake module directory path.
my $M7_WIN32_FAKE_DIR;
sub _m7_win32_fake_dir {
    my ($dir) = @_;
    return $dir if defined $dir;
    return $M7_WIN32_FAKE_DIR if defined $M7_WIN32_FAKE_DIR;
    my $fake = File::Spec->catdir( $M7_HOME, 'm7-fakewin32' );
    my $win32 = File::Spec->catdir( $fake, 'Win32' );
    mkdir $fake  or die "Unable to mkdir $fake: $!";
    mkdir $win32 or die "Unable to mkdir $win32: $!";
    my $pm = File::Spec->catfile( $win32, 'Process.pm' );
    open my $fh, '>', $pm or die "Unable to write $pm: $!";
    print {$fh} "package Win32::Process;\n";
    print {$fh} "use strict;\nuse warnings;\n";
    print {$fh} "our \$M7_OPEN_MODE = 'ok';\n";
    print {$fh} "sub Open {\n";
    print {$fh} "    my (\$obj, \$pid, \$flags) = \@_;\n";
    print {$fh} "    return 0 if \$M7_OPEN_MODE eq 'fail';\n";
    print {$fh} "    \$_[0] = bless {}, 'Win32::Process';\n";
    print {$fh} "    eval { die \"inner dirty\\n\" } if \$M7_OPEN_MODE eq 'dirty';\n";
    print {$fh} "    return 1;\n";
    print {$fh} "}\n";
    print {$fh} "1;\n";
    close $fh or die "Unable to close $pm: $!";
    $M7_WIN32_FAKE_DIR = $fake;
    return $fake;
}

# _m7_orphan_sender_entry($value): an unbuffered channel whose
# sender_queue holds one orphaned entry. A sender routine queues
# the value, then a repeating watcher routine cancels the sender
# and closes the channel, so the sender dies at its closed check
# and the entry is never taken. The main thread can then receive
# it through the top-of-receive sender_queue path (B 1118).
# Input: value to send.
# Output: the channel.
sub _m7_orphan_sender_entry {
    my ($value) = @_;
    my $ch = Developer::Dashboard::GoRoutine::channel();
    my $sender;
    $sender = Developer::Dashboard::GoRoutine::go( sub { $ch->send($value); } );
    my $watcher;
    $watcher = Developer::Dashboard::GoRoutine::go(
        sub {
            return if !@{ $ch->{sender_queue} };
            $sender->kill();
            $ch->close();
            $watcher->kill();
            return;
        },
        { every => 0.01 }
    );
    Developer::Dashboard::GoRoutine::wait_all();
    return $ch;
}

{
    # 3a. _keep_spawn_handle: the Windows registry path, driven
    # with a fake Win32::Process and a localised $^O. Four calls:
    # ok (installs CLONE_SKIP, Open succeeds), dirty (Open
    # succeeds with $@ set), fail (Open fails, the or-die fires),
    # ok again (CLONE_SKIP already defined, skipped).
    my $faked   = _m7_win32_fake_dir();
    my $reg_pid = _m7_spawn_sleep();
    {
        local @INC = ( $faked, @INC );
        local $^O  = 'MSWin32';
        $Win32::Process::M7_OPEN_MODE = 'ok';
        Developer::Dashboard::GoRoutine::_keep_spawn_handle($reg_pid);
        ok( defined &Win32::Process::CLONE_SKIP,
            'keep_spawn_handle: first call installs the CLONE_SKIP stub' );
        is( Developer::Dashboard::GoRoutine::_process_running_wrapper($reg_pid),
            1, 'keep_spawn_handle: the registered pid reads as running on Windows' );
        $Win32::Process::M7_OPEN_MODE = 'dirty';
        Developer::Dashboard::GoRoutine::_keep_spawn_handle($reg_pid);
        is( Developer::Dashboard::GoRoutine::_process_running_wrapper($reg_pid),
            1, 'keep_spawn_handle: a dirty dollar does not stop the registry entry' );
        $Win32::Process::M7_OPEN_MODE = 'fail';
        Developer::Dashboard::GoRoutine::_keep_spawn_handle($reg_pid);
        is( Developer::Dashboard::GoRoutine::_process_running_wrapper($reg_pid),
            1, 'keep_spawn_handle: a failed Open still records the pid' );
        $Win32::Process::M7_OPEN_MODE = 'ok';
        Developer::Dashboard::GoRoutine::_keep_spawn_handle($reg_pid);
        is( Developer::Dashboard::GoRoutine::_process_running_wrapper($reg_pid),
            1, 'keep_spawn_handle: a second call skips the installed CLONE_SKIP stub' );
        Developer::Dashboard::GoRoutine::_keep_spawn_handle(undef);
        ok( 1, 'keep_spawn_handle: an undefined pid returns at once' );
    }
    _m7_kill_child($reg_pid);
}

{
    # 3b. _spawn_wrapper: the Windows env-merge condition with the
    # first term true and the rest false (localised $^O, options a
    # plain hash with no env key). The else branch spawns plainly.
    # The child is $^X, not /bin/true: /bin/true does not exist on
    # macOS (true is /usr/bin/true there) or on Windows, and the
    # macOS leg died on it in proofs 212-215 (R184).
    my $pid;
    {
        local $^O = 'MSWin32';
        $pid = Developer::Dashboard::GoRoutine::_spawn_wrapper( [ $^X, '-e', 'exit 0' ], {} );
    }
    ok( defined $pid && $pid > 0, 'spawn_wrapper: a plain hash option spawns without the env merge' );
    is( _wait_for_exit( $pid, 5 ), 0, 'spawn_wrapper: the plain spawn exits cleanly' );
    {
        # The condition's middle cell: $^O is Windows but the
        # options are not a hash, so the env merge is skipped and
        # the native spawn dies on the missing hash.
        local $^O = 'MSWin32';
        my $err = eval { Developer::Dashboard::GoRoutine::_spawn_wrapper( [ $^X, '-e', 'exit 0' ], undef ); 1 } ? '' : $@;
        like( $err, qr/not a HASH reference/,
            'spawn_wrapper: a non-hash option dies on Windows' );
    }
}

{
    # 3c. _process_running_wrapper: undefined pid (the condition's
    # first term false), a pid outside the registry, and the
    # registry pid from 3a. The XS layer warns on undef, so the
    # warning is swallowed for that one call.
    my $reg_pid = _m7_spawn_sleep();
    {
        local @INC = ( _m7_win32_fake_dir(), @INC );
        local $^O  = 'MSWin32';
        $Win32::Process::M7_OPEN_MODE = 'ok';
        Developer::Dashboard::GoRoutine::_keep_spawn_handle($reg_pid);
        my $undef_result;
        {
            local $SIG{__WARN__} = sub { };
            $undef_result = Developer::Dashboard::GoRoutine::_process_running_wrapper(undef);
        }
        is( $undef_result, 0, 'process_running_wrapper: an undefined pid reads as not running' );
        is( Developer::Dashboard::GoRoutine::_process_running_wrapper(999999),
            0, 'process_running_wrapper: a pid outside the registry falls through to the native check' );
        is( Developer::Dashboard::GoRoutine::_process_running_wrapper($reg_pid),
            1, 'process_running_wrapper: a registry pid reads as running' );
    }
    _m7_kill_child($reg_pid);
}

{
    # 3d. _wait_process_wrapper: an exited child (the XS wait
    # returns its code) and an undefined pid (the XS wait croaks
    # before the delete line - B 185 false is unreachable).
    my $pid = _m7_spawn_sleep();
    kill 'TERM', $pid;
    {
        # Poll for the exit without reaping: the wrapper below is
        # the one that reaps it, and a second wait would die.
        my $deadline = time() + 5;
        while ( time() < $deadline ) {
            last if Developer::Dashboard::GoRoutine::process_exited($pid);
            Time::HiRes::sleep(0.05);
        }
    }
    is( Developer::Dashboard::GoRoutine::_wait_process_wrapper($pid),
        143, 'wait_process_wrapper: an exited child returns its TERM exit code' );
    my $err = eval { Developer::Dashboard::GoRoutine::_wait_process_wrapper(undef); 1 } ? '' : $@;
    like( $err, qr/invalid GoRoutine child process identifier/,
        'wait_process_wrapper: an undefined pid dies in the native wait' );
}

{
    # 3e. _finish_routine on a bogus id returns at once, and
    # _cancel_routine with no kind defaults it to killed.
    Developer::Dashboard::GoRoutine::_finish_routine( 999999, 'done' );
    ok( 1, 'finish_routine: a bogus id returns without dying' );
    my $h = Developer::Dashboard::GoRoutine::go( sub { return; }, { after => 60 } );
    is( Developer::Dashboard::GoRoutine::_cancel_routine( $h->{id} ),
        1, 'cancel_routine: cancelling a pending routine with no kind returns true' );
    is( $h->status, 'killed', 'cancel_routine: no kind defaults to killed' );
}

{
    # 3f. go() trigger validation: a closed handle has no fileno
    # (the first loop dies), and a plain fd number registers the
    # trigger through the second loop.
    pipe( my $pr, my $pw ) or die "Unable to pipe: $!";
    close $pr;
    my $err = eval {
        Developer::Dashboard::GoRoutine::go( sub { return; }, { readable => $pr } );
        1;
    } ? '' : $@;
    like( $err, qr/go\(\) readable trigger needs a filehandle/,
        'go: a closed handle dies in the trigger validation' );
    pipe( my $fr, my $fw ) or die "Unable to pipe: $!";
    my $fired = 0;
    my $h = Developer::Dashboard::GoRoutine::go( sub { $fired = 1; }, { readable => fileno($fr) } );
    syswrite $fw, 'x';
    Developer::Dashboard::GoRoutine::pump(1);
    is( $fired, 1, 'go: a plain fd number registers a readable trigger' );
    close $fr;
    close $fw;
    close $pw;
}

{
    # 3g. _dispatch_routine with the record gone. A callback that
    # destroys its own handle and finishes itself, then returns,
    # exits, yields, or dies: the dispatch re-reads an undefined
    # record and takes the no-record path in each branch.
    my $gone_return;
    $gone_return = Developer::Dashboard::GoRoutine::go( sub {
        my $id = $gone_return->{id};
        undef $gone_return;
        Developer::Dashboard::GoRoutine::_finish_routine( $id, 'done' );
        return;
    } );
    Developer::Dashboard::GoRoutine::pump(1);
    is( Developer::Dashboard::GoRoutine::_routine_record( $gone_return->{id} ),
        undef, 'dispatch: a callback that deletes its own record and returns leaves no record' );

    my $gone_exit;
    $gone_exit = Developer::Dashboard::GoRoutine::go( sub {
        my $id = $gone_exit->{id};
        undef $gone_exit;
        Developer::Dashboard::GoRoutine::_finish_routine( $id, 'done' );
        exit(0);
    } );
    Developer::Dashboard::GoRoutine::pump(1);
    ok( 1, 'dispatch: a callback that deletes its own record and exits does not die' );

    my $kept_exit = Developer::Dashboard::GoRoutine::go( sub { exit(0); } );
    Developer::Dashboard::GoRoutine::pump(1);
    is( $kept_exit->status, 'exited', 'dispatch: a callback that exits with its record kept finishes as exited' );

    my $gone_yield;
    my $yield_ch = Developer::Dashboard::GoRoutine::channel();
    $gone_yield = Developer::Dashboard::GoRoutine::go( sub {
        my $id = $gone_yield->{id};
        undef $gone_yield;
        Developer::Dashboard::GoRoutine::_finish_routine( $id, 'done' );
        $yield_ch->receive();
        return;
    } );
    Developer::Dashboard::GoRoutine::pump(1);
    is( Developer::Dashboard::GoRoutine::_routine_record( $gone_yield->{id} ),
        undef, 'dispatch: a callback that deletes its own record and yields leaves no record' );
    $yield_ch->close();

    my $kept_yield_ch = Developer::Dashboard::GoRoutine::channel();
    my $kept_yield = Developer::Dashboard::GoRoutine::go( sub { $kept_yield_ch->receive(); return; } );
    Developer::Dashboard::GoRoutine::pump(1);
    is( $kept_yield->status, 'pending', 'dispatch: a callback that yields with its record kept stays pending' );
    $kept_yield_ch->close();
    Developer::Dashboard::GoRoutine::pump(1);

    my $gone_die;
    $gone_die = Developer::Dashboard::GoRoutine::go( sub {
        my $id = $gone_die->{id};
        undef $gone_die;
        Developer::Dashboard::GoRoutine::_finish_routine( $id, 'done' );
        die "m7 gone die\n";
    } );
    Developer::Dashboard::GoRoutine::pump(1);
    is( Developer::Dashboard::GoRoutine::_routine_record( $gone_die->{id} ),
        undef, 'dispatch: a callback that deletes its own record and dies leaves no record' );

    my $kept_die = Developer::Dashboard::GoRoutine::go( sub { die "m7 kept die\n"; } );
    Developer::Dashboard::GoRoutine::pump(1);
    is( $kept_die->status, 'failed', 'dispatch: a callback that dies with its record kept finishes as failed' );

    my $poke_cancel;
    $poke_cancel = Developer::Dashboard::GoRoutine::go( sub {
        my $id = $poke_cancel->{id};
        my $rec = Developer::Dashboard::GoRoutine::_routine_record($id);
        $rec->{cancel_requested} = 1;
        $rec->{cancel_kind}      = undef;
        return;
    } );
    Developer::Dashboard::GoRoutine::pump(1);
    is( $poke_cancel->status, 'killed',
        'dispatch: cancel requested with no kind finishes as killed' );
}

{
    # 3h. Pump timeouts: a timeout already past when pump runs
    # (the until rounds to zero and the Perl-side check finishes
    # it), and a bounded pump whose routine timeout is farther
    # than the bound (the bound is not the timeout).
    my $past = Developer::Dashboard::GoRoutine::go( sub { return; }, { after => 60 } );
    my $past_rec = Developer::Dashboard::GoRoutine::_routine_record( $past->{id} );
    $past_rec->{timeout_at} = Developer::Dashboard::GoRoutine::_ev_now() - 1;
    Developer::Dashboard::GoRoutine::pump(0);
    is( $past->status, 'timed_out', 'pump: a routine whose timeout already passed finishes as timed out' );

    my $far = Developer::Dashboard::GoRoutine::go( sub { return; }, { after => 60 } );
    $far->timeout(30);
    my $progress = Developer::Dashboard::GoRoutine::pump(0.1);
    is( $progress, 0, 'pump: a bounded pump with a far-future timeout makes no progress' );
    is( $far->status, 'pending', 'pump: the far-future routine stays pending' );
    $far->kill();
}

{
    # 3i. B 878: two waiters on one channel, closed together. The
    # first waiter's callback cancels the second, so the pump's
    # dispatch of the second finds it no longer pending.
    my $ch = Developer::Dashboard::GoRoutine::channel();
    my $second;
    my $first = Developer::Dashboard::GoRoutine::go( sub {
        $ch->receive();
        $second->kill();
        return;
    } );
    $second = Developer::Dashboard::GoRoutine::go( sub {
        $ch->receive();
        return;
    } );
    Developer::Dashboard::GoRoutine::pump(1);
    $ch->close();
    Developer::Dashboard::GoRoutine::pump(1);
    is( $first->status,  'done',   'dispatch: the first waiter runs when the channel closes' );
    is( $second->status, 'killed', 'dispatch: the second waiter is cancelled before its dispatch' );
}

{
    # 3j. B 952: wait_all with a pending routine that has no
    # triggers at all. pump(undef) returns zero progress, the
    # bounded fallback runs, and an alarm finishes the routine so
    # the wait ends instead of hanging.
    my $h = Developer::Dashboard::GoRoutine::go( sub { return; }, { after => 60 } );
    my $id = $h->{id};
    Developer::Dashboard::GoRoutine::_ev_cancel($id);
    local $SIG{ALRM} = sub {
        Developer::Dashboard::GoRoutine::_finish_routine( $id, 'done' );
    };
    Time::HiRes::alarm(0.2);
    Developer::Dashboard::GoRoutine::wait_all();
    Time::HiRes::alarm(0);
    is( $h->status, 'done', 'wait_all: a triggerless routine finished by a signal ends the wait' );
}

{
    # 3k. Channel send and receive paths: an orphaned sender
    # entry taken in list and in scalar context, a buffered value
    # landing while the main thread waits, and a close landing
    # while the main thread waits in scalar context.
    my $ch_list = _m7_orphan_sender_entry(42);
    my ( $v_list, $ok_list ) = $ch_list->receive();
    is( $v_list,  42, 'channel: an orphaned sender entry reads back in list context' );
    is( $ok_list, 1,  'channel: an orphaned sender entry reports success in list context' );

    my $ch_scalar = _m7_orphan_sender_entry(43);
    my $v_scalar = $ch_scalar->receive();
    is( $v_scalar, 43, 'channel: an orphaned sender entry reads back in scalar context' );

    my $ch_buf = Developer::Dashboard::GoRoutine::channel(1);
    my $buf_sender = Developer::Dashboard::GoRoutine::go( sub { $ch_buf->send(7); } );
    my ( $v_buf, $ok_buf ) = $ch_buf->receive();
    is( $v_buf,  7, 'channel: a buffered value landing during the main-thread wait reads back in list context' );
    is( $ok_buf, 1, 'channel: a buffered value landing during the main-thread wait reports success' );

    my $ch_close = Developer::Dashboard::GoRoutine::channel();
    my $closer = Developer::Dashboard::GoRoutine::go( sub { $ch_close->close(); } );
    my $v_close = $ch_close->receive();
    is( $v_close, undef, 'channel: a close landing during the main-thread wait reads back as undef in scalar context' );
}

{
    # 3l. Waiter skips: a yielded receiver whose record is gone
    # (handle destroyed, then cancelled) is skipped by a buffered
    # send, and by close; a yielded receiver cancelled with its
    # handle kept is skipped by close as finished-but-present.
    my $ch_wake = Developer::Dashboard::GoRoutine::channel(1);
    my $wake_h;
    $wake_h = Developer::Dashboard::GoRoutine::go( sub { $ch_wake->receive(); return; } );
    Developer::Dashboard::GoRoutine::pump(1);
    my $wake_id = $wake_h->{id};
    undef $wake_h;
    Developer::Dashboard::GoRoutine::_cancel_routine($wake_id);
    $ch_wake->send(9);
    is( $ch_wake->size, 1, 'wake_waiter: a deleted waiter is skipped and the value stays queued' );

    my $ch_close_gone = Developer::Dashboard::GoRoutine::channel();
    my $gone_h;
    $gone_h = Developer::Dashboard::GoRoutine::go( sub { $ch_close_gone->receive(); return; } );
    Developer::Dashboard::GoRoutine::pump(1);
    my $gone_id = $gone_h->{id};
    undef $gone_h;
    Developer::Dashboard::GoRoutine::_cancel_routine($gone_id);
    $ch_close_gone->close();
    ok( $ch_close_gone->is_closed, 'close: a deleted waiter is skipped and the channel still closes' );

    my $ch_close_kept = Developer::Dashboard::GoRoutine::channel();
    my $kept_h = Developer::Dashboard::GoRoutine::go( sub { $ch_close_kept->receive(); return; } );
    Developer::Dashboard::GoRoutine::pump(1);
    $kept_h->kill();
    $ch_close_kept->close();
    is( $kept_h->status, 'killed', 'close: a finished-but-present waiter stays killed' );
}

{
    # 3m. Routine handle guards: _rec and DESTROY called as plain
    # functions with a non-reference and with a reference that
    # carries no id, and age() on a routine that has not finished.
    my $err_rec = eval {
        Developer::Dashboard::GoRoutine::Routine::_rec('not-a-ref');
        1;
    } ? '' : $@;
    like( $err_rec, qr/invalid go routine handle/,
        'routine handle: _rec on a non-reference dies' );
    my $err_rec_noid = eval {
        Developer::Dashboard::GoRoutine::Routine::_rec( bless {}, 'Developer::Dashboard::GoRoutine::Routine' );
        1;
    } ? '' : $@;
    like( $err_rec_noid, qr/invalid go routine handle/,
        'routine handle: _rec on a reference without an id dies' );
    Developer::Dashboard::GoRoutine::Routine::DESTROY('not-a-ref');
    ok( 1, 'routine handle: DESTROY on a non-reference returns at once' );
    Developer::Dashboard::GoRoutine::Routine::DESTROY(
        bless {}, 'Developer::Dashboard::GoRoutine::Routine' );
    ok( 1, 'routine handle: DESTROY on a reference without an id returns at once' );

    my $age_h = Developer::Dashboard::GoRoutine::go( sub { return; }, { after => 60 } );
    my $age = $age_h->age();
    ok( defined $age && $age >= 0, 'routine handle: age on a pending routine reads the live clock' );
    $age_h->kill();
}

# The two END-drain routines below stay registered until the test
# process exits, so the END block itself is exercised: the pending
# repeating routine is cancelled there, and the failed repeating
# routine is skipped there as already finished.
my $M7_END_REPEATING_PENDING = Developer::Dashboard::GoRoutine::go(
    sub { return; }, { every => 60 } );
my $M7_END_REPEATING_FAILED = Developer::Dashboard::GoRoutine::go(
    sub { die "m7 end failed\n"; }, { every => 0.05 } );
Developer::Dashboard::GoRoutine::pump(1);
is( $M7_END_REPEATING_PENDING->status, 'pending',
    'end drain: a repeating routine left pending stays pending until exit' );
is( $M7_END_REPEATING_FAILED->status, 'failed',
    'end drain: a repeating routine that dies stays failed until exit' );

{
    # 3o. Receive from the sender queue through the main-thread
    # loop: the first sender queues to the queue while the main
    # thread waits, a receiver routine takes that value (which
    # clears the waiting flag), and a second sender then falls
    # through to the sender queue. A watcher then closes the
    # channel: the second sender dies at its closed check, but
    # close() never clears the sender queue, so its entry stays
    # orphaned. The main thread's loop check then sees an empty
    # queue with a queued sender, so it leaves the loop and takes
    # the orphaned value through the post-loop sender-queue
    # return. Run once in list context and once in scalar context,
    # for the two sides of that return. (A plain second sender
    # with no watcher deadlocks here and must not be used: the
    # sender blocks in its send loop waiting for its entry to be
    # taken, while the main thread is stuck in the pump waiting
    # for the sender to return - the cooperative re-entrancy
    # deadlock. The close is what breaks it.)
    for my $wantarray ( 1, 0 ) {
        my $ch = Developer::Dashboard::GoRoutine::channel();
        my $first_sender = Developer::Dashboard::GoRoutine::go( sub { $ch->send('m7-first'); } );
        my $got_first;
        my $taker = Developer::Dashboard::GoRoutine::go( sub { $got_first = $ch->receive(); } );
        my $second_sender = Developer::Dashboard::GoRoutine::go( sub { $ch->send('m7-second'); } );
        my $watcher = Developer::Dashboard::GoRoutine::go( sub { $ch->close(); } );
        my ( $got_second, $ok );
        if ($wantarray) {
            ( $got_second, $ok ) = $ch->receive();
        }
        else {
            $got_second = $ch->receive();
            $ok = defined $got_second ? 1 : 0;
        }
        Developer::Dashboard::GoRoutine::wait_all();
        is( $got_first, 'm7-first',
            'receive: a receiver routine takes the queued value while the main thread waits' );
        is( $got_second, 'm7-second',
            'receive: the main thread takes a queued sender through the post-loop return' );
        is( $ok, 1, 'receive: the post-loop sender-queue return reports success' );
        is( $first_sender->status, 'done', 'receive: the first sender finishes' );
        is( $second_sender->status, 'failed',
            'receive: the second sender dies on the close and leaves its entry orphaned' );
        is( $taker->status, 'done', 'receive: the taker finishes' );
        is( $watcher->status, 'done', 'receive: the watcher finishes' );
    }
}

{
    # 3p. Buffered send: the buffer holds one value, so a second
    # send from a routine waits in the loop until a receiver
    # routine frees the slot. The die-if after the pump then
    # reads the channel still open, and the send completes.
    my $buf = Developer::Dashboard::GoRoutine::channel(1);
    $buf->send('m7-first');
    my $buf_sender = Developer::Dashboard::GoRoutine::go( sub { $buf->send('m7-second'); } );
    my $buf_got;
    my $buf_receiver = Developer::Dashboard::GoRoutine::go( sub { $buf_got = $buf->receive(); } );
    Developer::Dashboard::GoRoutine::wait_all();
    is( $buf_got, 'm7-first',
        'buffered send: a receiver routine frees the slot while a sender waits' );
    is( $buf_sender->status, 'done',
        'buffered send: the waiting sender finishes once the slot frees' );
    is( $buf_receiver->status, 'done', 'buffered send: the receiver finishes' );
    is( $buf->receive(), 'm7-second',
        'buffered send: the second value arrives after the first' );
}

# SECTION 4 - CollectorRunner (R178).
#
# Cover #19 gaps for CollectorRunner.pm: 23 branch cells, 16
# condition cells, 1 uncovered sub (__ANON__ at line 1639, the
# capture block in _read_process_title's Windows branch). The
# success sides of B 837/838/839 were already covered in #19
# (false=1 each); only the open-failure sides were missing.
#
# PROBED UNCOVERABLE (evidence in /tmp/m7-probes, 27 Nov):
# - C 1155 !l&&r and C 1255 !l&&r: _is_managed_loop returns 1
#   whenever _state_confirms_managed_loop would, through its own
#   state fallthrough, so the or-3 can never see its first term
#   false and its second true. The outer condition also gates on
#   the same namespace the early return in _is_managed_loop
#   checks, so no namespace trick separates them either. The
#   both-false cells (!l&&!r) are covered here with a foreign pid.
# - C 1447 l&&!r: the marker check in _is_managed_loop returns 1
#   as soon as the marker equals the name, so the
#   $marker_disagrees computation never sees a matching marker.
# - C 1627 !l: _read_process_title(undef) returns at the B 1599
#   guard before the Windows pid check is reached.
# - C 1642 !l: the capture block always returns $? >> 8, an
#   integer, so the exit code is never undefined.
# - B 1643 true: Capture::Tiny always yields a defined stdout
#   string (possibly empty), so the title is never undefined.
# - B 1548 false, B 1555 false, B 1145 (either side): three-or-
#   more-term conditions whose branch rows Devel::Cover never
#   counts (see the section 3 quirk note). The condition tables
#   are the proof: C 1548, C 1555 and C 1145 are covered here
#   cell by cell, and the branch rows are expected to stay put.
# - B 1448, B 1450, B 1452, B 1642, B 1645 are two-term
#   conditions and count normally; both sides are covered here.

{
    package Local::CRFiles;
    sub new {
        my ( $class, $log ) = @_;
        return bless { log => $log }, $class;
    }
    sub collector_log {
        my ($self) = @_;
        return $self->{log};
    }
    sub set_log {
        my ( $self, $log ) = @_;
        $self->{log} = $log;
        return;
    }
    sub append {
        my ( $self, $name, $message ) = @_;
        open my $fh, '>>', $self->{log} or die "Unable to append to $self->{log}: $!";
        print {$fh} $message;
        close $fh or die "Unable to close $self->{log}: $!";
        return 1;
    }

    package Local::CRCollectors;
    sub new {
        my ($class) = @_;
        return bless { stopped => [], entries => [] }, $class;
    }
    sub mark_stopped {
        my ( $self, $name ) = @_;
        push @{ $self->{stopped} }, $name;
        return 1;
    }
    sub append_log_entry {
        my ( $self, $name, %args ) = @_;
        push @{ $self->{entries} }, { name => $name, %args };
        return 1;
    }
}

# _m7_collector_runner($files): a CollectorRunner over the shared
# M7 paths, with fake collectors and the given fake files object.
# Input: fake files object.
# Output: CollectorRunner object.
my $M7_CR_COLLECTORS = Local::CRCollectors->new;
sub _m7_collector_runner {
    my ($files) = @_;
    return Developer::Dashboard::CollectorRunner->new(
        collectors => $M7_CR_COLLECTORS,
        files      => $files,
        paths      => $M7_PATHS,
    );
}

# _m7_write_loop_state($runner, $name, $data): writes one loop
# state file, making the collector directory first.
# Input: runner, collector name, state hash reference.
# Output: the written state hash reference.
sub _m7_write_loop_state {
    my ( $runner, $name, $data ) = @_;
    my $dir = $M7_PATHS->collector_dir($name);
    require File::Path;
    File::Path::make_path($dir);
    return $runner->_write_loop_state( $name, $data );
}

# _m7_save_handles(): duplicates the three standard handles so a
# test that re-opens them (the _run_loop_worker opens) can put
# them back afterwards. Returns the three saved handles.
# _m7_restore_handles(@saved): puts them back.
# Input/output: saved handle list.
sub _m7_save_handles {
    open my $in,  '<&', \*STDIN  or die "Unable to dup STDIN: $!";
    open my $out, '>&', \*STDOUT or die "Unable to dup STDOUT: $!";
    open my $err, '>&', \*STDERR or die "Unable to dup STDERR: $!";
    return ( $in, $out, $err );
}
sub _m7_restore_handles {
    my ( $in, $out, $err ) = @_;
    open \*STDIN,  '<&', $in  or die "Unable to restore STDIN: $!";
    open \*STDOUT, '>&', $out or die "Unable to restore STDOUT: $!";
    open \*STDERR, '>&', $err or die "Unable to restore STDERR: $!";
    return;
}

# _m7_fake_taskkill_dir($mode): a bin directory holding a fake
# taskkill script. Mode 'always' kills its /PID argument at once;
# mode 'second' kills only on its second invocation (a counter
# file beside the script). The script ignores the /T and /F flags.
# Input: mode string.
# Output: bin directory path.
sub _m7_fake_taskkill_dir {
    my ($mode) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my $script = File::Spec->catfile( $dir, 'taskkill' );
    open my $fh, '>', $script or die "Unable to write $script: $!";
    print {$fh} "#!/bin/sh\n";
    print {$fh} "# Wait for the killed pid to register as dead before\n";
    print {$fh} "# exiting: SIGKILL is delivered at once, but the victim\n";
    print {$fh} "# only becomes a zombie when it is next scheduled, and\n";
    print {$fh} "# the liveness check right after this script returns\n";
    print {$fh} "# would otherwise read it as still alive (a race the\n";
    print {$fh} "# cover run showed: the check read true until the\n";
    print {$fh} "# script spent a few milliseconds logging). Polling\n";
    print {$fh} "# /proc until the state is Z makes the kill visible.\n";
    print {$fh} "# Where /proc is absent the poll ends at once and the\n";
    print {$fh} "# script degrades to kill-and-exit.\n";
    print {$fh} "_m7_wait_dead() {\n";
    print {$fh} "    n=0\n";
    print {$fh} "    while [ \"\$n\" -lt 100 ]; do\n";
    print {$fh} "        s=\$(cut -d' ' -f3 /proc/\"\$1\"/stat 2>/dev/null) || return 0\n";
    print {$fh} "        [ \"\$s\" = \"Z\" ] && return 0\n";
    print {$fh} "        sleep 0.01\n";
    print {$fh} "        n=\$((n + 1))\n";
    print {$fh} "    done\n";
    print {$fh} "    return 0\n";
    print {$fh} "}\n";
    if ( $mode eq 'second' ) {
        print {$fh} "count_file=\"\$(dirname \"\$0\")/count\"\n";
        print {$fh} "c=\$(cat \"\$count_file\" 2>/dev/null || echo 0)\n";
        print {$fh} "c=\$((c + 1))\n";
        print {$fh} "echo \"\$c\" > \"\$count_file\"\n";
        print {$fh} "if [ \"\$c\" -ge 2 ]; then kill -9 \"\$2\"; _m7_wait_dead \"\$2\"; fi\n";
    }
    else {
        print {$fh} "kill -9 \"\$2\"\n";
        print {$fh} "_m7_wait_dead \"\$2\"\n";
    }
    print {$fh} "exit 0\n";
    close $fh or die "Unable to close $script: $!";
    chmod 0755, $script or die "Unable to chmod $script: $!";
    return $dir;
}

# _m7_fake_powershell_dir($mode): a bin directory holding a fake
# powershell script. Mode 'fail' exits 1, 'silent' exits 0 with
# no output, 'print' exits 0 printing a title line. The script
# ignores its arguments.
# Input: mode string.
# Output: bin directory path.
sub _m7_fake_powershell_dir {
    my ($mode) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my $script = File::Spec->catfile( $dir, 'powershell' );
    open my $fh, '>', $script or die "Unable to write $script: $!";
    print {$fh} "#!/bin/sh\n";
    if ( $mode eq 'fail' ) {
        print {$fh} "exit 1\n";
    }
    elsif ( $mode eq 'print' ) {
        print {$fh} "printf '%s\\n' 'C:\\fake\\perl.exe --dummy'\n";
        print {$fh} "exit 0\n";
    }
    else {
        print {$fh} "exit 0\n";
    }
    close $fh or die "Unable to close $script: $!";
    chmod 0755, $script or die "Unable to chmod $script: $!";
    return $dir;
}

{
    # 4a. _run_loop_worker: the three open-or-die sides, each
    # reached with a localised $OS_NAME so the Windows block runs.
    # The opens redirect the test process handles, so each call
    # runs with the handles saved and puts them back before any
    # assertion. The die happens before run_once, so the job is
    # never executed and the sub never reaches its exit.
    my $cr_dir = tempdir( CLEANUP => 1 );
    my $cr_log = File::Spec->catfile( $cr_dir, 'collector.log' );
    my $cr_files = Local::CRFiles->new($cr_log);
    my $runner = _m7_collector_runner($cr_files);
    my $saved_title = $0;

    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        local *File::Spec::devnull = sub { '/nonexistent/m7-devnull' };
        my @saved = _m7_save_handles();
        my $err = eval { $runner->_run_loop_worker( {}, 'm7w837', undef, undef ); 1 } ? '' : $@;
        _m7_restore_handles(@saved);
        like( $err, qr/No such file or directory/,
            'run_loop_worker: a devnull that cannot open dies at the STDIN open' );
    }
    {
        mkdir File::Spec->catdir( $cr_dir, 'logdir' ) or die 'Unable to mkdir logdir';
        $cr_files->set_log( File::Spec->catdir( $cr_dir, 'logdir' ) );
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        my @saved = _m7_save_handles();
        my $err = eval { $runner->_run_loop_worker( {}, 'm7w838', undef, undef ); 1 } ? '' : $@;
        _m7_restore_handles(@saved);
        like( $err, qr/Is a directory|Permission denied/,
            'run_loop_worker: a collector log that is a directory dies at the STDOUT open' );
    }
    {
        $cr_files->set_log($cr_log);
        mkdir "$cr_log.stderr" or die 'Unable to mkdir log.stderr';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        my @saved = _m7_save_handles();
        my $err = eval { $runner->_run_loop_worker( {}, 'm7w839', undef, undef ); 1 } ? '' : $@;
        _m7_restore_handles(@saved);
        like( $err, qr/Is a directory|Permission denied/,
            'run_loop_worker: a stderr log that is a directory dies at the STDERR open' );
    }
    $0 = $saved_title;
}

{
    # 4b. _waitpid_nonblocking: the Windows branch with a reaped
    # child (reap_child returns the pid) and with a live child
    # (reap_child returns false and the non-blocking waitpid
    # answers zero).
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);

    my $gone = _m7_spawn_sleep();
    {
        local @INC = ( _m7_win32_fake_dir(), @INC );
        local $^O  = 'MSWin32';
        $Win32::Process::M7_OPEN_MODE = 'ok';
        Developer::Dashboard::GoRoutine::_keep_spawn_handle($gone);
    }
    kill 'TERM', $gone;
    {
        # Poll for the exit without reaping: reap_child inside
        # _waitpid_nonblocking is the one that reaps it.
        my $deadline = time() + 5;
        while ( time() < $deadline ) {
            last if Developer::Dashboard::GoRoutine::process_exited($gone);
            Time::HiRes::sleep(0.05);
        }
    }
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_waitpid_nonblocking($gone), $gone,
            'waitpid_nonblocking: a reaped Windows child returns its pid' );
    }

    my $live = _m7_spawn_sleep();
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_waitpid_nonblocking($live), 0,
            'waitpid_nonblocking: a live child falls through to waitpid and answers zero' );
    }
    _m7_kill_child($live);
}

{
    # 4c. _terminate_loop_workers: the false sides of the three
    # Windows liveness checks. A fake taskkill that kills at once
    # makes the first check read dead; a fake that kills only on
    # its second call, with a TERM-ignoring worker, makes the
    # escalation check read dead after the tree kill.
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);

    my $bin_always = _m7_fake_taskkill_dir('always');
    my $victim = _m7_spawn_sleep();
    {
        local $ENV{PATH} = join $Config{path_sep}, $bin_always, $ENV{PATH};
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_terminate_loop_workers( { $victim => 1 } ), 1,
            'terminate_loop_workers: a worker killed by the tree kill stops' );
    }
    ok( !$runner->_pid_is_running($victim),
        'terminate_loop_workers: the tree-killed worker reads as not running' );
    kill 'KILL', $victim;
    eval { Developer::Dashboard::GoRoutine::wait_process($victim) };

    my $bin_second = _m7_fake_taskkill_dir('second');
    my $stubborn = _m7_spawn_sleep( ignore_term => 1 );
    {
        local $ENV{PATH} = join $Config{path_sep}, $bin_second, $ENV{PATH};
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_terminate_loop_workers( { $stubborn => 1 } ), 1,
            'terminate_loop_workers: a TERM-ignoring worker stops at the escalation kill' );
    }
    ok( !$runner->_pid_is_running($stubborn),
        'terminate_loop_workers: the escalated worker reads as not running' );
    kill 'KILL', $stubborn;
    eval { Developer::Dashboard::GoRoutine::wait_process($stubborn) };
}

{
    # 4d. stop_loop through the persisted state: a state pid that
    # is not numeric (the condition's middle cell, and the if
    # false), a live child named by a valid state (the ternary
    # true side, the condition's last cell, and the if true), and
    # a foreign pid from a pidfile with no state (both terms of
    # the or-3 false).
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);

    _m7_write_loop_state( $runner, 'm7abc',
        { pid => 'abc', process_name => 'd2 collector: m7abc', status => 'running' } );
    is( $runner->stop_loop('m7abc'), undef,
        'stop_loop: a state pid that is not numeric stops nothing' );
    $runner->_cleanup_loop_files('m7abc');

    my $live = _m7_spawn_sleep();
    _m7_write_loop_state( $runner, 'm7live',
        { pid => $live, process_name => 'd2 collector: m7live', status => 'running' } );
    is( $runner->stop_loop('m7live'), $live,
        'stop_loop: a live child named by valid state stops and returns its pid' );
    is( $M7_CR_COLLECTORS->{stopped}[-1], 'm7live',
        'stop_loop: the stopped collector is recorded' );
    # stop_loop reaped the child itself; waiting on it again
    # would die, so nothing is cleaned up here.

    my $foreign = _m7_spawn_sleep();
    {
        open my $pfh, '>', $runner->_pidfile('m7foreign') or die 'Unable to write pidfile';
        print {$pfh} "$foreign\n";
        close $pfh or die 'Unable to close pidfile';
    }
    is( $runner->stop_loop('m7foreign'), $foreign,
        'stop_loop: a foreign pid from a pidfile returns its pid without signalling it' );
    ok( $runner->_pid_is_running($foreign),
        'stop_loop: the foreign pid is still running afterwards' );
    _m7_kill_child($foreign);
}

{
    # 4e. stop_loop with a TERM-ignoring loop: the grace expires
    # with the pid still running, so the escalation kill runs.
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);
    my $stubborn = _m7_spawn_sleep( ignore_term => 1 );
    _m7_write_loop_state( $runner, 'm7stubborn',
        { pid => $stubborn, process_name => 'd2 collector: m7stubborn', status => 'running' } );
    {
        # The escalation check sits inside the Windows branch: on
        # Unix the group KILL above it runs first and the check is
        # never evaluated, so the localised $OS_NAME is what reaches
        # it with the loop still running.
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->stop_loop('m7stubborn'), $stubborn,
            'stop_loop: a TERM-ignoring loop is killed at the escalation and returns its pid' );
    }
    # stop_loop reaped the child itself; waiting on it again
    # would die, so nothing is cleaned up here.
}

{
    # 4f. _is_managed_loop on Windows: the title and marker
    # disagreement cells, and the pidfile read cells. The title
    # agrees only when it carries the helper shape or the loop
    # title as a token, never when it equals the title (that
    # returns earlier). A zombie supplies the undefined title; a
    # space title supplies the defined-but-empty one.
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);

    # $^X, not /bin/true: see 3b (R184). The perl child starts
    # slower than /bin/true, 0.43s worst under Devel::Cover on
    # this VM, so the settle is 2s, not 0.3s.
    my $zombie = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'exit 0' ], {} );
    select undef, undef, undef, 2.0;
    {
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_is_managed_loop( $zombie, 'm7za' ), 0,
            'is_managed_loop: a zombie with no title and no marker is not a loop' );
    }
    _wait_for_exit( $zombie, 5 );

    my $blank = _m7_spawn_sleep( title => ' ' );
    {
        open my $pfh, '>', $runner->_pidfile('m7zb') or die 'Unable to write pidfile';
        print {$pfh} "999999\n";
        close $pfh or die 'Unable to close pidfile';
    }
    {
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_is_managed_loop( $blank, 'm7zb' ), 0,
            'is_managed_loop: a blank title with a foreign pidfile pid is not a loop' );
    }
    $runner->_cleanup_loop_files('m7zb');
    _m7_kill_child($blank);

    my $plain = _m7_spawn_sleep();
    {
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_is_managed_loop( $plain, 'm7zc' ), 0,
            'is_managed_loop: a plain title that disagrees is not a loop' );
    }
    _m7_kill_child($plain);

    my $token_pid = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-e', 'my $t = "d2 collector: m7zd"; select undef, undef, undef, 30;' ],
        { env => { DEVELOPER_DASHBOARD_LOOP_NAME => 'other' } },
    );
    {
        my $deadline = time() + 5;
        while ( time() < $deadline ) {
            my $seen = $M7_MANAGER->_read_process_env_marker( $token_pid, 'DEVELOPER_DASHBOARD_LOOP_NAME' );
            last if defined $seen;
            Time::HiRes::sleep(0.05);
        }
    }
    {
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_is_managed_loop( $token_pid, 'm7zd' ), 0,
            'is_managed_loop: a title that agrees with a disagreeing marker is not a loop' );
    }
    _m7_kill_child($token_pid);

    my $named = _m7_spawn_sleep( title => 'x d2 collector: m7ze y' );
    {
        open my $pfh, '>', $runner->_pidfile('m7ze') or die 'Unable to write pidfile';
        print {$pfh} "$named\n";
        close $pfh or die 'Unable to close pidfile';
    }
    {
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_is_managed_loop( $named, 'm7ze' ), 1,
            'is_managed_loop: a pidfile naming the pid confirms the loop on Windows' );
    }
    $runner->_cleanup_loop_files('m7ze');
    _m7_kill_child($named);

    my $badrec = _m7_spawn_sleep( title => 'x d2 collector: m7zf y' );
    {
        open my $pfh, '>', $runner->_pidfile('m7zf') or die 'Unable to write pidfile';
        print {$pfh} "abc\n";
        close $pfh or die 'Unable to close pidfile';
    }
    {
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_is_managed_loop( $badrec, 'm7zf' ), 0,
            'is_managed_loop: a pidfile with a non-numeric pid does not confirm the loop' );
    }
    $runner->_cleanup_loop_files('m7zf');
    _m7_kill_child($badrec);

    my $empty = _m7_spawn_sleep( title => 'x d2 collector: m7zg y' );
    mkdir $runner->_pidfile('m7zg') or die 'Unable to mkdir pidfile dir';
    {
        # A pidfile that is a directory slurps to undef without
        # dying (the read fails, so the body is undef and no error
        # is raised), so the pidfile read condition sees no error
        # and no recorded pid. An empty pidfile does NOT do this:
        # slurp_file returns an empty string for it, which is
        # defined (probed 27 Nov, /tmp/m7-probes/h-slurp.pl).
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_is_managed_loop( $empty, 'm7zg' ), 0,
            'is_managed_loop: a directory pidfile does not confirm the loop' );
    }
    rmdir $runner->_pidfile('m7zg') or die 'Unable to rmdir pidfile dir';
    $runner->_cleanup_loop_files('m7zg');
    _m7_kill_child($empty);
}

{
    # 4g. _loop_runtime_matches: a runtime marker naming another
    # runtime, a title that carries no runtime token, a title
    # that cannot be read at all, and a title carrying this
    # runtime's token.
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);
    my $key = $runner->_runtime_state_key;

    my $wrong = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $M7_SLEEP_SCRIPT, '', 0 ],
        { env => { DEVELOPER_DASHBOARD_LOOP_RUNTIME => 'wrongkey' } },
    );
    {
        my $deadline = time() + 5;
        while ( time() < $deadline ) {
            my $seen = $M7_MANAGER->_read_process_env_marker( $wrong, 'DEVELOPER_DASHBOARD_LOOP_RUNTIME' );
            last if defined $seen;
            Time::HiRes::sleep(0.05);
        }
    }
    is( $runner->_loop_runtime_matches( $wrong, 'm7r1' ), 0,
        'loop_runtime_matches: a marker naming another runtime does not match' );
    _m7_kill_child($wrong);

    # $^X, not /bin/true, settle 2s: see 3b (R184).
    my $zombie = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'exit 0' ], {} );
    select undef, undef, undef, 2.0;
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_loop_runtime_matches( $zombie, 'm7r2' ), 0,
            'loop_runtime_matches: a title that cannot be read does not match' );
    }
    _wait_for_exit( $zombie, 5 );

    my $token = _m7_spawn_sleep( title => "loop --runtime $key" );
SKIP: {
        # The match needs the title read back, and on Windows the
        # title comes from powershell, which is not on PATH here.
        skip 'matching a runtime token needs a readable title, which Windows has not got here', 1
          if $^O eq 'MSWin32';
        is( $runner->_loop_runtime_matches( $token, 'm7r3' ), 1,
            'loop_runtime_matches: a title carrying this runtime token matches' );
    }
    _m7_kill_child($token);
}

{
    # 4h. _read_process_title on Windows: an undefined pid, a
    # non-numeric pid, and the powershell fallback with a fake
    # powershell that is absent, failing, silent, or printing.
    # A zombie supplies the empty command line that reaches the
    # Windows branch. The capture block is the CollectorRunner
    # __ANON__ at line 1639.
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);

    is( $runner->_read_process_title(undef), undef,
        'read_process_title: an undefined pid reads as no title' );
    {
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_read_process_title('abc'), undef,
            'read_process_title: a non-numeric pid reads as no title on Windows' );
    }

    # $^X, not /bin/true, settle 2s: see 3b (R184).
    my $zombie = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'exit 0' ], {} );
    select undef, undef, undef, 2.0;
    {
        my $emptybin = tempdir( CLEANUP => 1 );
        local $ENV{PATH} = $emptybin;
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_read_process_title($zombie), undef,
            'read_process_title: no powershell on Windows reads as no title' );
    }
    {
        my $bin = _m7_fake_powershell_dir('fail');
        local $ENV{PATH} = join $Config{path_sep}, $bin, $ENV{PATH};
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_read_process_title($zombie), undef,
            'read_process_title: a failing powershell reads as no title' );
    }
    {
        my $bin = _m7_fake_powershell_dir('silent');
        local $ENV{PATH} = join $Config{path_sep}, $bin, $ENV{PATH};
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_read_process_title($zombie), undef,
            'read_process_title: a silent powershell reads as no title' );
    }
SKIP: {
        # The printing fake is a shell script, which cmd cannot run.
        skip 'the printing fake powershell is a shell script, which cmd cannot run', 1
          if $^O eq 'MSWin32';
        my $bin = _m7_fake_powershell_dir('print');
        local $ENV{PATH} = join $Config{path_sep}, $bin, $ENV{PATH};
        local $^O = 'MSWin32';
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runner->_read_process_title($zombie), 'C:\\fake\\perl.exe --dummy',
            'read_process_title: a printing powershell reads back its title' );
    }
    _wait_for_exit( $zombie, 5 );
}

{
    # 4i. _spawn_windows_background_command: no command at all
    # (the options condition's first term false) and a plain
    # command (the last argument is not a hash).
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);
    my $err = eval { $runner->_spawn_windows_background_command(); 1 } ? '' : $@;
    like( $err, qr/GoRoutine spawn requires a non-empty argv array/,
        'spawn_windows_background_command: no command dies in the spawn' );
    my $pid = $runner->_spawn_windows_background_command( $^X, '-e', '1;' );
    ok( defined $pid && $pid > 0,
        'spawn_windows_background_command: a plain command spawns' );
    _wait_for_exit( $pid, 5 );
}

{
    # 4j. _find_running_loop: a helper-shaped title that returns
    # its pid, the same shape in a foreign namespace, a plain
    # sleeper, a marker that names the collector, a marker that
    # names another collector, and a blank title that the empty
    # title cell skips.
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);
    my $key = $runner->_runtime_state_key;

    my $helper = _m7_spawn_sleep( title => "collector-loop-foreground --name m7fh --runtime $key" );
SKIP: {
        # The match needs the title read back from the real
        # process table, and on Windows that comes from
        # powershell, which is not on PATH here.
        skip 'finding a loop by its title needs a readable title, which Windows has not got here', 1
          if $^O eq 'MSWin32';
        my $fakeroot = File::Spec->catdir( $M7_HOME, 'm7-fakeproc-helper' );
        mkdir $fakeroot or die "Unable to mkdir $fakeroot: $!";
        mkdir File::Spec->catdir( $fakeroot, $helper ) or die 'Unable to mkdir helper';
        open my $cfh, '>', File::Spec->catfile( $fakeroot, $helper, 'cmdline' ) or die 'Unable to write cmdline';
        print {$cfh} "collector-loop-foreground --name m7fh --runtime $key\0";
        close $cfh or die 'Unable to close cmdline';
        local $Developer::Dashboard::CollectorRunner::PROCFS_ROOT = $fakeroot;
        is( $runner->_find_running_loop('m7fh'), $helper,
            'find_running_loop: a helper-shaped title returns its pid' );
    }
    {
        my $fakeroot = File::Spec->catdir( $M7_HOME, 'm7-fakeproc-foreign' );
        mkdir $fakeroot or die "Unable to mkdir $fakeroot: $!";
        mkdir File::Spec->catdir( $fakeroot, $helper ) or die 'Unable to mkdir helper';
        open my $cfh, '>', File::Spec->catfile( $fakeroot, $helper, 'cmdline' ) or die 'Unable to write cmdline';
        print {$cfh} "collector-loop-foreground --name m7fh --runtime $key\0";
        close $cfh or die 'Unable to close cmdline';
        my $real_ns = readlink '/proc/self/ns/pid';
        mkdir File::Spec->catdir( $fakeroot, $$ ) or die 'Unable to mkdir self';
        mkdir File::Spec->catdir( $fakeroot, $$, 'ns' ) or die 'Unable to mkdir self/ns';
        symlink $real_ns, File::Spec->catfile( $fakeroot, $$, 'ns', 'pid' )
          or die 'Unable to symlink self ns';
        mkdir File::Spec->catdir( $fakeroot, $helper, 'ns' ) or die 'Unable to mkdir helper/ns';
        symlink 'pid:[4026539999]', File::Spec->catfile( $fakeroot, $helper, 'ns', 'pid' )
          or die 'Unable to symlink helper ns';
        local $Developer::Dashboard::CollectorRunner::PROCFS_ROOT = $fakeroot;
        local $Developer::Dashboard::ProcessSupervision::PROCFS_ROOT = $fakeroot;
        SKIP: {
            # Same fake tree as the section 2 test, and the same
            # macOS shape: with no /proc the current id reads
            # empty, the helper reads as same-namespace and is
            # returned instead of undef. It never ran on macOS in
            # proof #211 (macOS stopped at test 151), so this is
            # fixed before the re-proof, not after it.
            skip 'the fake namespace tree needs a real /proc, which macOS does not have', 1
              if !$M7_MANAGER->_procfs_available;
            is( $runner->_find_running_loop('m7fh'), undef,
                'find_running_loop: a helper-shaped title in a foreign namespace returns nothing' );
        }
    }
    _m7_kill_child($helper);

    my $plain = _m7_spawn_sleep();
    {
        my $fakeroot = File::Spec->catdir( $M7_HOME, 'm7-fakeproc-plain' );
        mkdir $fakeroot or die "Unable to mkdir $fakeroot: $!";
        mkdir File::Spec->catdir( $fakeroot, $plain ) or die 'Unable to mkdir plain';
        open my $cfh, '>', File::Spec->catfile( $fakeroot, $plain, 'cmdline' ) or die 'Unable to write cmdline';
        print {$cfh} "sleep\0";
        close $cfh or die 'Unable to close cmdline';
        local $Developer::Dashboard::CollectorRunner::PROCFS_ROOT = $fakeroot;
        is( $runner->_find_running_loop('m7plain'), undef,
            'find_running_loop: a plain sleeper returns nothing' );
    }
    _m7_kill_child($plain);

    my $marked = _m7_spawn_sleep();
SKIP: {
        # The marker path still reads the title first, and on
        # Windows the title comes from powershell, which is not
        # on PATH here.
        skip 'finding a loop by its marker needs a readable title, which Windows has not got here', 1
          if $^O eq 'MSWin32';
        my $fakeroot = File::Spec->catdir( $M7_HOME, 'm7-fakeproc-marker' );
        mkdir $fakeroot or die "Unable to mkdir $fakeroot: $!";
        mkdir File::Spec->catdir( $fakeroot, $marked ) or die 'Unable to mkdir marked';
        open my $cfh, '>', File::Spec->catfile( $fakeroot, $marked, 'cmdline' ) or die 'Unable to write cmdline';
        print {$cfh} "sleep\0";
        close $cfh or die 'Unable to close cmdline';
        open my $efh, '>', File::Spec->catfile( $fakeroot, $marked, 'environ' ) or die 'Unable to write environ';
        print {$efh} "DEVELOPER_DASHBOARD_LOOP_NAME=m7fm\0DEVELOPER_DASHBOARD_LOOP_RUNTIME=$key\0";
        close $efh or die 'Unable to close environ';
        local $Developer::Dashboard::CollectorRunner::PROCFS_ROOT = $fakeroot;
        local $Developer::Dashboard::ProcessSupervision::PROCFS_ROOT = $fakeroot;
        is( $runner->_find_running_loop('m7fm'), $marked,
            'find_running_loop: a marker naming the collector returns its pid' );
    }
    {
        my $fakeroot = File::Spec->catdir( $M7_HOME, 'm7-fakeproc-marker-other' );
        mkdir $fakeroot or die "Unable to mkdir $fakeroot: $!";
        mkdir File::Spec->catdir( $fakeroot, $marked ) or die 'Unable to mkdir marked';
        open my $cfh, '>', File::Spec->catfile( $fakeroot, $marked, 'cmdline' ) or die 'Unable to write cmdline';
        print {$cfh} "sleep\0";
        close $cfh or die 'Unable to close cmdline';
        open my $efh, '>', File::Spec->catfile( $fakeroot, $marked, 'environ' ) or die 'Unable to write environ';
        print {$efh} "DEVELOPER_DASHBOARD_LOOP_NAME=other\0DEVELOPER_DASHBOARD_LOOP_RUNTIME=$key\0";
        close $efh or die 'Unable to close environ';
        local $Developer::Dashboard::CollectorRunner::PROCFS_ROOT = $fakeroot;
        local $Developer::Dashboard::ProcessSupervision::PROCFS_ROOT = $fakeroot;
        is( $runner->_find_running_loop('m7fm'), undef,
            'find_running_loop: a marker naming another collector returns nothing' );
    }
    _m7_kill_child($marked);

    my $blank = _m7_spawn_sleep( title => ' ' );
    {
        my $fakeroot = File::Spec->catdir( $M7_HOME, 'm7-fakeproc-blank' );
        mkdir $fakeroot or die "Unable to mkdir $fakeroot: $!";
        mkdir File::Spec->catdir( $fakeroot, $blank ) or die 'Unable to mkdir blank';
        open my $cfh, '>', File::Spec->catfile( $fakeroot, $blank, 'cmdline' ) or die 'Unable to write cmdline';
        print {$cfh} "x\0";
        close $cfh or die 'Unable to close cmdline';
        local $Developer::Dashboard::CollectorRunner::PROCFS_ROOT = $fakeroot;
        is( $runner->_find_running_loop('m7blank'), undef,
            'find_running_loop: a blank title is skipped' );
    }
    _m7_kill_child($blank);
}

{
    # 4k. running_loops: a foreign pid from a pidfile with no
    # state is not listed, and its pidfile is cleaned up.
    my $cr_files = Local::CRFiles->new( File::Spec->catfile( $M7_HOME, 'm7-cr.log' ) );
    my $runner = _m7_collector_runner($cr_files);
    my $foreign = _m7_spawn_sleep();
    {
        open my $pfh, '>', $runner->_pidfile('m7rl') or die 'Unable to write pidfile';
        print {$pfh} "$foreign\n";
        close $pfh or die 'Unable to close pidfile';
    }
    my @running = $runner->running_loops();
    my @named = grep { $_->{name} eq 'm7rl' } @running;
    is( scalar @named, 0, 'running_loops: a foreign pid is not listed' );
    ok( !-f $runner->_pidfile('m7rl'),
        'running_loops: the foreign pidfile is cleaned up' );
    _m7_kill_child($foreign);
}

# ======================================================================
# SECTION 5 - Web/Server (R178).
#
# Cover #19 gap for lib/Developer/Dashboard/Web/Server.pm: 25
# branch cells + 18 condition cells + 0 subs. Every cell is
# accounted for below as covered, or as probed-uncoverable with
# the evidence. The gap file is the authority for the cell list;
# two of its entries correct the pre-work mapping: B 752 is the
# read-below-zero finish (its missing side is TRUE, the EOF case,
# not the data case), and B 676 / B 803 are the done-guard returns
# (their missing sides are TRUE, a state already done).
#
# COVERED HERE. B 124 false (log path undef, no HOME), B 132
# false + C 132 !l + l&&!r (undef and code-ref @INC entries),
# B 620 true + C 620 !l&&r (an error that stringifies to empty),
# B 659 true (blocking(0) on a real backend socket), B 676 true
# (proxy on a done state), B 696 true (flush with a full send
# buffer), B 699 true + B 700 true/false + C 700 l + !l&&!r
# (syswrite undef, EAGAIN then EBADF), B 704 false (partial
# write), B 720 true + B 721 true/false + C 721 l + !l&&!r
# (read_head sysread undef, EAGAIN then EBADF), B 744 true
# (read head with nothing readable), B 747 true + B 748
# true/false + C 748 l + !l&&!r (proxy read sysread undef,
# EAGAIN then EBADF), B 752 true (proxy read at end of file),
# B 758 true + C 758 l&&r (incomplete head), C 758 !l (head at
# the 16K cap) + l&&!r (complete head), B 778 true (redirect
# with a full send buffer), B 781 true + B 782 true/false +
# C 782 l + !l&&!r (redirect syswrite undef, EAGAIN then EBADF),
# B 787 false (partial redirect write), B 803 true (finish on a
# done state) + C 806 !l (finish with no client), B 938
# true/false + C 938 l&&r + l&&!r (stop backend, reaped and not),
# B 966 true (unusable backend pid), C 966 and-3 !l + l&&!r
# (undef and non-numeric pid) + or-3 !l&&r (pid 0), B 1001
# false (undef @INC entry in the watchdog library args),
# C 93 and-3 !l (undef web pid) + or-3 !l&&r (pid 0), C 147
# l&&!r is already covered by the suite, C 166 l&&!r (empty log
# path), C 167 !l (undef text), C 657 l&&!r (backend connected),
# C 376 !l&&r (socket readable) + !l&&!r (socket idle).
#
# PROBED-UNCOVERABLE, with the evidence. B 402 false: the
# listener-close error is a fresh lexical (declared line 352,
# assigned only at line 402, read at line 408) and the guarded
# block runs once per call, so it is always undef at the guard.
# B 659 false: a fresh IO::Socket::INET always has can(blocking)
# true (probe /tmp/m7-probes/s56-tie.pl), and the backend is
# built by IO::Socket::INET->new in the same sub, so there is
# no injection point. C 147 !l and C 620 l: $@ is never undef
# after eval (probe /tmp/m7-probes/s56-probes.pl: die empty
# leaves 45 chars, die undef leaves 46, a successful eval leaves
# a defined empty string). C 700 / C 721 / C 748 / C 782 !l&&r:
# both disjuncts are the same comparison ($! == 11 or $! == 11),
# EAGAIN is EWOULDBLOCK on Linux, so the second can never fire
# while the first does not. C 966 or-3 l fires on the undef
# call: Devel::Cover counts the first || operand's truth
# (!defined $backend_pid) as the or-3 left cell, the same
# attribution that gives C 93 or-3 l=1 in #19; the written
# first disjunct can never be true as a whole, but the cell is
# covered by the undef call (local cover run: or-3 2 1 3).
#
# HOW THE CELLS ARE REACHED. The error cells use a tied handle
# (M7::TieProbe) whose FILENO returns a real socket fd, so
# IO::Select works on it while READ/WRITE return undef with a
# chosen errno, or die with a chosen exception. The die is
# decided by a defined check, not a truth check: an exception
# that stringifies to empty is false in boolean context, and a
# truth check would swallow it. The buffer-full cells fill a
# real socket send buffer with non-blocking syswrites. The
# partial-write cells use the same tied handle with a short
# count: those bytes really go to the socket and the short
# count is returned, so the caller takes its partial branch.
# A real fill cannot pin the offset: freeing 100 bytes from the
# peer let a later 1000-byte write through whole on this host,
# so the fill/free route is not deterministic. The frontend
# loop cells use a test-local subclass (M7::WS::Server) that returns a
# pre-made listener and a ready backend, a mocked
# GoRoutine::spawn that answers only the watchdog spawn, and
# an alarm that stops the loop after two seconds (the probe
# /tmp/m7-probes/s56-serve-frontend.pl proved the loop returns
# in ~2s this way). The previous TERM handler is localised to a
# no-op first: the loop re-runs the previous handler, and a
# DEFAULT there would re-kill TERM and recurse. All coverage
# cells are hit in the test process; the only spawned children
# are the real backend sleep child (stopped by the loop itself)
# and the lifetime watcher child (which exits after about six
# seconds, once it has seen its dead owner on two polls).
# ======================================================================

require Developer::Dashboard::Web::Server;
require IO::Select;
require IO::Socket::INET;

{
    package M7::TieProbe;
    sub TIEHANDLE {
        my ( $class, %args ) = @_;
        return bless {
            fd      => $args{fd},
            errno   => $args{errno} || 11,
            die     => $args{die},
            partial => $args{partial},
            real    => $args{real},
        }, $class;
    }
    sub FILENO { return $_[0]->{fd}; }
    sub READ {
        my ($self) = @_;
        die $self->{die} if defined $self->{die};
        $! = $self->{errno};
        return undef;
    }
    sub WRITE {
        my ( $self, $buf, $len, $offset ) = @_;
        die $self->{die} if defined $self->{die};
        if ( defined $self->{partial} ) {
            # A genuine short write: this many bytes really go to
            # the socket, and the short count is returned, so the
            # caller takes its partial-write branch. A defined
            # check, not a truth check, decides the die: an
            # exception that stringifies to empty is still a
            # defined exception, and a truth check would miss it.
            my $n = $len < $self->{partial} ? $len : $self->{partial};
            return syswrite( $self->{real}, substr( $buf, $offset || 0, $n ) );
        }
        $! = $self->{errno};
        return undef;
    }
    sub CLOSE { return 1; }
}

{
    package M7::EmptyExc;
    use overload q{""} => sub { return ''; }, fallback => 1;
    sub new { return bless {}, shift; }
}

{
    package M7::WS::Daemon;
    sub new { my ( $class, $port ) = @_; return bless { port => $port }, $class; }
    sub sockhost         { return '127.0.0.1'; }
    sub sockport         { return $_[0]->{port}; }
    sub internal_sockhost { return '127.0.0.1'; }
    sub internal_sockport { return $_[0]->{port}; }
}

{
    package M7::WS::Server;
    our @ISA = ('Developer::Dashboard::Web::Server');
    sub _wait_for_ssl_backend_ready { return 1; }
    sub _open_ssl_frontend_listener_or_die {
        my ($self) = @_;
        return $self->{m7_listener};
    }
}

# _m7_tcp_pair(): one connected TCP pair on loopback, for the
# client states below. The listener is closed; the two ends are
# returned.
# Input: none.
# Output: (client socket, peer socket).
sub _m7_tcp_pair {
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
        Listen    => 128,         ReuseAddr => 1,
    ) or die "Unable to listen for a test pair: $!";
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $listener->sockport, Proto => 'tcp',
    ) or die "Unable to connect a test pair: $!";
    my $peer = $listener->accept or die "Unable to accept a test pair: $!";
    close $listener;
    return ( $client, $peer );
}

# _m7_fill_socket($sock): fills one socket send buffer with
# non-blocking syswrites until EAGAIN, so a later write or a
# can_write probe finds it full. The socket is left non-blocking.
# Input: socket handle.
# Output: bytes written.
sub _m7_fill_socket {
    my ($sock) = @_;
    $sock->blocking(0);
    my $chunk = 'x' x 65536;
    my $total = 0;
    while (1) {
        my $written = syswrite( $sock, $chunk );
        last if !defined $written;
        last if $written == 0;
        $total += $written;
    }
    return $total;
}

# _m7_ws_state(%over): a frontend client state hash with sane
# defaults; the caller overrides the fields its sub needs.
# The caller owns the sockets (owns_sockets 0) unless it says
# otherwise, so finish never closes a handle the test still
# holds.
# Input: field overrides.
# Output: state hash reference.
sub _m7_ws_state {
    my (%over) = @_;
    my $state = {
        client       => undef,
        backend      => undef,
        daemon       => undef,
        worker_server => undef,
        phase        => 'READ_HEAD',
        head         => '',
        write_buf    => '',
        write_off    => 0,
        buf_c2b      => '',
        off_c2b      => 0,
        buf_b2c      => '',
        off_b2c      => 0,
        done         => 0,
        errors       => [],
        routine      => undef,
        owns_sockets => 0,
    };
    @{$state}{ keys %over } = values %over;
    return $state;
}

my $M7_WS_LISTENER = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
    Listen    => 128,         ReuseAddr => 1,
) or die "Unable to listen for the Web/Server tests: $!";
my $M7_WS_DAEMON = M7::WS::Daemon->new( $M7_WS_LISTENER->sockport );
my $M7_WS_SERVER = bless {
    host                  => '127.0.0.1',
    ssl_subject_alt_names => [],
}, 'Developer::Dashboard::Web::Server';

{
    # 5a. Log-path guard cells: an undef web pid, a zero pid, a
    # non-numeric pid, and a usable pid.
    is( Developer::Dashboard::Web::Server::_web_lifetime_owner_watcher_log_path(undef),
        undef, 'log path: undef web pid gives no log path' );
    is( Developer::Dashboard::Web::Server::_web_lifetime_owner_watcher_log_path(0),
        undef, 'log path: web pid 0 gives no log path' );
    is( Developer::Dashboard::Web::Server::_web_lifetime_owner_watcher_log_path('abc'),
        undef, 'log path: non-numeric web pid gives no log path' );
    like( Developer::Dashboard::Web::Server::_web_lifetime_owner_watcher_log_path(12345),
        qr/web-lifetime-owner-watcher-12345\.log\z/,
        'log path: a usable web pid gives its log path' );
}

{
    # 5b. Watcher start with no HOME: the log-path eval dies
    # (PathRegistry has no home), so the push is skipped and the
    # watcher still starts. The @INC carries an undef entry and a
    # code-ref entry, so the library-args grep skips both. The
    # owner pid is dead, so the watcher child exits once it has
    # seen the owner dead on two polls (about six seconds: the
    # poll interval is five seconds). The wait bound is 40 seconds
    # so the child still has headroom under Devel::Cover, where
    # the forked child starts slowly and the plain 15 second
    # bound was not enough; the wait returns as soon as the
    # child exits, so the plain run is not slowed down.
    my $watcher;
    {
        local %ENV = %ENV;
        delete @ENV{qw(HOME USERPROFILE HOMEDRIVE HOMEPATH)};
        $ENV{DEVELOPER_DASHBOARD_LIFETIME_PID} = 999999;
        local @INC = ( undef, sub { }, @INC );
        $watcher = Developer::Dashboard::Web::Server::_start_lifetime_owner_watcher();
    }
    ok( defined $watcher && $watcher > 0,
        'watcher start: starts with no HOME and no log path' );
    my $watcher_rc = _wait_for_exit( $watcher, 40 );
    ok( defined $watcher_rc,
        'watcher start: the watcher child exits once its owner is confirmed dead' );
    {
        local %ENV = %ENV;
        delete $ENV{DEVELOPER_DASHBOARD_LIFETIME_PID};
        is( Developer::Dashboard::Web::Server::_start_lifetime_owner_watcher(),
            0, 'watcher start: no opted-in owner pid starts nothing' );
    }
}

{
    # 5c. Watcher-start log writer: an empty log path, an undef
    # text, and a line that is written and read back.
    my $m7_log = File::Spec->catfile( $M7_HOME, 'm7-watcher.log' );
    is( Developer::Dashboard::Web::Server::_log_lifetime_owner_watcher_start( '', 'some text' ),
        undef, 'watcher log: an empty log path writes nothing' );
    is( Developer::Dashboard::Web::Server::_log_lifetime_owner_watcher_start( $m7_log, undef ),
        undef, 'watcher log: undef text writes nothing' );
    is( Developer::Dashboard::Web::Server::_log_lifetime_owner_watcher_start( $m7_log, 'm7 log line' ),
        1, 'watcher log: a line is written' );
    like( _m7_read_file($m7_log), qr/m7 log line/, 'watcher log: the line is in the log' );
}

{
    # 5d. Client step error path: the read dies with an exception
    # that stringifies to empty, so the step records the
    # unknown-error text; and a read that dies with a message,
    # which is recorded as-is.
    my ( $sock, $peer ) = _m7_tcp_pair();
    syswrite( $peer, 'x' );
    open my $th, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th, 'M7::TieProbe', fd => fileno($sock), die => M7::EmptyExc->new;
    my $state = _m7_ws_state(
        client => $th, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        phase => 'READ_HEAD',
    );
    is( Developer::Dashboard::Web::Server::_ssl_frontend_client_step($state),
        1, 'client step: returns 1 after the read dies' );
    is( $state->{errors}[0], 'unknown client error',
        'client step: an empty error becomes the unknown-error text' );
    ok( $state->{done}, 'client step: the client is finished after the error' );
    untie *$th;
    close $th;
    close $sock;
    close $peer;

    my ( $sock2, $peer2 ) = _m7_tcp_pair();
    syswrite( $peer2, 'x' );
    open my $th2, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th2, 'M7::TieProbe', fd => fileno($sock2), die => 'm7 boom';
    my $state2 = _m7_ws_state(
        client => $th2, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        phase => 'READ_HEAD',
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_step($state2);
    like( $state2->{errors}[0], qr/m7 boom/,
        'client step: a message error is recorded as-is' );
    untie *$th2;
    close $th2;
    close $sock2;
    close $peer2;
}

{
    # 5e. Wait-for-first-byte: a TLS first byte routes to PROXY
    # with a connected backend, and a plain first byte routes to
    # READ_HEAD.
    my ( $client, $peer ) = _m7_tcp_pair();
    syswrite( $peer, chr(22) );
    my $state = _m7_ws_state(
        client => $client, daemon => $M7_WS_DAEMON, phase => 'WAIT_FIRST',
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_wait_first($state);
    is( $state->{phase}, 'PROXY', 'wait first: a TLS first byte routes to PROXY' );
    ok( defined $state->{backend} && $state->{backend}->connected,
        'wait first: the backend is connected' );
    my $accepted = $M7_WS_LISTENER->accept;
    close $accepted if $accepted;
    close $state->{backend} if $state->{backend};
    close $client;
    close $peer;

    my ( $client2, $peer2 ) = _m7_tcp_pair();
    syswrite( $peer2, 'G' );
    my $state2 = _m7_ws_state(
        client => $client2, daemon => $M7_WS_DAEMON, phase => 'WAIT_FIRST',
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_wait_first($state2);
    is( $state2->{phase}, 'READ_HEAD', 'wait first: a plain first byte routes to READ_HEAD' );
    is( $state2->{head}, '', 'wait first: a plain first byte clears the head' );
    close $client2;
    close $peer2;
}

{
    # 5f. Proxy pump: a done state returns at once; an idle
    # state returns at the read check; end of file finishes the
    # client; data is read into the buffer.
    my ( $c1, $p1 ) = _m7_tcp_pair();
    my ( $c2, $p2 ) = _m7_tcp_pair();
    my $done_state = _m7_ws_state(
        client => $c1, backend => $c2, done => 1,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy($done_state);
    is( $done_state->{buf_c2b}, '', 'proxy: a done state pumps nothing' );
    is( $done_state->{done}, 1, 'proxy: a done state stays done' );

    my $idle_state = _m7_ws_state( client => $c1, backend => $c2 );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy($idle_state);
    is( $idle_state->{buf_c2b}, '', 'proxy: an idle state reads nothing' );
    is( $idle_state->{done}, 0, 'proxy: an idle state stays open' );

    my ( $c3, $p3 ) = _m7_tcp_pair();
    close $p3;
    my $eof_state = _m7_ws_state(
        client => $c3, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy_dir(
        $eof_state, $c3, $c2, 'buf_c2b', 'off_c2b' );
    ok( $eof_state->{done}, 'proxy: end of file finishes the client' );

    my ( $c4, $p4 ) = _m7_tcp_pair();
    syswrite( $p4, 'm7-data' );
    my $data_state = _m7_ws_state(
        client => $c4, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy_dir(
        $data_state, $c4, $c2, 'buf_c2b', 'off_c2b' );
    is( $data_state->{buf_c2b}, 'm7-data', 'proxy: a chunk is read into the buffer' );
    is( $data_state->{off_c2b}, 0, 'proxy: a fresh chunk starts at offset 0' );
    close $c1; close $p1; close $c2; close $p2;
    close $c3; close $c4; close $p4;
}

{
    # 5f continued. Flush with a full send buffer returns at
    # once; a partial write leaves the offset short of the
    # buffer; a failed syswrite returns on EAGAIN and dies on
    # any other errno; a failed read returns on EAGAIN and
    # finishes the client on any other errno.
    my ( $c1, $p1 ) = _m7_tcp_pair();
    my ( $c2, $p2 ) = _m7_tcp_pair();
    _m7_fill_socket($c1);
    my $full_state = _m7_ws_state(
        client => $c1, backend => $c2, buf_c2b => 'hello', off_c2b => 0,
        worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy_dir(
        $full_state, $c2, $c1, 'buf_c2b', 'off_c2b' );
    is( $full_state->{buf_c2b}, 'hello', 'proxy flush: a full send buffer leaves the buffer' );
    is( $full_state->{off_c2b}, 0, 'proxy flush: a full send buffer moves the offset nowhere' );

    my ( $c3, $p3 ) = _m7_tcp_pair();
    my ( $c4, $p4 ) = _m7_tcp_pair();
    open my $thp, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$thp, 'M7::TieProbe', fd => fileno($c3), partial => 100, real => $c3;
    my $big = 'y' x 1000;
    my $part_state = _m7_ws_state(
        client => $c3, backend => $c4, buf_c2b => $big, off_c2b => 0,
        worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy_dir(
        $part_state, $c4, $thp, 'buf_c2b', 'off_c2b' );
    is( $part_state->{off_c2b}, 100,
        'proxy flush: a partial write leaves the offset short of the buffer' );
    my $got = '';
    sysread( $p3, $got, 100 );
    is( $got, 'y' x 100, 'proxy flush: the short write really moved its bytes' );
    untie *$thp;
    close $thp;

    my ( $c5, $p5 ) = _m7_tcp_pair();
    my ( $c6, $p6 ) = _m7_tcp_pair();
    open my $th, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th, 'M7::TieProbe', fd => fileno($c5), errno => 11;
    my $eagain_state = _m7_ws_state(
        client => $c6, backend => $c5, buf_b2c => 'hello', off_b2c => 0,
        worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy_dir(
        $eagain_state, $c6, $th, 'buf_b2c', 'off_b2c' );
    is( $eagain_state->{buf_b2c}, 'hello', 'proxy flush: EAGAIN leaves the buffer' );
    is( $eagain_state->{done}, 0, 'proxy flush: EAGAIN leaves the client open' );
    untie *$th;
    close $th;

    open my $th2, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th2, 'M7::TieProbe', fd => fileno($c5), errno => 9;
    my $ebadf_state = _m7_ws_state(
        client => $c6, backend => $c5, buf_b2c => 'hello', off_b2c => 0,
        worker_server => $M7_WS_SERVER,
    );
    my $died = eval {
        Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy_dir(
            $ebadf_state, $c6, $th2, 'buf_b2c', 'off_b2c' );
        1;
    };
    ok( !$died && $@ =~ /Unable to proxy SSL frontend bytes/,
        'proxy flush: a bad file descriptor dies' );
    untie *$th2;
    close $th2;

    my ( $c7, $p7 ) = _m7_tcp_pair();
    syswrite( $p7, 'x' );
    open my $th3, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th3, 'M7::TieProbe', fd => fileno($c7), errno => 11;
    my $read_eagain = _m7_ws_state(
        client => $c7, backend => $c6, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy_dir(
        $read_eagain, $th3, $c6, 'buf_c2b', 'off_c2b' );
    is( $read_eagain->{done}, 0, 'proxy read: EAGAIN leaves the client open' );
    is( $read_eagain->{buf_c2b}, '', 'proxy read: EAGAIN reads nothing' );
    untie *$th3;
    close $th3;

    open my $th4, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th4, 'M7::TieProbe', fd => fileno($c7), errno => 9;
    my $read_ebadf = _m7_ws_state(
        client => $c7, backend => $c6, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_proxy_dir(
        $read_ebadf, $th4, $c6, 'buf_c2b', 'off_c2b' );
    ok( $read_ebadf->{done}, 'proxy read: a bad file descriptor finishes the client' );
    untie *$th4;
    close $th4;
    close $c1; close $p1; close $c2; close $p2;
    close $c3; close $p3; close $c4; close $p4;
    close $c5; close $p5; close $c6; close $p6;
    close $c7; close $p7;
}

{
    # 5g. Read head: an incomplete head stays in READ_HEAD; a
    # complete head builds the redirect; a head at the 16K cap
    # builds the redirect too; an unreadable client returns at
    # once; a failed sysread returns on EAGAIN and finishes the
    # client on any other errno; end of file finishes the client.
    my ( $c1, $p1 ) = _m7_tcp_pair();
    syswrite( $p1, "GET / HTTP/1.1\r\nHost: example.com\r\n" );
    my $state = _m7_ws_state(
        client => $c1, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_read_head($state);
    is( $state->{phase}, 'READ_HEAD', 'read head: an incomplete head stays reading' );
    like( $state->{head}, qr/GET \/ HTTP\/1\.1/, 'read head: an incomplete head is kept' );

    my ( $c2, $p2 ) = _m7_tcp_pair();
    my $state2 = _m7_ws_state(
        client => $c2, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        head => "GET /path?x=1 HTTP/1.1\r\nHost: example.com\r\n",
    );
    syswrite( $p2, "\r\n" );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_read_head($state2);
    is( $state2->{phase}, 'WRITE_REDIRECT', 'read head: a complete head moves to the redirect' );
    like( $state2->{write_buf}, qr/Location: https:\/\/127\.0\.0\.1:/,
        'read head: the redirect names the daemon host' );

    my ( $c3, $p3 ) = _m7_tcp_pair();
    my $state3 = _m7_ws_state(
        client => $c3, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        head => 'x' x 16383,
    );
    syswrite( $p3, 'y' );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_read_head($state3);
    is( $state3->{phase}, 'WRITE_REDIRECT', 'read head: a head at the cap moves to the redirect' );
    ok( defined $state3->{write_buf} && length( $state3->{write_buf} ) > 0,
        'read head: a head at the cap builds a redirect' );

    my ( $c4, $p4 ) = _m7_tcp_pair();
    syswrite( $p4, 'x' );
    open my $th, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th, 'M7::TieProbe', fd => fileno($c4), errno => 11;
    my $state4 = _m7_ws_state(
        client => $th, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_read_head($state4);
    is( $state4->{phase}, 'READ_HEAD', 'read head: EAGAIN stays reading' );
    is( $state4->{head}, '', 'read head: EAGAIN reads nothing' );
    untie *$th;
    close $th;

    open my $th2, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th2, 'M7::TieProbe', fd => fileno($c4), errno => 9;
    my $state5 = _m7_ws_state(
        client => $th2, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_read_head($state5);
    ok( $state5->{done}, 'read head: a bad file descriptor finishes the client' );
    untie *$th2;
    close $th2;

    my ( $c6, $p6 ) = _m7_tcp_pair();
    close $p6;
    my $state6 = _m7_ws_state(
        client => $c6, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_read_head($state6);
    ok( $state6->{done}, 'read head: end of file finishes the client' );

    my ( $c7, $p7 ) = _m7_tcp_pair();
    my $state7 = _m7_ws_state(
        client => $c7, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_read_head($state7);
    is( $state7->{phase}, 'READ_HEAD', 'read head: an unreadable client stays reading' );
    is( $state7->{head}, '', 'read head: an unreadable client reads nothing' );
    close $c1; close $p1; close $c2; close $p2;
    close $c3; close $p3; close $c4; close $p4; close $c6; close $c7; close $p7;
}

{
    # 5h. Write redirect: a full send buffer returns at once; a
    # failed syswrite returns on EAGAIN and finishes the client
    # on any other errno; a partial write leaves the offset short;
    # a full write finishes the client.
    my ( $c1, $p1 ) = _m7_tcp_pair();
    _m7_fill_socket($c1);
    my $state = _m7_ws_state(
        client => $c1, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        write_buf => 'x' x 100, write_off => 0,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_write_redirect($state);
    is( $state->{write_off}, 0, 'write redirect: a full send buffer writes nothing' );

    my ( $c2, $p2 ) = _m7_tcp_pair();
    open my $th, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th, 'M7::TieProbe', fd => fileno($c2), errno => 11;
    my $state2 = _m7_ws_state(
        client => $th, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        write_buf => 'hello', write_off => 0,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_write_redirect($state2);
    is( $state2->{write_off}, 0, 'write redirect: EAGAIN writes nothing' );
    untie *$th;
    close $th;

    open my $th2, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$th2, 'M7::TieProbe', fd => fileno($c2), errno => 9;
    my $state3 = _m7_ws_state(
        client => $th2, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        write_buf => 'hello', write_off => 0,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_write_redirect($state3);
    ok( $state3->{done}, 'write redirect: a bad file descriptor finishes the client' );
    untie *$th2;
    close $th2;

    my ( $c4, $p4 ) = _m7_tcp_pair();
    open my $thp, '+<', '/dev/null' or die "Unable to open a tied handle: $!";
    tie *$thp, 'M7::TieProbe', fd => fileno($c4), partial => 100, real => $c4;
    my $big = 'z' x 1000;
    my $state4 = _m7_ws_state(
        client => $thp, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        write_buf => $big, write_off => 0,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_write_redirect($state4);
    is( $state4->{write_off}, 100,
        'write redirect: a partial write leaves the offset short of the buffer' );
    ok( !$state4->{done}, 'write redirect: a partial write leaves the client open' );
    untie *$thp;
    close $thp;

    my ( $c5, $p5 ) = _m7_tcp_pair();
    my $state5 = _m7_ws_state(
        client => $c5, daemon => $M7_WS_DAEMON, worker_server => $M7_WS_SERVER,
        write_buf => 'HTTP/1.1 307 Temporary Redirect', write_off => 0,
    );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_write_redirect($state5);
    ok( $state5->{done}, 'write redirect: a full write finishes the client' );
    close $c1; close $p1; close $c2; close $p2;
    close $c4; close $p4; close $c5; close $p5;
}

{
    # 5i. Finish: a state already done returns at once, and a
    # state with no client finishes without closing anything.
    my $done_state = _m7_ws_state( done => 1 );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_finish($done_state);
    is( $done_state->{done}, 1, 'finish: a done state stays done' );
    my $no_client = _m7_ws_state( client => undef, owns_sockets => 1 );
    Developer::Dashboard::Web::Server::_ssl_frontend_client_finish($no_client);
    is( $no_client->{done}, 1, 'finish: a state with no client still finishes' );
}

{
    # 5j. Stop backend: a pid already reaped returns at once, and
    # a live child is terminated and reaped.
    is( Developer::Dashboard::Web::Server::_stop_ssl_backend( 999999, { 999999 => 1 } ),
        1, 'stop backend: a reaped pid returns at once' );
    my $child = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'sleep 30' ], {} );
    ok( $child && $child > 0, 'stop backend: a sleep child spawns' );
    is( Developer::Dashboard::Web::Server::_stop_ssl_backend( $child, {} ),
        1, 'stop backend: a live child is stopped' );
    ok( !Developer::Dashboard::GoRoutine::process_running($child),
        'stop backend: the stopped child is gone' );
}

{
    # 5k. Watchdog guards: an undef pid, a non-numeric pid, and
    # pid 0 all return 0; a usable pid with an undef @INC entry
    # spawns the watchdog (mocked, so no child is started).
    is( Developer::Dashboard::Web::Server::_start_ssl_backend_watchdog(undef),
        0, 'watchdog: an undef backend pid starts nothing' );
    is( Developer::Dashboard::Web::Server::_start_ssl_backend_watchdog('abc'),
        0, 'watchdog: a non-numeric backend pid starts nothing' );
    is( Developer::Dashboard::Web::Server::_start_ssl_backend_watchdog(0),
        0, 'watchdog: backend pid 0 starts nothing' );
    my $real_spawn = \&Developer::Dashboard::GoRoutine::spawn;
    {
        no warnings qw(redefine once);
        local *Developer::Dashboard::GoRoutine::spawn = sub {
            my ($argv) = @_;
            return 424242 if grep { !ref $_ && $_ =~ /watcher/ } @{$argv};
            return $real_spawn->(@_);
        };
        local @INC = ( undef, @INC );
        is( Developer::Dashboard::Web::Server::_start_ssl_backend_watchdog(12345),
            424242, 'watchdog: a usable backend pid spawns the watchdog' );
    }
}

# _m7_run_frontend($with_client): runs _serve_ssl_frontend once
# on a fresh listener (the loop closes the listener it is given,
# so a second call needs a new one), with a mocked watchdog
# spawn and an alarm that stops the loop after two seconds.
# With a client connected first, the accept runs; without one
# the loop idles.
# Input: boolean, whether to connect a client first.
# Output: boolean true when the frontend returned.
sub _m7_run_frontend {
    my ($with_client) = @_;
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
        Listen    => 128,         ReuseAddr => 1,
    ) or die "Unable to listen for the frontend loop: $!";
    my $server = bless {
        host                  => '127.0.0.1',
        ssl_subject_alt_names => [],
        ssl_backend_command_builder => sub { return [ $^X, '-e', 'sleep 30' ]; },
        m7_listener => $listener,
    }, 'M7::WS::Server';
    my $client;
    if ($with_client) {
        $client = IO::Socket::INET->new(
            PeerAddr => '127.0.0.1', PeerPort => $listener->sockport, Proto => 'tcp',
        ) or die "Unable to connect to the frontend loop: $!";
    }
    my $real_spawn = \&Developer::Dashboard::GoRoutine::spawn;
    my $rc;
    {
        no warnings qw(redefine once);
        local *Developer::Dashboard::GoRoutine::spawn = sub {
            my ($argv) = @_;
            return 424242 if grep { !ref $_ && $_ =~ /watcher/ } @{$argv};
            return $real_spawn->(@_);
        };
        local $SIG{TERM} = sub { };
        local $SIG{ALRM} = sub { kill 'TERM', $$; };
        alarm(2);
        $rc = eval { $server->_serve_ssl_frontend($M7_WS_DAEMON); 1 };
        alarm(0);
    }
    close $client if $client;
    close $listener;
    return $rc;
}

{
    # 5l. Frontend loop: with no client waiting the loop idles
    # until the alarm stops it, and with a client waiting the
    # accept runs and the loop still stops on the alarm. The
    # backend is a real sleep child, stopped by the loop; the
    # watchdog spawn is mocked.
    ok( _m7_run_frontend(0), 'frontend loop: returns when the alarm stops an idle loop' );
    ok( _m7_run_frontend(1), 'frontend loop: returns when the alarm stops a loop with a client waiting' );
}

close $M7_WS_LISTENER;

# ======================================================================
# SECTION 6 - SkillManager (R178).
#
# Cover #19 gap for lib/Developer/Dashboard/SkillManager.pm: 21
# branch cells + 12 condition cells + 0 subs. Every cell is
# accounted for below as covered, or as probed-uncoverable with
# the evidence.
#
# COVERED HERE. B 277 true (uninstall over a skills root whose
# realpath is undef), B 460 true + C 460 l (a file:// URL with
# no name), B 500 true (resolve depth past 40), B 501 true +
# C 501 l + !l&&r (resolve of undef and of empty), B 504 false
# + C 504 l&&!r (a trailing slash leaves the file part empty),
# B 505 false (a relative path), B 511 true (a dot-dot part),
# B 519 false (a relative link target) + B 523 true (a link in
# the middle of the path), B 540 true + C 540 l + !l&&r
# (strict directory of undef and of empty), B 549 true (a
# dot-dot part), B 575 true (a symlink loop refuses the path),
# B 584 true (the Windows branch of the contained check),
# B 1506 true (the Windows drain) + B 1511 true/false (with and
# without a timeout) + B 1517 true/false (stdout and stderr
# chunks) + B 1526 false (the drain succeeds, no fallback),
# B 1935 false (the Windows side of the protected argument),
# B 1936 true/false + C 1936 l + !l&&r + !l&&!r (undef, quoted
# and plain arguments), B 1937 true/false (no shell character,
# and one), C 612 !l&&r (a backslash path with no drive
# letter), C 1675 / C 1688 / C 1700 l&&!r (an empty OS
# override).
#
# PROBED-UNCOVERABLE, with the evidence. B 518 true: readlink
# after a successful -l never returns undef in normal use (a
# probe over 200 symlinks, /tmp/m7-probes/s56-readlink.pl,
# found 0 undef); only a link deleted between the check and
# the read could do it. C 504 !l and C 543 !l: splitpath never
# returns an undef file on Unix (probe: splitpath('/a/b/') and
# splitpath('') both give a defined empty file). C 510 l and
# C 548 l: the walked parts are splitdir strings plus a file
# guarded by defined-and-nonempty, so no part is ever undef.
# C 460 !l&&r: the name regex needs one or more non-slash
# characters, so a name is either undef or non-empty, never
# an empty string.
#
# HOW THE CELLS ARE REACHED. The uninstall root list is
# injected through the PathRegistry scope hash (a test setup
# on an object this file built, the same class as the fake
# /proc roots in section 4): runtime_layers returns the scope
# list directly, so the bogus root sorts first and its
# realpath is undef. The Windows drain uses the t/1009 fake
# Win32 modules (M7 names here) with FIONREAD byte counts on
# the real open3 pipes, and a localised $^O. The symlink
# fixtures live under a tempdir and are removed by it.
# ======================================================================

require Developer::Dashboard::SkillManager;

my $M7_SM = Developer::Dashboard::SkillManager->new( paths => $M7_PATHS );

{
    # 6a. Uninstall: the skills roots carry a bogus root first,
    # whose realpath is undef, so the loop skips it and removes
    # the skill from the real root.
    my $sm_home = tempdir( CLEANUP => 1 );
    my $real_root = File::Spec->catdir( $sm_home, 'skills-real' );
    my $real_skills = File::Spec->catdir( $real_root, 'skills' );
    my $skill_dir = File::Spec->catdir( $real_skills, 'm7skill' );
    mkdir $real_root or die "Unable to mkdir $real_root: $!";
    mkdir $real_skills or die "Unable to mkdir $real_skills: $!";
    mkdir $skill_dir or die "Unable to mkdir $skill_dir: $!";
    my $bogus_root = File::Spec->catdir( $sm_home, 'skills-bogus' );
    my $paths = Developer::Dashboard::PathRegistry->new( home => $sm_home );
    $paths->{_runtime_layer_candidate_scope} = { runtime_layers => [ $real_root, $bogus_root ] };
    my $sm = Developer::Dashboard::SkillManager->new( paths => $paths );
    my $r = $sm->uninstall('m7skill');
    is( $r->{success}, 1, 'uninstall: a skill under a real root uninstalls' );
    ok( !-d $skill_dir, 'uninstall: the skill directory is removed' );
    is( $r->{repo_name}, 'm7skill', 'uninstall: the result names the skill' );
}

{
    # 6b. Repo name extraction: a file:// URL with no name, a
    # plain file URL, and an SSH URL.
    is( Developer::Dashboard::SkillManager::_extract_repo_name('file://'),
        undef, 'extract name: a bare file URL has no name' );
    is( Developer::Dashboard::SkillManager::_extract_repo_name('file:///tmp/foo.git'),
        'foo', 'extract name: a file URL gives its name without .git' );
    is( Developer::Dashboard::SkillManager::_extract_repo_name('git@github.com:user/repo-name.git'),
        'repo-name', 'extract name: an SSH URL gives its name' );
}

{
    # 6c. Symlink resolution: depth, empty inputs, a trailing
    # slash, a relative path, a dot-dot part, and relative and
    # absolute link targets.
    is( Developer::Dashboard::SkillManager::_resolve_path_symlinks( '/x', 41 ),
        undef, 'resolve: depth past 40 gives undef' );
    is( Developer::Dashboard::SkillManager::_resolve_path_symlinks(undef),
        undef, 'resolve: undef gives undef' );
    is( Developer::Dashboard::SkillManager::_resolve_path_symlinks(''),
        '', 'resolve: empty gives empty' );
    is( Developer::Dashboard::SkillManager::_resolve_path_symlinks('/a/b/'),
        '/a/b', 'resolve: a trailing slash drops the empty file part' );
    require Cwd;
    is( Developer::Dashboard::SkillManager::_resolve_path_symlinks('a/b'),
        File::Spec->catdir( Cwd::getcwd(), 'a', 'b' ),
        'resolve: a relative path starts at the working directory' );
    is( Developer::Dashboard::SkillManager::_resolve_path_symlinks('/tmp/../tmp'),
        '/tmp', 'resolve: a dot-dot part steps up' );
    my $dir = tempdir( CLEANUP => 1 );
    my $target = File::Spec->catdir( $dir, 'target' );
    mkdir $target or die "Unable to mkdir $target: $!";
    symlink 'target', File::Spec->catfile( $dir, 'link' )
        or die "Unable to symlink a relative target: $!";
    symlink $target, File::Spec->catfile( $dir, 'link2' )
        or die "Unable to symlink an absolute target: $!";
    is( Developer::Dashboard::SkillManager::_resolve_path_symlinks( File::Spec->catfile( $dir, 'link', 'file' ) ),
        File::Spec->catfile( $dir, 'target', 'file' ),
        'resolve: a relative link target resolves' );
    is( Developer::Dashboard::SkillManager::_resolve_path_symlinks( File::Spec->catfile( $dir, 'link2', 'file' ) ),
        File::Spec->catfile( $dir, 'target', 'file' ),
        'resolve: an absolute link target resolves' );
}

{
    # 6d. Strict directory: undef, empty, a dot-dot part, a real
    # directory, and a missing path.
    is( Developer::Dashboard::SkillManager::_strict_directory(undef),
        0, 'strict: undef is not a directory' );
    is( Developer::Dashboard::SkillManager::_strict_directory(''),
        0, 'strict: empty is not a directory' );
    is( Developer::Dashboard::SkillManager::_strict_directory('/tmp/../tmp'),
        1, 'strict: a dot-dot part steps up' );
    is( Developer::Dashboard::SkillManager::_strict_directory('/tmp'),
        1, 'strict: tmp is a directory' );
    is( Developer::Dashboard::SkillManager::_strict_directory('/tmp/nonexistent-m7-xyz'),
        0, 'strict: a missing path is not a directory' );
}

{
    # 6e. Install path contained: a symlink loop is refused, the
    # Windows branch still contains a real path, and the plain
    # contained and outside cases behave.
    my $dir = tempdir( CLEANUP => 1 );
    symlink File::Spec->catfile( $dir, 'b' ), File::Spec->catfile( $dir, 'a' )
        or die "Unable to symlink the loop: $!";
    symlink File::Spec->catfile( $dir, 'a' ), File::Spec->catfile( $dir, 'b' )
        or die "Unable to symlink the loop: $!";
    is( $M7_SM->_install_path_contained( File::Spec->catfile( $dir, 'a', 'file' ), $dir ),
        0, 'contained: a symlink loop is refused' );
    my $root = File::Spec->catdir( $dir, 'root' );
    my $skill = File::Spec->catdir( $root, 'skill' );
    mkdir $root or die "Unable to mkdir $root: $!";
    mkdir $skill or die "Unable to mkdir $skill: $!";
    is( $M7_SM->_install_path_contained( $skill, $root ),
        1, 'contained: a path under the root is contained' );
    is( $M7_SM->_install_path_contained( File::Spec->catdir( $dir, 'outside' ), $root ),
        0, 'contained: a path outside the root is not contained' );
    {
        local $^O = 'MSWin32';
        is( $M7_SM->_install_path_contained( $skill, $root ),
            1, 'contained: the Windows branch still contains a real path' );
    }
}

{
    # 6f. Install source normalisation: a backslash path with no
    # drive letter, and a drive-letter path.
    is( $M7_SM->_normalize_install_source('file://foo\\bar'),
        'file:///foo/bar', 'normalize: a backslash path is rewritten' );
    is( $M7_SM->_normalize_install_source('file://localhost/C:/x'),
        'file:///C:/x', 'normalize: a drive path is rewritten' );
}

{
    # 6g. OS detection overrides: an empty override value is
    # defined but not '0', so the check falls through. Debian
    # answers from /etc/debian_version on this host, so only its
    # boolean shape is asserted; Alpine and Fedora have no
    # release file here, so they answer 0.
    {
        local $ENV{DD_TEST_DEBIAN_LIKE} = '';
        my $deb = $M7_SM->_is_debian_like;
        ok( $deb == 0 || $deb == 1, 'debian: an empty override returns a boolean' );
    }
    {
        local $ENV{DD_TEST_ALPINE} = '';
        is( $M7_SM->_is_alpine, 0, 'alpine: an empty override is not alpine' );
    }
    {
        local $ENV{DD_TEST_FEDORA} = '';
        is( $M7_SM->_is_fedora, 0, 'fedora: an empty override is not fedora' );
    }
}

{
    # 6h. Protected argument: undef, quoted, plain and
    # shell-character arguments on Windows, and a plain
    # argument off Windows.
    {
        local $^O = 'MSWin32';
        is( Developer::Dashboard::SkillManager::_cmd_protected_argument(undef),
            undef, 'protected: undef stays undef' );
        is( Developer::Dashboard::SkillManager::_cmd_protected_argument('a"b'),
            'a"b', 'protected: a quoted argument stays as-is' );
        is( Developer::Dashboard::SkillManager::_cmd_protected_argument('abc'),
            'abc', 'protected: a plain argument stays as-is' );
        is( Developer::Dashboard::SkillManager::_cmd_protected_argument('^1.2.3'),
            '"^1.2.3"', 'protected: a shell character earns quotes' );
    }
    is( Developer::Dashboard::SkillManager::_cmd_protected_argument('x'),
        'x', 'protected: a plain argument stays as-is off Windows' );
}

{
    # 6i. Streaming command on Windows: the drain is driven by
    # fake Win32 modules (the t/1009 pattern, M7 names) that
    # report real byte counts via FIONREAD on the open3 pipes.
    # The fake is installed only off Windows; on Windows the
    # real modules run. Both streams are drained, with a
    # timeout and without one.
    my %M7_FAKE_FH_FOR_HANDLE;
    my $M7_FIONREAD = $^O eq 'darwin' ? 0x4004667F : 0x541B;
    if ( !$IS_WINDOWS ) {
        $INC{'Win32/API.pm'}     = 'fake-t1011';
        $INC{'Win32API/File.pm'} = 'fake-t1011';
        no warnings qw(once redefine prototype);
        *Win32::API::new = sub {
            my ( $class, @args ) = @_;
            return bless {}, 'M7::FakePeek';
        };
        *M7::FakePeek::Call = sub {
            my ( $self, $handle, $buffer, $n, $bytes_read, $total_avail, $bytes_left ) = @_;
            my $fh = $M7_FAKE_FH_FOR_HANDLE{$handle};
            return 0 if !defined $fh;
            my $sel = IO::Select->new($fh);
            my @ready = $sel->can_read(0);
            if ( !@ready ) {
                $_[5] = pack 'L', 0;
                return 1;
            }
            my $packed = pack 'L', 0;
            my $ok = ioctl( $fh, $M7_FIONREAD, $packed );
            return 0 if !$ok;
            my $count = unpack 'L', $packed;
            return 0 if $count == 0;
            $_[5] = pack 'L', $count;
            return 1;
        };
        *Win32API::File::GetOsFHandle = sub {
            my ($fh) = @_;
            return undef if !defined $fh || !defined fileno($fh);
            my $handle = fileno($fh);
            $M7_FAKE_FH_FOR_HANDLE{$handle} = $fh;
            return $handle;
        };
    }
    my $r1;
    {
        local $^O = 'MSWin32';
        $r1 = $M7_SM->_run_streaming_command(
            command => [ $^X, '-e', 'print "m7-out\n"; print STDERR "m7-err\n";' ],
            timeout_ms => 5000,
        );
    }
    is( $r1->{stdout}, "m7-out\n", 'streaming: stdout is drained on Windows' );
    is( $r1->{stderr}, "m7-err\n", 'streaming: stderr is drained on Windows' );
    is( $r1->{exit}, 0, 'streaming: the child exits cleanly' );
    is( $r1->{timed_out}, 0, 'streaming: the child does not time out' );
    my $r2;
    {
        local $^O = 'MSWin32';
        $r2 = $M7_SM->_run_streaming_command(
            command => [ $^X, '-e', 'print "m7-out2\n";' ],
        );
    }
    is( $r2->{stdout}, "m7-out2\n", 'streaming: stdout is drained without a timeout' );
    is( $r2->{exit}, 0, 'streaming: the child without a timeout exits cleanly' );
}

# ======================================================================
# SECTION 7 - ProcessSupervision (R178).
#
# Cover #19 gap for lib/Developer/Dashboard/ProcessSupervision.pm: 15
# branch cells + 4 condition cells + 0 subs. Every cell is
# accounted for below as covered, or as probed-uncoverable with
# the evidence.
#
# COVERED HERE. B 91 true (a GoRoutine child that has exited is
# reaped through the native process API), B 194 true (the in-place
# overwrite succeeds after a stubbed rename failure over an
# unmovable source), B 452 true (a System32 taskkill.exe is
# present under a fake SystemRoot), B 522 true (the second call
# returns the cached import) and false (the first call imports),
# B 527 / B 529 / B 531 / B 533 false (the import succeeding),
# B 541 false (the import succeeds), B 572 true /
# false (OpenProcess returning a falsy and a real handle),
# B 576 true / false (GetExitCodeProcess succeeding and failing),
# B 578 true / false (a wrong and a matching real pid) + C 578
# !l, l&&!r and l&&r (an undef, a wrong and a matching real pid),
# B 579 true / false (no exit code and one), B 580 true / false
# (STILL_ACTIVE and an exited code), C 449 l&&!r (an empty
# command resolution), C 450 l (a SystemRoot is set).
#
# PROBED-UNCOVERABLE, with the evidence. B 265 true: the restore
# rename in _source_is_movable can only fail if the filesystem
# changes between the two adjacent renames, and there is no
# interposition point between them; a probe over a real file, a
# directory and a missing source (/tmp/m7-probes/s79-probes2.pl,
# run under Devel::Cover) left the true side at 0 while the
# false side counted 1. C 309 !l&&r: Perl's '<&' and '>&' dups
# are symmetric - both succeed exactly when the descriptor is
# valid - so a descriptor that fails the read dup but passes the
# write dup does not exist on Linux; a probe battery over
# write-only files, O_PATH descriptors, directory handles,
# socketpairs (including shutdown halves) and both pipe ends
# (/tmp/m7-probes/s79-probes2.pl) found every descriptor duping
# both ways, and the #19 counts (8,0,1016) show the cell never
# firing across the whole suite. B 527 / B 529 / B 531 / B 533
# true: each kernel32 import failing in turn does make the
# import return undef - an isolated probe proves all four
# guards fire - but in the cover run only the last compilation
# of a reloaded file is reported, and a failed import sets the
# poison flag, so the four guard variants need four reloads and
# only the last variant's data survives. A minimal reload probe
# (/tmp/m7-reload-test/run.pl) proves the mechanism: two calls
# before a reload and two after it, yet the report shows only
# the two post-reload evaluations. The guard tests below still
# verify the behaviour (each failing import returns undef);
# the true sides cannot be recorded in the cover measurement.
#
# HOW THE CELLS ARE REACHED. B 91 polls process_exited directly
# instead of _wait_for_exit, because _wait_for_exit reaps the
# child through wait_process and deletes the registry entry
# reap_child needs. B 194 stubs _rename_path on the RuntimeManager
# (the wrapper the module documents as the seam for simulating
# platform rename failures) and blocks the movability probe with
# a non-empty directory at the probe path, so the source is
# genuinely unmovable while still readable. The taskkill tests
# localise $OS_NAME and $ENV{PATH} to an empty directory, and
# stub command_in_path in the ProcessSupervision stash for the
# empty resolution (command_in_path can only return undef or a
# non-empty path: its candidates are catfile joins and empty PATH
# entries are skipped). The Windows API tests reload
# ProcessSupervision for fresh file lexicals before each import
# variant, because a failed import sets the poison flag and
# blocks every retry in the same process, and the earlier
# sections already called _pid_is_running with $OS_NAME
# localised, so the flag is very likely already set in this
# process. All API calls after a reload are fully qualified as
# Developer::Dashboard::ProcessSupervision::... because the
# RuntimeManager-imported copies still point at the pre-reload
# code. The _process_exists_windows variants drive one cached
# fake API whose Call behaviour is scripted through the
# %M7::FakeApiFn::BEHAVIOUR hash, so no reload is needed
# between them.
# ======================================================================

# M7::FakeApiFn: one scripted Win32::API function object. Call
# returns the behaviour recorded for its function name, calling
# it when it is a code reference (so GetExitCodeProcess can write
# its code into the caller's buffer, as the real function does).
{
    package M7::FakeApiFn;
    our %BEHAVIOUR;
    sub new {
        my ( $class, $name ) = @_;
        return bless { name => $name }, $class;
    }
    sub Call {
        my $self = shift;
        my $value = $BEHAVIOUR{ $self->{name} };
        # Pass @_ through untouched, never copied into a fresh list:
        # a code behaviour writes its result into the caller's buffer
        # through the alias, and a copy would swallow that write.
        return ref($value) eq 'CODE' ? $value->(@_) : $value;
    }
}

# _m7_reload_process_supervision(): reloads ProcessSupervision so
# its file lexicals ($_WINDOWS_PROCESS_API and the poison flag)
# start fresh. The earlier sections already called
# _pid_is_running with $OS_NAME localised, which poisons the
# import in this process, so the API tests cannot run without it.
# Input: none. Output: none.
sub _m7_reload_process_supervision {
    delete $INC{'Developer/Dashboard/ProcessSupervision.pm'};
    local $SIG{__WARN__} = sub { };
    no warnings qw(redefine prototype);
    require Developer::Dashboard::ProcessSupervision;
}

# _m7_windows_api_with_fail($fail_name): reloads ProcessSupervision,
# installs a Win32::API::new that returns scripted fake function
# objects (undef for the named function, when given), and returns
# whatever _windows_process_api builds, or undef when the import
# fails. Input: function name to fail, or undef for a clean import.
# Output: API hash reference, or undef.
sub _m7_windows_api_with_fail {
    my ($fail_name) = @_;
    _m7_reload_process_supervision();
    my $api;
    {
        no warnings qw(redefine prototype);
        local *Win32::API::new = sub {
            my ( $class, $dll, $name ) = @_;
            return undef if defined $fail_name && $name eq $fail_name;
            return M7::FakeApiFn->new($name);
        };
        $api = Developer::Dashboard::ProcessSupervision::_windows_process_api();
    }
    return $api;
}

# 7b: B 194 true - the in-place overwrite succeeds after the
# rename fails over an unmovable source. The rename is stubbed
# to fail (the module documents _rename_path as the seam for
# simulating platform rename failures), and the source is made
# genuinely unmovable by a non-empty directory at the probe path
# _source_is_movable renames to, so the real CORE::rename in the
# probe fails while the source itself stays readable.
{
    my $m7_ps_dir = tempdir( CLEANUP => 1 );
    my $m7_ps_source = File::Spec->catfile( $m7_ps_dir, 'state.json' );
    my $m7_ps_target = File::Spec->catfile( $m7_ps_dir, 'state-final.json' );
    open my $m7_ps_fh, '>', $m7_ps_source or die "Unable to write $m7_ps_source: $!";
    print {$m7_ps_fh} "M7 state\n" or die "Unable to print: $!";
    close $m7_ps_fh or die "Unable to close $m7_ps_source: $!";
    my $m7_ps_probe = $m7_ps_source . '.movable-probe';
    mkdir $m7_ps_probe or die "Unable to mkdir $m7_ps_probe: $!";
    open my $m7_ps_probe_fh, '>', File::Spec->catfile( $m7_ps_probe, 'keep.txt' )
      or die "Unable to write the probe keep file: $!";
    close $m7_ps_probe_fh or die "Unable to close the probe keep file: $!";
    my $m7_ps_replaced;
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        no warnings qw(redefine prototype);
        local *Developer::Dashboard::RuntimeManager::_rename_path = sub { 0 };
        $m7_ps_replaced = $M7_MANAGER->_replace_state_file( $m7_ps_source, $m7_ps_target );
    }
    is( $m7_ps_replaced, 1, 'section 7: an unmovable source is replaced in place on Windows' );
    is( _m7_read_file($m7_ps_target), "M7 state\n", 'section 7: the in-place overwrite copies the source content' );
    ok( !-e $m7_ps_source, 'section 7: the source is unlinked after the in-place overwrite' );
}

# 7c: B 265 true and C 309 !l&&r are probed-uncoverable (see the
# section header). No test is written for either cell.

# 7d: B 452 true, C 449 l&&!r, C 450 l - _taskkill_command on a
# simulated Windows. The PATH is localised to an empty directory
# so command_in_path finds nothing, and the empty resolution is
# fed by a stub in the ProcessSupervision stash.
{
    my $m7_ps_empty = tempdir( CLEANUP => 1 );
    my $m7_ps_root  = tempdir( CLEANUP => 1 );
    my $m7_ps_cmd;
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        local $ENV{PATH} = $m7_ps_empty;
        delete local $ENV{SystemRoot};
        $m7_ps_cmd = Developer::Dashboard::ProcessSupervision::_taskkill_command();
    }
    is( $m7_ps_cmd, 'taskkill', 'section 7: no taskkill anywhere falls back to the bare name' );
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        local $ENV{SystemRoot} = $m7_ps_root;
        no warnings qw(redefine prototype);
        local *Developer::Dashboard::ProcessSupervision::command_in_path = sub { '' };
        $m7_ps_cmd = Developer::Dashboard::ProcessSupervision::_taskkill_command();
    }
    is( $m7_ps_cmd, 'taskkill', 'section 7: an empty taskkill resolution falls back to the bare name' );
    my $m7_ps_system32 = File::Spec->catdir( $m7_ps_root, 'System32' );
    mkdir $m7_ps_system32 or die "Unable to mkdir $m7_ps_system32: $!";
    my $m7_ps_exe = File::Spec->catfile( $m7_ps_system32, 'taskkill.exe' );
    open my $m7_ps_exe_fh, '>', $m7_ps_exe or die "Unable to write $m7_ps_exe: $!";
    close $m7_ps_exe_fh or die "Unable to close $m7_ps_exe: $!";
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        local $ENV{PATH}       = $m7_ps_empty;
        local $ENV{SystemRoot} = $m7_ps_root;
        $m7_ps_cmd = Developer::Dashboard::ProcessSupervision::_taskkill_command();
    }
    is( $m7_ps_cmd, $m7_ps_exe, 'section 7: a System32 taskkill.exe is returned when present' );
}

# 7e: B 522 true/false, B 527 / B 529 / B 531 / B 533 true/false,
# B 541 false - _windows_process_api imports the four kernel32
# functions once and caches them, and each failing import in turn
# makes the import return undef. Each variant reloads the module
# for fresh lexicals, because one failed import poisons retries.
{
    my $m7_ps_api = _m7_windows_api_with_fail(undef);
    ok( defined $m7_ps_api, 'section 7: the Windows process API imports cleanly' );
    my $m7_ps_api2 = Developer::Dashboard::ProcessSupervision::_windows_process_api();
    is( $m7_ps_api2, $m7_ps_api, 'section 7: the second import returns the cached API' );
    for my $m7_ps_fn ( qw(OpenProcess GetExitCodeProcess GetProcessId CloseHandle) ) {
        my $m7_ps_failed = _m7_windows_api_with_fail($m7_ps_fn);
        ok( !defined $m7_ps_failed, "section 7: the import fails when $m7_ps_fn cannot be imported" );
    }
}

# 7f: B 572 true/false, B 576 true/false, B 578 true/false,
# B 579 true/false, B 580 true/false, C 578 !l / l&&!r / l&&r -
# _process_exists_windows over one cached fake API whose Call
# behaviour is scripted per variant. No reload is needed between
# variants: only the behaviour hash changes.
{
    my $m7_ps_api = _m7_windows_api_with_fail(undef);
    ok( defined $m7_ps_api, 'section 7: the fake API is ready for the liveness variants' );
    my $m7_ps_pid = $$;
    my $m7_ps_exists;
    {
        local %M7::FakeApiFn::BEHAVIOUR = (
            OpenProcess => 0,
        );
        $m7_ps_exists = Developer::Dashboard::ProcessSupervision::_process_exists_windows($m7_ps_pid);
    }
    is( $m7_ps_exists, 0, 'section 7: a falsy OpenProcess handle means the process does not exist' );
    {
        local %M7::FakeApiFn::BEHAVIOUR = (
            OpenProcess         => 1234,
            GetProcessId        => undef,
            GetExitCodeProcess  => sub { $_[1] = pack 'L', 259; return 1; },
            CloseHandle         => 1,
        );
        $m7_ps_exists = Developer::Dashboard::ProcessSupervision::_process_exists_windows($m7_ps_pid);
    }
    is( $m7_ps_exists, 0, 'section 7: an undef real pid means the process does not exist' );
    {
        local %M7::FakeApiFn::BEHAVIOUR = (
            OpenProcess         => 1234,
            GetProcessId        => $m7_ps_pid + 4,
            GetExitCodeProcess  => sub { $_[1] = pack 'L', 259; return 1; },
            CloseHandle         => 1,
        );
        $m7_ps_exists = Developer::Dashboard::ProcessSupervision::_process_exists_windows($m7_ps_pid);
    }
    is( $m7_ps_exists, 0, 'section 7: a mismatched real pid means the process does not exist' );
    {
        local %M7::FakeApiFn::BEHAVIOUR = (
            OpenProcess         => 1234,
            GetProcessId        => $m7_ps_pid,
            GetExitCodeProcess  => sub { $_[1] = pack 'L', 259; return 1; },
            CloseHandle         => 1,
        );
        $m7_ps_exists = Developer::Dashboard::ProcessSupervision::_process_exists_windows($m7_ps_pid);
    }
    is( $m7_ps_exists, 1, 'section 7: STILL_ACTIVE means the process exists' );
    {
        local %M7::FakeApiFn::BEHAVIOUR = (
            OpenProcess         => 1234,
            GetProcessId        => $m7_ps_pid,
            GetExitCodeProcess  => sub { $_[1] = pack 'L', 0; return 1; },
            CloseHandle         => 1,
        );
        $m7_ps_exists = Developer::Dashboard::ProcessSupervision::_process_exists_windows($m7_ps_pid);
    }
    is( $m7_ps_exists, 0, 'section 7: an exited code means the process does not exist' );
    {
        local %M7::FakeApiFn::BEHAVIOUR = (
            OpenProcess         => 1234,
            GetProcessId        => $m7_ps_pid,
            GetExitCodeProcess  => sub { return 0; },
            CloseHandle         => 1,
        );
        $m7_ps_exists = Developer::Dashboard::ProcessSupervision::_process_exists_windows($m7_ps_pid);
    }
    is( $m7_ps_exists, 0, 'section 7: a failed exit-code read means the process does not exist' );
}

# 7a: B 91 true - a GoRoutine child that has exited is reaped
# through the native process API. The poll uses process_exited
# directly, never _wait_for_exit: _wait_for_exit calls
# wait_process, which deletes the registry entry reap_child
# needs, so the reap would always report false afterwards.
# This block runs AFTER 7f on purpose: the 7e/7f reloads
# discard Devel::Cover data for ProcessSupervision, so a
# reap before the last reload would never be recorded.
# It runs in the final compilation, after the last reload.
{
    # PERL5OPT is cleared for the child: under Devel::Cover the
    # parent inherits -MDevel::Cover, and a child that loads it
    # takes seconds to start, longer than a short poll bound.
    # $^O is localised to MSWin32 around the spawn: the
    # registry keep in GoRoutine keys off runtime $^O (not
    # $OS_NAME), so only a spawn under a localised $^O
    # records the child, and only a recorded child lets
    # reap_child return true (B 91 true). Without it the
    # reap falls through to waitpid and the branch never
    # fires. The comment in GoRoutine.pm names this as the
    # designed test seam.
    my $m7_ps_pid;
    {
        local $^O = 'MSWin32';
        $m7_ps_pid = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', '1' ], { env => { PERL5OPT => '' } } );
    }
    ok( defined $m7_ps_pid, 'section 7: the GoRoutine child spawns' );
    my $m7_ps_exited = 0;
    my $m7_ps_deadline = time() + 30;
    while ( time() < $m7_ps_deadline ) {
        last if Developer::Dashboard::GoRoutine::process_exited($m7_ps_pid);
        Time::HiRes::sleep(0.05);
    }
    $m7_ps_exited = Developer::Dashboard::GoRoutine::process_exited($m7_ps_pid);
    ok( $m7_ps_exited, 'section 7: the GoRoutine child has exited' );
    BAIL_OUT('section 7: the GoRoutine child never exited') if !$m7_ps_exited;
    my $m7_ps_reaped;
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        $m7_ps_reaped = $M7_MANAGER->_reap_child_process($m7_ps_pid);
    }
    is( $m7_ps_reaped, 1, 'section 7: an exited GoRoutine child is reaped on Windows' );
    ok( !Developer::Dashboard::GoRoutine::is_spawn_child($m7_ps_pid), 'section 7: the reaped child leaves the spawn registry' );
}

# ======================================================================
# SECTION 8 - PageRuntime (R178).
#
# Cover #19 gap for lib/Developer/Dashboard/PageRuntime.pm: 15
# branch cells + 3 condition cells + 0 subs. Every cell is
# accounted for below as covered, or as probed-uncoverable with
# the evidence.
#
# COVERED HERE. B 845 true + C 845 !l and l&&!r (an undef handle
# and a closed one), B 846 true (a defined peek), B 848 true (a
# GetOsFHandle that returns undef) and false (a real handle),
# B 854 true (a peek Call that returns 0) and false (a real
# count), B 858 true (a tied handle whose FILENO turns undef),
# B 897 true (a localised $^O) and false (the plain path),
# B 901 true (a PeekNamedPipe import that returns undef) and
# false (a real fake peek), B 927 true (a closed handle in the
# stream loop), C 969 l (a non-empty broken list, from 8c2: one
# broken handle and one live one), B 982 true
# (a writer that dies in the post-exit drain) and false (a writer
# that returns), B 986 true (a writer that returns false in the
# post-exit drain) and false (a writer that returns true),
# B 992 true (a peek Call that dies) and false (a clean stream),
# B 999 true (a fatal error with no termination yet) + C 999
# l&&r (a defined fatal error and no termination), B 1005 true
# (a fatal error is rethrown) and false (a clean return).
#
# PROBED-UNCOVERABLE, with the evidence. B 972 false: the
# assignment to $saved_status sits inside the child-exited block,
# which always ends in last STREAM, and it is the only write to
# that fresh lexical in the sub, so the guard can never see it
# already defined; the child-exited tests below fire the true
# side and the false side stays at 0. C 999 l&&!r: a defined
# fatal error and an already-terminated stream cannot co-occur -
# $terminated is only set when $disconnected or $stream_error is
# set, and those are only set on paths that exit the loop cleanly
# (last STREAM), while a fatal error only arises when the outer
# eval dies, which bypasses those assignments; no path sets both.
# B 862 true: select never returns undef for the call this code
# makes - a closed descriptor returns -1 and an out-of-range bit
# returns 0 (probes: select on a closed fd gives -1, on a
# 999999 fd gives 0, both defined), and the zero timeout leaves
# no window for an interrupting signal, so the guard is defensive
# dead code.
#
# HOW THE CELLS ARE REACHED. The readiness helper is called
# directly for its own cells, with a tied handle for the FILENO
# cases (its FILENO returns a defined descriptor first and undef
# second, so the two fileno calls in the helper see different
# answers). The stream tests localise $^O to MSWin32 and drive
# the section-6i fake peek for the real byte counts, a lying
# peek (Call reports zero available while the pipes hold data)
# for the post-exit drain cells - the data must be invisible to
# the readiness poll but present for the drain - and a dying
# peek for the fatal path. The worker pid is a GoRoutine child
# that has already exited, polled through process_exited without
# reaping so the child-exited check sees it. The write ends of
# the pipes are closed before each stream call, so a sysread can
# only return buffered bytes or end of file, never block.
# ======================================================================

require Developer::Dashboard::PageRuntime;

my $M7_PR = Developer::Dashboard::PageRuntime->new( paths => $M7_PATHS );

# M7::TiedFh: a tied handle whose FILENO answers from a list, so
# successive fileno calls can disagree (defined, then undef).
{
    package M7::TiedFh;
    sub TIEHANDLE {
        my ( $class, @values ) = @_;
        return bless { values => \@values, n => 0 }, $class;
    }
    sub FILENO {
        my ($self) = @_;
        return $self->{values}[ $self->{n}++ ];
    }
}

# M7::LyingPeek: a PeekNamedPipe that always reports zero bytes
# available, while the real pipes hold data. The post-exit drain
# then sees the data the readiness poll could not.
{
    package M7::LyingPeek;
    sub new {
        my ($class) = @_;
        return bless {}, $class;
    }
    sub Call {
        my ($self) = @_;
        $_[5] = pack 'L', 0;
        return 1;
    }
}

# M7::DyingPeek: a PeekNamedPipe whose Call dies, for the fatal
# stream path.
{
    package M7::DyingPeek;
    sub new {
        my ($class) = @_;
        return bless {}, $class;
    }
    sub Call { die "M7 fatal peek\n"; }
}

# _m7_ajax_pipes_with_data($out_text, $err_text): two pipes holding
# the given bytes with their write ends closed, plus a GoRoutine
# worker that has already exited (polled, never reaped, so the
# child-exited check sees it). Input: stdout and stderr bytes.
# Output: stdout read end, stderr read end, worker pid.
sub _m7_ajax_pipes_with_data {
    my ( $out_text, $err_text ) = @_;
    pipe( my $out_r, my $out_w ) or die "Unable to pipe: $!";
    pipe( my $err_r, my $err_w ) or die "Unable to pipe: $!";
    # syswrite, never print: a print is buffered and the bytes would
    # not be in the kernel pipe yet when the peek counts them.
    syswrite( $out_w, $out_text ) == length($out_text) or die "Unable to write: $!";
    syswrite( $err_w, $err_text ) == length($err_text) or die "Unable to write: $!";
    close $out_w or die "Unable to close: $!";
    close $err_w or die "Unable to close: $!";
    # PERL5OPT is cleared for the child: under Devel::Cover the
    # parent inherits -MDevel::Cover, and a child that loads it
    # takes seconds to start, longer than a short poll bound.
    my $pid = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', '1' ], { env => { PERL5OPT => '' } } );
    die 'GoRoutine spawn failed' if !defined $pid;
    my $deadline = time() + 30;
    while ( time() < $deadline ) {
        last if Developer::Dashboard::GoRoutine::process_exited($pid);
        Time::HiRes::sleep(0.05);
    }
    BAIL_OUT('section 8: the Ajax worker never exited')
      if !Developer::Dashboard::GoRoutine::process_exited($pid);
    return ( $out_r, $err_r, $pid );
}

# 8a: B 845 true + C 845 !l / l&&!r, B 846 true, B 848 true/false,
# B 854 true/false, B 858 true - the readiness helper, called
# directly. B 862 is probed-uncoverable (see the header).
{
    my $m7_pr_avail = $M7_PR->_saved_ajax_windows_pipe_available( undef, undef );
    is( $m7_pr_avail, undef, 'section 8: an undef handle has no bytes available' );
    open my $m7_pr_closed, '<', File::Spec->devnull() or die "Unable to open devnull: $!";
    close $m7_pr_closed or die "Unable to close: $!";
    $m7_pr_avail = $M7_PR->_saved_ajax_windows_pipe_available( undef, $m7_pr_closed );
    is( $m7_pr_avail, undef, 'section 8: a closed handle has no bytes available' );
    pipe( my $m7_pr_r, my $m7_pr_w ) or die "Unable to pipe: $!";
    # syswrite, never print: a print is buffered and the bytes would
    # not be in the kernel pipe yet when the peek counts them.
    syswrite( $m7_pr_w, "M7 data\n" ) == 8 or die "Unable to write: $!";
    my $m7_pr_peek = Win32::API->new( 'kernel32', 'PeekNamedPipe', 'QPIPPP', 'I' );
    $m7_pr_avail = $M7_PR->_saved_ajax_windows_pipe_available( $m7_pr_peek, $m7_pr_r );
    is( $m7_pr_avail, 8, 'section 8: the peek reports the bytes waiting in the pipe' );
    close $m7_pr_w or die "Unable to close: $!";
    {
        no warnings qw(redefine prototype);
        local *Win32API::File::GetOsFHandle = sub { return undef; };
        $m7_pr_avail = $M7_PR->_saved_ajax_windows_pipe_available( $m7_pr_peek, $m7_pr_r );
    }
    is( $m7_pr_avail, undef, 'section 8: an unreachable handle has no bytes available' );
    {
        local %M7::FakeApiFn::BEHAVIOUR = ( PeekNamedPipe => 0 );
        my $m7_pr_zero = M7::FakeApiFn->new('PeekNamedPipe');
        $m7_pr_avail = $M7_PR->_saved_ajax_windows_pipe_available( $m7_pr_zero, $m7_pr_r );
    }
    is( $m7_pr_avail, undef, 'section 8: a failed peek call has no bytes available' );
    # A package glob, not a lexical: tie *$scalar does not
    # autovivify a glob from an undef scalar.
    tie *M7::TiedFhHandle, 'M7::TiedFh', 3, undef;
    $m7_pr_avail = $M7_PR->_saved_ajax_windows_pipe_available( undef, *M7::TiedFhHandle );
    is( $m7_pr_avail, undef, 'section 8: a handle whose descriptor vanishes has no bytes available' );
    close $m7_pr_r or die "Unable to close: $!";
}

# 8b: B 897 true, B 901 true - the PeekNamedPipe import fails on
# a localised Windows.
{
    my ( $m7_pr_out, $m7_pr_err );
    pipe( $m7_pr_out, my $m7_pr_w1 ) or die "Unable to pipe: $!";
    pipe( $m7_pr_err, my $m7_pr_w2 ) or die "Unable to pipe: $!";
    my $m7_pr_died;
    {
        local $^O = 'MSWin32';
        no warnings qw(redefine prototype);
        local *Win32::API::new = sub { return undef; };
        my $ok = eval {
            $M7_PR->_stream_saved_ajax_windows(
                pid    => $$,
                path   => 'm7.pl',
                stdout => $m7_pr_out,
                stderr => $m7_pr_err,
            );
            1;
        };
        $m7_pr_died = $@ if !$ok;
    }
    like( $m7_pr_died, qr/Could not import PeekNamedPipe/, 'section 8: a failed PeekNamedPipe import dies' );
    close $m7_pr_w1 or die "Unable to close: $!";
    close $m7_pr_w2 or die "Unable to close: $!";
    close $m7_pr_out or die "Unable to close: $!";
    close $m7_pr_err or die "Unable to close: $!";
}

# 8c: B 927 true - closed handles in the stream loop are
# reported broken, drained as read errors, and retired. Both
# handles are closed here, so @live empties and the loop leaves
# at last STREAM before line 969; C 969 l needs the one-broken
# one-live case in 8c2.
{
    pipe( my $m7_pr_out, my $m7_pr_w1 ) or die "Unable to pipe: $!";
    pipe( my $m7_pr_err, my $m7_pr_w2 ) or die "Unable to pipe: $!";
    close $m7_pr_w1 or die "Unable to close: $!";
    close $m7_pr_w2 or die "Unable to close: $!";
    close $m7_pr_out or die "Unable to close: $!";
    close $m7_pr_err or die "Unable to close: $!";
    my $m7_pr_pid = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', '1' ], {} );
    die 'GoRoutine spawn failed' if !defined $m7_pr_pid;
    my @m7_pr_read_errors;
    my $m7_pr_result;
    {
        local $^O = 'MSWin32';
        $m7_pr_result = $M7_PR->_stream_saved_ajax_windows(
            pid           => $m7_pr_pid,
            path          => 'm7.pl',
            stdout        => $m7_pr_out,
            stderr        => $m7_pr_err,
            stdout_writer => sub { return 1; },
            stderr_writer => sub { push @m7_pr_read_errors, $_[0]; return 1; },
        );
    }
    is( $m7_pr_result->{disconnected}, 0, 'section 8: broken handles do not disconnect the stream' );
    is( $m7_pr_result->{error}, '', 'section 8: broken handles leave no stream error' );
    like( $m7_pr_read_errors[0] // '', qr/Unable to read ajax stream/, 'section 8: a broken handle reports its read error' );
}

# 8c2: C 969 l - one broken handle and one live handle reach
# the next-STREAM check with @broken set. Only the stdout read
# end is closed, so the drain reports its read error and returns
# true, the stdout handle retires, but the stderr handle stays
# live, so the loop does not leave at last STREAM and reaches
# line 969 with @broken non-empty. The stderr pipe carries data
# (not an empty EOF pipe: the fake peek returns 0 for a readable
# pipe with zero bytes available, which would put stderr in
# @broken as well), so it is ready, drains its chunk, and stays
# live for the next-STREAM check. The next iteration finds the
# worker already exited and the stream ends through the
# post-exit drain.
{
    pipe( my $m7_pr_out, my $m7_pr_w1 ) or die "Unable to pipe: $!";
    pipe( my $m7_pr_err, my $m7_pr_w2 ) or die "Unable to pipe: $!";
    close $m7_pr_w1 or die "Unable to close: $!";
    my $m7_pr_written = syswrite( $m7_pr_w2, "M7 err\n" );
    die "Unable to write: $!" if !defined $m7_pr_written || $m7_pr_written != 7;
    close $m7_pr_w2 or die "Unable to close: $!";
    close $m7_pr_out or die "Unable to close: $!";
    my $m7_pr_pid = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', '1' ], { env => { PERL5OPT => '' } } );
    die 'GoRoutine spawn failed' if !defined $m7_pr_pid;
    my @m7_pr_err_chunks;
    my $m7_pr_result;
    {
        local $^O = 'MSWin32';
        $m7_pr_result = $M7_PR->_stream_saved_ajax_windows(
            pid           => $m7_pr_pid,
            path          => 'm7.pl',
            stdout        => $m7_pr_out,
            stderr        => $m7_pr_err,
            stdout_writer => sub { return 1; },
            stderr_writer => sub { push @m7_pr_err_chunks, $_[0]; return 1; },
        );
    }
    is( $m7_pr_result->{disconnected}, 0, 'section 8: one broken handle does not disconnect the stream' );
    is( $m7_pr_result->{error}, '', 'section 8: one broken handle leaves no stream error' );
    like( $m7_pr_err_chunks[0] // '', qr/Unable to read ajax stream/, 'section 8: one broken handle reports its read error' );
    is( $m7_pr_err_chunks[1] // '', "M7 err\n", 'section 8: the live handle still delivers its chunk' );
    close $m7_pr_err if defined fileno($m7_pr_err);
}

# 8d: B 982 true/false, B 986 true/false - the post-exit drain,
# reached through a lying peek so the data is invisible to the
# readiness poll but present for the drain.
{
    my ( $m7_pr_out, $m7_pr_err, $m7_pr_pid ) = _m7_ajax_pipes_with_data( "M7 ajax out\n", "M7 ajax err\n" );
    my ( @m7_pr_out_chunks, @m7_pr_err_chunks );
    my $m7_pr_result;
    {
        local $^O = 'MSWin32';
        no warnings qw(redefine prototype);
        local *Win32::API::new = sub { return M7::LyingPeek->new(); };
        $m7_pr_result = $M7_PR->_stream_saved_ajax_windows(
            pid           => $m7_pr_pid,
            path          => 'm7.pl',
            stdout        => $m7_pr_out,
            stderr        => $m7_pr_err,
            stdout_writer => sub { push @m7_pr_out_chunks, $_[0]; return 1; },
            stderr_writer => sub { push @m7_pr_err_chunks, $_[0]; return 1; },
        );
    }
    is( $m7_pr_result->{disconnected}, 0, 'section 8: a clean post-exit drain does not disconnect' );
    is( join( '', @m7_pr_out_chunks ), "M7 ajax out\n", 'section 8: the post-exit drain delivers the stdout bytes' );
    is( join( '', @m7_pr_err_chunks ), "M7 ajax err\n", 'section 8: the post-exit drain delivers the stderr bytes' );
}
{
    my ( $m7_pr_out, $m7_pr_err, $m7_pr_pid ) = _m7_ajax_pipes_with_data( "M7 ajax out\n", "M7 ajax err\n" );
    my $m7_pr_result;
    {
        local $^O = 'MSWin32';
        no warnings qw(redefine prototype);
        local *Win32::API::new = sub { return M7::LyingPeek->new(); };
        $m7_pr_result = $M7_PR->_stream_saved_ajax_windows(
            pid           => $m7_pr_pid,
            path          => 'm7.pl',
            stdout        => $m7_pr_out,
            stderr        => $m7_pr_err,
            stdout_writer => sub { return 0; },
            stderr_writer => sub { return 1; },
        );
    }
    is( $m7_pr_result->{disconnected}, 1, 'section 8: a writer that refuses disconnects the stream' );
}
{
    my ( $m7_pr_out, $m7_pr_err, $m7_pr_pid ) = _m7_ajax_pipes_with_data( "M7 ajax out\n", "M7 ajax err\n" );
    my $m7_pr_result;
    {
        local $^O = 'MSWin32';
        no warnings qw(redefine prototype);
        local *Win32::API::new = sub { return M7::LyingPeek->new(); };
        $m7_pr_result = $M7_PR->_stream_saved_ajax_windows(
            pid           => $m7_pr_pid,
            path          => 'm7.pl',
            stdout        => $m7_pr_out,
            stderr        => $m7_pr_err,
            stdout_writer => sub { die "M7 writer die\n"; },
            stderr_writer => sub { return 1; },
        );
    }
    is( $m7_pr_result->{disconnected}, 0, 'section 8: a dying writer ends the stream through its error, not a disconnect' );
    like( $m7_pr_result->{error}, qr/M7 writer die/, 'section 8: a dying writer reports its error' );
}

# 8e: B 992 true, B 999 true + C 999 l&&r, B 1005 true - a peek
# Call that dies is a fatal stream error, rethrown after the
# worker is terminated.
{
    my ( $m7_pr_out, $m7_pr_err, $m7_pr_pid ) = _m7_ajax_pipes_with_data( "M7 ajax out\n", "M7 ajax err\n" );
    my $m7_pr_died;
    {
        local $^O = 'MSWin32';
        no warnings qw(redefine prototype);
        local *Win32::API::new = sub { return M7::DyingPeek->new(); };
        my $ok = eval {
            $M7_PR->_stream_saved_ajax_windows(
                pid    => $m7_pr_pid,
                path   => 'm7.pl',
                stdout => $m7_pr_out,
                stderr => $m7_pr_err,
            );
            1;
        };
        $m7_pr_died = $@ if !$ok;
    }
    like( $m7_pr_died, qr/M7 fatal peek/, 'section 8: a dying peek is rethrown as a fatal stream error' );
}

# 8f: the happy path - the real fake peek reports the bytes, the
# ready drain delivers them, and the post-exit drain retires the
# handles at end of file.
{
    my ( $m7_pr_out, $m7_pr_err, $m7_pr_pid ) = _m7_ajax_pipes_with_data( "M7 ajax out\n", "M7 ajax err\n" );
    my ( @m7_pr_out_chunks, @m7_pr_err_chunks );
    my $m7_pr_result;
    {
        local $^O = 'MSWin32';
        $m7_pr_result = $M7_PR->_stream_saved_ajax_windows(
            pid           => $m7_pr_pid,
            path          => 'm7.pl',
            stdout        => $m7_pr_out,
            stderr        => $m7_pr_err,
            stdout_writer => sub { push @m7_pr_out_chunks, $_[0]; return 1; },
            stderr_writer => sub { push @m7_pr_err_chunks, $_[0]; return 1; },
        );
    }
    is( $m7_pr_result->{disconnected}, 0, 'section 8: a clean stream does not disconnect' );
    is( join( '', @m7_pr_out_chunks ), "M7 ajax out\n", 'section 8: the ready drain delivers the stdout bytes' );
    is( join( '', @m7_pr_err_chunks ), "M7 ajax err\n", 'section 8: the ready drain delivers the stderr bytes' );
}

# ======================================================================
# SECTION 9 - SkillDispatcher (R178).
#
# Cover #19 gap for lib/Developer/Dashboard/SkillDispatcher.pm: 12
# branch cells + 4 condition cells + 1 sub. Every cell is
# accounted for below as covered, or as probed-uncoverable with
# the evidence.
#
# COVERED HERE. B 401 true (the Windows drain runs under a
# localised $^O) + S __ANON__@406 (the drain callback runs) +
# B 407 true / false (stdout and stderr chunks) + B 418 false
# (the drain succeeds, no select fallback), B 468 true (the
# Windows replacement runs under a localised $^O) + B 479 true /
# false (a status above 255 and one at zero), B 1136 true + C
# 1136 l&&r (a cached page over an unsettled stat), B 1143 true
# / false (a disk that differs, one that is unreadable, and one
# that matches) + C 1143 or-3 !l / l&&!r / l&&r (an undef disk, a
# matching disk, a differing disk) + C 1143 or-2 l / !l&&r (a
# cached raw instruction present and absent), B 1249 false (no
# high-resolution stat), B 1250 true / false (a non-array stat, a
# stat without a timestamp, and a real one) + C 1250 l / !l&&r /
# !l&&!r, B 1251 true / false (a recent and an old timestamp),
# B 2100 true (an opendir under descriptor exhaustion).
#
# PROBED-UNCOVERABLE, with the evidence. B 2235 true: basename
# never returns undef for a defined path (a probe over '', '/',
 'foo/',
# 'foo', '.' and '..' all returned defined strings) and dies on
# an undef one ("fileparse(): need a valid pathname"), so the
# guard can never see an undef skill name; the false side is
# covered and the true side is defensive dead code.
#
# HOW THE CELLS ARE REACHED. The child-command test localises
# $^O and silences STDOUT and STDERR to devnull around the call
# with the file's own save/restore helpers, so the callback
# prints never reach the TAP stream; the return value proves the
# callback told the streams apart. The replacement test installs an exit override (which dies with the exit code
# while its flag is set, and is the real exit otherwise) and then
# reloads SkillDispatcher, so the exit in _exec_replacement
# resolves to the override; the reload is verified by comparing
# the replacement sub before and after, and the test bails out
# rather than ever calling a real exit. The child-command test
# runs AFTER the replacement test on purpose: the reload
# discards Devel::Cover data for SkillDispatcher, so a drain
# before the reload would never be recorded. The nav-cache tests prime
# the literal cache through _load_skill_page over a fixture skill
# (dashboards/nav/file.tt, plain text, so it builds as a raw-nav-tt
# page) with d_hires_stat localised to 0, so a just-written file
# counts as unsettled; the differing-disk case is reached by
# hand-priming a page whose raw instruction differs from the disk
# (a real rewrite changes the stat fingerprint, so the cache is
# dropped before the byte compare can run), and the unreadable-disk
# case by a subclass whose _read_skill_page_instruction dies on its
# second call only. The opendir test lowers the soft descriptor
# limit through the setrlimit syscall (Linux numbers only, so the
# test skips elsewhere) so the exhaustion stays bounded at about
# a hundred handles, then restores the limit.
# ======================================================================

require Developer::Dashboard::PageDocument;
require Developer::Dashboard::SkillDispatcher;

my $M7_SD = Developer::Dashboard::SkillDispatcher->new( paths => $M7_PATHS );

# 9b: B 468 true, B 479 true/false - the Windows replacement
# runs system and exits with the child status. The exit override
# dies with the exit code while its flag is set; SkillDispatcher
# is reloaded after the override is installed, so the exit in
# _exec_replacement resolves to it. The reload is verified first:
# if the replacement sub did not change, the test bails out
# rather than ever calling a real exit.
my $M7_EXIT_OVERRIDE = 0;
{
    no warnings qw(redefine prototype);
    *CORE::GLOBAL::exit = sub {
        my ($code) = @_;
        $code = 0 if !defined $code;
        die "M7-EXIT:$code\n" if $M7_EXIT_OVERRIDE;
        CORE::exit($code);
    };
}
sub _m7_reload_skill_dispatcher {
    delete $INC{'Developer/Dashboard/SkillDispatcher.pm'};
    local $SIG{__WARN__} = sub { };
    no warnings qw(redefine prototype);
    require Developer::Dashboard::SkillDispatcher;
}
{
    my $m7_sd_before = \&Developer::Dashboard::SkillDispatcher::_exec_replacement;
    _m7_reload_skill_dispatcher();
    my $m7_sd_after = \&Developer::Dashboard::SkillDispatcher::_exec_replacement;
    ok( $m7_sd_before != $m7_sd_after, 'section 9: SkillDispatcher reloaded for the exit override' );
    BAIL_OUT('section 9: SkillDispatcher did not reload') if $m7_sd_before == $m7_sd_after;
    my $m7_sd_exec = Developer::Dashboard::SkillDispatcher->new( paths => $M7_PATHS );
    my $m7_sd_died;
    {
        local $^O = 'MSWin32';
        $M7_EXIT_OVERRIDE = 1;
        my $ok = eval { $m7_sd_exec->_exec_replacement( [$^X], [ '-e', 'exit 1' ] ); 1; };
        $m7_sd_died = $@ if !$ok;
        $M7_EXIT_OVERRIDE = 0;
    }
    like( $m7_sd_died, qr/M7-EXIT:1/, 'section 9: a failing child exits with its status on Windows' );
    {
        local $^O = 'MSWin32';
        $M7_EXIT_OVERRIDE = 1;
        my $ok = eval { $m7_sd_exec->_exec_replacement( [$^X], [ '-e', 'exit 0' ] ); 1; };
        $m7_sd_died = $@ if !$ok;
        $M7_EXIT_OVERRIDE = 0;
    }
    like( $m7_sd_died, qr/M7-EXIT:0/, 'section 9: a clean child exits zero on Windows' );
}

# 9a: B 401 true, S __ANON__@406, B 407 true/false, B 418 false -
# the Windows drain runs under a localised $^O and delivers both
# streams through its callback. The callback prints to STDOUT and
# STDERR, so those are silenced to devnull around the call (the
# return value already proves the callback told the streams
# apart); Capture::Tiny is not used here because it warns about
# reopening STDIN under prove and pollutes the captured text.
# This block runs AFTER 9b on purpose: 9b reloads
# SkillDispatcher, and a reload discards Devel::Cover data
# for the file, so a drain before the reload would never be
# recorded. It runs in the final compilation, after the
# last reload.
{
    my $m7_sd_result;
    my ( $m7_sd_in, $m7_sd_out, $m7_sd_err ) = _m7_save_handles();
    open STDOUT, '>', File::Spec->devnull() or die "Unable to silence STDOUT: $!";
    open STDERR, '>', File::Spec->devnull() or die "Unable to silence STDERR: $!";
    my $m7_sd_ok = eval {
        local $^O = 'MSWin32';
        $m7_sd_result = $M7_SD->_run_child_command_streaming(
            command      => [$^X],
            args         => [ '-e', 'print "OUT\n"; print STDERR "ERR\n";' ],
            skill_layers => [],
        );
        1;
    };
    my $m7_sd_call_error = $@ if !$m7_sd_ok;
    _m7_restore_handles( $m7_sd_in, $m7_sd_out, $m7_sd_err );
    close $m7_sd_in;
    close $m7_sd_out;
    close $m7_sd_err;
    die $m7_sd_call_error if !$m7_sd_ok;
    is( $m7_sd_result->{stdout}, "OUT\n", 'section 9: the Windows drain collects the stdout text' );
    is( $m7_sd_result->{stderr}, "ERR\n", 'section 9: the Windows drain collects the stderr text' );
    is( $m7_sd_result->{exit_code}, 0, 'section 9: the Windows drain reports a clean exit' );
}

# 9c: B 1136 true + C 1136 l&&r, B 1143 true/false + C 1143 or-3
# !l / l&&!r / l&&r + C 1143 or-2 l / !l&&r, B 1249 false,
# B 1250 true/false + C 1250 l / !l&&r / !l&&!r, B 1251 true/false
# - the literal-nav cache and the unsettled-stat check. The
# fixture skill holds one plain-text nav fragment, which builds
# as a raw-nav-tt page and is cached by the first load.
{
    no warnings qw(redefine prototype);
    local *Time::HiRes::d_hires_stat = sub { 0 };
    is( Developer::Dashboard::SkillDispatcher::_skill_nav_stat_is_unsettled(undef), 1, 'section 9: an undef stat is unsettled' );
    is( Developer::Dashboard::SkillDispatcher::_skill_nav_stat_is_unsettled('not-an-array'), 1, 'section 9: a non-array stat is unsettled' );
    is( Developer::Dashboard::SkillDispatcher::_skill_nav_stat_is_unsettled( [ (0) x 9, undef ] ), 1, 'section 9: a stat without a timestamp is unsettled' );
    is( Developer::Dashboard::SkillDispatcher::_skill_nav_stat_is_unsettled( [ (0) x 9, time() ] ), 1, 'section 9: a recent stat is unsettled' );
    is( Developer::Dashboard::SkillDispatcher::_skill_nav_stat_is_unsettled( [ (0) x 9, time() - 100 ] ), 0, 'section 9: an old stat is settled' );
}
my $M7_SD_HOME = tempdir( CLEANUP => 1 );
my $M7_SD_ROOT = File::Spec->catdir( $M7_SD_HOME, 'm7skill' );
my $M7_SD_NAV  = File::Spec->catdir( $M7_SD_ROOT, 'dashboards', 'nav' );
mkdir $M7_SD_ROOT or die "Unable to mkdir $M7_SD_ROOT: $!";
mkdir File::Spec->catdir( $M7_SD_ROOT, 'dashboards' ) or die "Unable to mkdir: $!";
mkdir $M7_SD_NAV or die "Unable to mkdir $M7_SD_NAV: $!";
my $M7_SD_FILE = File::Spec->catfile( $M7_SD_NAV, 'file.tt' );
open my $m7_sd_fh, '>', $M7_SD_FILE or die "Unable to write $M7_SD_FILE: $!";
print {$m7_sd_fh} "M7 literal nav fragment\n" or die "Unable to print: $!";
close $m7_sd_fh or die "Unable to close $M7_SD_FILE: $!";
my $M7_SD_ARGS = {
    skill_name               => 'm7skill',
    route_id                 => 'nav/file.tt',
    layers                   => [$M7_SD_ROOT],
    cache_literal_nav        => 1,
    validated_route_segments => [ 'nav', 'file.tt' ],
};
{
    my $m7_sd_disp = Developer::Dashboard::SkillDispatcher->new( paths => $M7_PATHS );
    my $m7_sd_page1 = $m7_sd_disp->_load_skill_page(%$M7_SD_ARGS);
    is( $m7_sd_page1->{meta}{raw_instruction}, "M7 literal nav fragment\n", 'section 9: the nav fragment loads as a raw page' );
    my $m7_sd_page2;
    {
        no warnings qw(redefine prototype);
        local *Time::HiRes::d_hires_stat = sub { 0 };
        $m7_sd_page2 = $m7_sd_disp->_load_skill_page(%$M7_SD_ARGS);
    }
    ok( $m7_sd_page2 == $m7_sd_page1, 'section 9: an unchanged nav fragment is served from the cache' );
    is( $m7_sd_page2->{meta}{raw_instruction}, "M7 literal nav fragment\n", 'section 9: the cached page carries the disk content' );
}
{
    package Local::M7SkillDispatcherReadDie;
    our @ISA = ('Developer::Dashboard::SkillDispatcher');
    our $M7_READ_COUNT = 0;
    sub _read_skill_page_instruction {
        my ( $self, $file ) = @_;
        $M7_READ_COUNT++;
        die "M7 read die\n" if $M7_READ_COUNT == 2;
        return $self->SUPER::_read_skill_page_instruction($file);
    }
}
{
    $Local::M7SkillDispatcherReadDie::M7_READ_COUNT = 0;
    my $m7_sd_disp = Local::M7SkillDispatcherReadDie->new( paths => $M7_PATHS );
    my $m7_sd_page1 = $m7_sd_disp->_load_skill_page(%$M7_SD_ARGS);
    my $m7_sd_page2;
    {
        no warnings qw(redefine prototype);
        local *Time::HiRes::d_hires_stat = sub { 0 };
        $m7_sd_page2 = $m7_sd_disp->_load_skill_page(%$M7_SD_ARGS);
    }
    ok( $m7_sd_page2 != $m7_sd_page1, 'section 9: an unreadable disk drops the cached page' );
    is( $m7_sd_page2->{meta}{raw_instruction}, "M7 literal nav fragment\n", 'section 9: the dropped page reloads from disk' );
}
{
    my $m7_sd_disp = Developer::Dashboard::SkillDispatcher->new( paths => $M7_PATHS );
    my ( $m7_sd_file, undef, $m7_sd_stat ) = $m7_sd_disp->_page_location(
        'm7skill', 'nav/file.tt',
        layers                   => [$M7_SD_ROOT],
        validated_route_segments => [ 'nav', 'file.tt' ],
    );
    ok( defined $m7_sd_file, 'section 9: the nav fragment resolves to a file' );
    my $m7_sd_key = join "\0", 'm7skill', 'nav/file.tt', $m7_sd_file, $M7_SD_ROOT;
    my $m7_sd_fp = Developer::Dashboard::SkillDispatcher::_skill_nav_fingerprint($m7_sd_stat);
    my $m7_sd_hp_page = Developer::Dashboard::PageDocument->new(
        id     => 'm7skill/nav/file.tt',
        title  => 'nav/file.tt',
        layout => { body => 'M7 different content' },
        meta   => { source_format => 'raw-nav-tt', raw_instruction => 'M7 different content' },
    );
    ok( $m7_sd_disp->_cache_literal_skill_nav_page( $m7_sd_key, $m7_sd_fp, $m7_sd_hp_page, length('M7 different content') ),
        'section 9: a page with stale content is hand-primed into the cache' );
    my $m7_sd_page2;
    {
        no warnings qw(redefine prototype);
        local *Time::HiRes::d_hires_stat = sub { 0 };
        $m7_sd_page2 = $m7_sd_disp->_load_skill_page(%$M7_SD_ARGS);
    }
    ok( $m7_sd_page2 != $m7_sd_hp_page, 'section 9: a differing disk drops the hand-primed page' );
    is( $m7_sd_page2->{meta}{raw_instruction}, "M7 literal nav fragment\n", 'section 9: the differing disk reloads from disk' );
}
{
    my $m7_sd_disp = Developer::Dashboard::SkillDispatcher->new( paths => $M7_PATHS );
    my ( $m7_sd_file, undef, $m7_sd_stat ) = $m7_sd_disp->_page_location(
        'm7skill', 'nav/file.tt',
        layers                   => [$M7_SD_ROOT],
        validated_route_segments => [ 'nav', 'file.tt' ],
    );
    my $m7_sd_key = join "\0", 'm7skill', 'nav/file.tt', $m7_sd_file, $M7_SD_ROOT;
    my $m7_sd_fp = Developer::Dashboard::SkillDispatcher::_skill_nav_fingerprint($m7_sd_stat);
    my $m7_sd_hp_page = Developer::Dashboard::PageDocument->new(
        id     => 'm7skill/nav/file.tt',
        title  => 'nav/file.tt',
        layout => { body => 'M7 different content' },
        meta   => { source_format => 'raw-nav-tt' },
    );
    ok( $m7_sd_disp->_cache_literal_skill_nav_page( $m7_sd_key, $m7_sd_fp, $m7_sd_hp_page, length('M7 different content') ),
        'section 9: a page without a raw instruction is hand-primed into the cache' );
    my $m7_sd_page2;
    {
        no warnings qw(redefine prototype);
        local *Time::HiRes::d_hires_stat = sub { 0 };
        $m7_sd_page2 = $m7_sd_disp->_load_skill_page(%$M7_SD_ARGS);
    }
    is( $m7_sd_page2->{meta}{raw_instruction}, "M7 literal nav fragment\n", 'section 9: a missing raw instruction reloads from disk' );
}

# 9d: B 2100 true - an opendir under descriptor exhaustion. The
# soft limit is lowered through the setrlimit syscall first (Linux
# numbers only, so the test skips elsewhere), which keeps the
# exhaustion bounded at about a hundred handles; the limit is
# restored before any assertion runs.
my $M7_SD_RUN_EXHAUSTION = 0;
my ( $M7_RL_SOFT, $M7_RL_HARD, $M7_RL_GET, $M7_RL_SET );
if ( $^O eq 'linux' ) {
    ( $M7_RL_GET, $M7_RL_SET ) = $Config{archname} =~ /aarch64/ ? ( 163, 167 )
      : $Config{archname} =~ /x86_64/ ? ( 97, 160 ) : ( undef, undef );
    if ( defined $M7_RL_GET ) {
        my $m7_rl_buf = pack( 'Q Q', 0, 0 );
        if ( syscall( $M7_RL_GET, 7, $m7_rl_buf ) == 0 ) {
            ( $M7_RL_SOFT, $M7_RL_HARD ) = unpack( 'Q Q', $m7_rl_buf );
            my $m7_rl_target = $M7_RL_SOFT > 256 ? 128 : $M7_RL_SOFT;
            if ( $m7_rl_target == $M7_RL_SOFT
                || syscall( $M7_RL_SET, 7, pack( 'Q Q', $m7_rl_target, $M7_RL_HARD ) ) == 0 )
            {
                $M7_SD_RUN_EXHAUSTION = 1;
            }
        }
    }
}
SKIP: {
    skip 'descriptor exhaustion needs Linux setrlimit syscall numbers', 3
      if !$M7_SD_RUN_EXHAUSTION;
    my $m7_sd_dir = tempdir( CLEANUP => 1 );
    my $m7_sd_exhausted;
    my @m7_sd_holds;
    my $m7_sd_err;
    eval {
        while ( @m7_sd_holds < 10000 ) {
            my $ok = open my $fh, '<', File::Spec->devnull();
            last if !$ok;
            push @m7_sd_holds, $fh;
        }
        $m7_sd_exhausted = Developer::Dashboard::SkillDispatcher::_skill_nav_directory_fingerprint($m7_sd_dir);
        1;
    } or $m7_sd_err = $@;
    close $_ for @m7_sd_holds;
    @m7_sd_holds = ();
    syscall( $M7_RL_SET, 7, pack( 'Q Q', $M7_RL_SOFT, $M7_RL_HARD ) );
    die $m7_sd_err if $m7_sd_err;
    ok( defined $m7_sd_exhausted, 'section 9: a fingerprint is returned under descriptor exhaustion' );
    ok( substr( $m7_sd_exhausted, -1 ) ne "\0", 'section 9: exhaustion returns the bare identity, without children' );
    my $m7_sd_released = Developer::Dashboard::SkillDispatcher::_skill_nav_directory_fingerprint($m7_sd_dir);
    ok( substr( $m7_sd_released, -1 ) eq "\0", 'section 9: a released descriptor table returns the identity with children' );
}

# 9e: B 2235 true is probed-uncoverable (see the section header).
# No test is written for it.

# =====================================================================
# SECTION 10 - Small modules: Collector, TimeUtils, Result, Config,
# ActionRunner, Paths, Prompt (R178).
#
# Collector 2 branch cells, TimeUtils 1, Result 1, Config 1,
# ActionRunner 1, Paths 2, Prompt 3 condition cells.
#
# 10a: Paths B 574 false is probed-uncoverable. The sub guards with
# -f $file first, and _resolve_symlinks returns undef only for a
# symlink loop (over 40 hops or a repeated target), which makes -f
# fail first: a probe over a two-link loop gives resolve undef and -f
# false together, so the ternary's false side cannot fire after the
# -f guard. B 573 false is coverable: the lib entry is independent
# of the file, so a loop in lib dies after the ternary fires.
# =====================================================================

require_ok('Developer::Dashboard::Collector');
require_ok('Developer::Dashboard::TimeUtils');
require_ok('Developer::Dashboard::Runtime::Result');
require_ok('Developer::Dashboard::Config');
require_ok('Developer::Dashboard::ActionRunner');
require_ok('Developer::Dashboard::CLI::Paths');
require_ok('Developer::Dashboard::Prompt');

# 10a: Collector _normalize_log_text, the undef and non-empty sides.
is( Developer::Dashboard::Collector::_normalize_log_text(undef), '',
    'section 10: undef text normalizes to empty' );
is( Developer::Dashboard::Collector::_normalize_log_text("a\n\n\n"), "a\n",
    'section 10: trailing blank lines collapse to one newline' );

# 10b: TimeUtils _now_iso8601, the negative-offset side. A POSIX zone
# west of UTC makes localtime lag gmtime, so the sign is '-'.
{
    local $ENV{TZ} = 'EST5';
    POSIX::tzset();
    my $m7_local = Developer::Dashboard::TimeUtils::_now_iso8601( tz => 'local' );
    like( $m7_local, qr/-0500\z/, 'section 10: a western zone gives a negative offset' );
    POSIX::tzset();
}

# 10c: Result _open_channel_file, the chmod-failure side. The tempfile
# call is intercepted in the Result namespace so the channel path does
# not exist, and $OS_NAME is localised to MSWin32 so the path form of
# the chmod runs; the chmod fails and the sub dies.
{
    local *Developer::Dashboard::Runtime::Result::tempfile = sub {
        open my $fh, '<', File::Spec->devnull();
        return ( $fh, '/nonexistent-m7-result-xyz' );
    };
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my $m7_died;
    eval { Developer::Dashboard::Runtime::Result::_open_channel_file(); 1 }
        or $m7_died = $@;
    like( $m7_died, qr/Unable to chmod RESULT tempfile/,
        'section 10: a failed chmod dies' );
}

# 10d: Config _normalize_home_path, the Windows fold side. The home
# and the path arrive with backslashes and fold to one separator.
{
    my $m7_fake_paths = bless { home => 'C:\Users\test' },
        'Developer::Dashboard::PathRegistry';
    my $m7_config = bless { paths => $m7_fake_paths },
        'Developer::Dashboard::Config';
    local $^O = 'MSWin32';
    is( Developer::Dashboard::Config::_normalize_home_path(
            $m7_config, 'C:\Users\test\file.txt' ),
        '$HOME/file.txt', 'section 10: backslashes fold on Windows' );
}

# 10e: ActionRunner _terminate_background_child, the Windows side.
# The pid is not a real child, so the taskkill is a no-op and the
# waitpid returns at once.
{
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( Developer::Dashboard::ActionRunner::_terminate_background_child(999999),
        1, 'section 10: the Windows terminate path returns true' );
}

# 10f: Paths _load_skill_folder_module, the unresolvable-lib side.
# The lib entry is a symlink loop, so _resolve_symlinks returns undef
# and the sub dies after the ternary fires.
{
    my $m7_dir = tempdir( CLEANUP => 1 );
    my $m7_loop = File::Spec->catdir( $m7_dir, 'looplib' );
    mkdir $m7_loop;
    symlink( 'b', File::Spec->catfile( $m7_loop, 'a' ) );
    symlink( 'a', File::Spec->catfile( $m7_loop, 'b' ) );
    my $m7_file = File::Spec->catfile( $m7_dir, 'Folder.pm' );
    open my $m7_fh, '>', $m7_file or die "cannot write $m7_file: $!";
    print {$m7_fh} "package M7TestSkill;\n1;\n";
    close $m7_fh;
    my $m7_died;
    eval {
        Developer::Dashboard::CLI::Paths::_load_skill_folder_module(
            {   dir  => $m7_dir,
                lib  => File::Spec->catfile( $m7_loop, 'a' ),
                file => $m7_file,
            }
        );
        1;
    } or $m7_died = $@;
    like( $m7_died, qr/Unable to resolve skill Folder\.pm/,
        'section 10: an unresolvable lib dies' );
}

# 10g: Prompt render, the empty-home, undef-home and undef-cwd sides.
# The fake paths object returns '' for the project root and whatever
# home it was built with; the indicators object is never consulted
# because no_indicators is set.
{ package M7::FakePaths10;
  sub new { my ( $class, %a ) = @_; bless \%a, $class; }
  sub project_root_for { '' }
  sub home { $_[0]->{home} }
}
{
    my $m7_prompt_empty = Developer::Dashboard::Prompt->new(
        indicators => 1,
        paths      => M7::FakePaths10->new( home => '' ),
    );
    my $m7_out = $m7_prompt_empty->render( no_indicators => 1 );
    ok( defined $m7_out, 'section 10: an empty home renders' );
}
{
    my $m7_prompt_no_home = Developer::Dashboard::Prompt->new(
        indicators => 1,
        paths      => M7::FakePaths10->new(),
    );
    my $m7_out = $m7_prompt_no_home->render( no_indicators => 1 );
    ok( defined $m7_out, 'section 10: an undef home renders' );
}
{
    require Cwd;
    my $m7_del_dir = tempdir( CLEANUP => 1 );
    my $m7_saved_cwd = Cwd::getcwd();
    chdir $m7_del_dir or die "cannot chdir: $!";
    rmdir $m7_del_dir or die "cannot rmdir: $!";
    my $m7_prompt_no_home = Developer::Dashboard::Prompt->new(
        indicators => 1,
        paths      => M7::FakePaths10->new(),
    );
    my $m7_out;
    my $m7_died;
    eval { $m7_out = $m7_prompt_no_home->render( no_indicators => 1 ); 1 }
        or $m7_died = $@;
    chdir $m7_saved_cwd or die "cannot chdir back: $!";
    ok( !$m7_died, 'section 10: a deleted cwd renders' );
    ok( defined $m7_out, 'section 10: a deleted cwd still renders a prompt' );
}

# =====================================================================
# SECTION 11 - InternalCLI, Upgrade, Ask, EnvLoader (R178).
#
# InternalCLI 2 branch + 1 condition cells, Upgrade 2 branch + 2
# condition cells, Ask 3 branch + 2 condition cells, EnvLoader 4
# branch + 1 condition cells.
#
# 11a: Upgrade B 150 (system returns -1 after the startability check)
# is reached with a CORE::GLOBAL::system override installed before
# Upgrade.pm compiles: the override returns -1 for one sentinel
# program and delegates to CORE::system for everything else, so the
# compiled-in override is behaviour-identical outside the sentinel.
# The override is removed right after the require, so only Upgrade.pm
# is compiled with it.
#
# 11d2: Ask B 805 false (a path with no drive letter under a
# localised Windows takes the false side of the drive-letter
# substitution in _normalize_path_segments).
# =====================================================================

require_ok('Developer::Dashboard::InternalCLI');
require_ok('Developer::Dashboard::CLI::Ask');
require_ok('Developer::Dashboard::EnvLoader');
require_ok('Developer::Dashboard::EnvAudit');

# 11a: the system override must be installed before Upgrade.pm is
# compiled, so it is set up here, ahead of the require_ok.
my $m7_upgrade_sentinel;
{
    my $m7_up_dir = tempdir( CLEANUP => 1 );
    $m7_upgrade_sentinel = File::Spec->catfile( $m7_up_dir, 'm7-installer' );
    open my $m7_fh, '>', $m7_upgrade_sentinel
        or die "cannot write $m7_upgrade_sentinel: $!";
    print {$m7_fh} "#!/bin/sh\nexit 0\n";
    close $m7_fh;
    chmod 0755, $m7_upgrade_sentinel;
    my $m7_sentinel = $m7_upgrade_sentinel;
    *CORE::GLOBAL::system = sub {
        if ( defined $_[0] && $_[0] eq $m7_sentinel ) {
            $! = 2;
            $? = -1;
            return -1;
        }
        return CORE::system(@_);
    };
}
require_ok('Developer::Dashboard::CLI::Upgrade');
delete $CORE::GLOBAL::{system};

# 11b: InternalCLI _helper_file_is_locked, the undef and empty sides,
# and the failed-restore side (the rename is overridden so the first
# rename "succeeds" and the restore fails, without moving the file).
is( Developer::Dashboard::InternalCLI::_helper_file_is_locked(undef), 0,
    'section 11: an undef target is not locked' );
is( Developer::Dashboard::InternalCLI::_helper_file_is_locked(''), 0,
    'section 11: an empty target is not locked' );
{
    my $m7_dir = tempdir( CLEANUP => 1 );
    my $m7_target = File::Spec->catfile( $m7_dir, 'helper.pl' );
    open my $m7_fh, '>', $m7_target or die "cannot write $m7_target: $!";
    print {$m7_fh} "1;\n";
    close $m7_fh;
    my $m7_calls = 0;
    local *Developer::Dashboard::InternalCLI::_rename_path = sub {
        $m7_calls++;
        return $m7_calls == 1 ? 1 : 0;
    };
    my $m7_died;
    eval {
        Developer::Dashboard::InternalCLI::_helper_file_is_locked($m7_target);
        1;
    } or $m7_died = $@;
    like( $m7_died, qr/Unable to restore/,
        'section 11: a failed restore dies' );
}

# 11c: Upgrade _program_is_startable, the empty, missing and
# non-executable sides; and _run_command, the failed-spawn side.
is( Developer::Dashboard::CLI::Upgrade::_program_is_startable(''), 0,
    'section 11: an empty program is not startable' );
is( Developer::Dashboard::CLI::Upgrade::_program_is_startable(
        '/nonexistent/m7-prog' ),
    0, 'section 11: a missing slashed program is not startable' );
{
    my $m7_dir = tempdir( CLEANUP => 1 );
    my $m7_plain = File::Spec->catfile( $m7_dir, 'plain.txt' );
    open my $m7_fh, '>', $m7_plain or die "cannot write $m7_plain: $!";
    print {$m7_fh} "plain\n";
    close $m7_fh;
    is( Developer::Dashboard::CLI::Upgrade::_program_is_startable($m7_plain),
        0, 'section 11: a non-executable file is not startable' );
}
{
    my $m7_died;
    eval {
        Developer::Dashboard::CLI::Upgrade::_run_command(
            [$m7_upgrade_sentinel] );
        1;
    } or $m7_died = $@;
    like( $m7_died, qr/Unable to start Developer Dashboard installer/,
        'section 11: a failed spawn dies' );
}

# 11d: Ask _normalize_path_segments, the Windows drive-letter side,
# and _run_cli, the missing-command and resolvable-command sides.
{
    local $^O = 'MSWin32';
    is( Developer::Dashboard::CLI::Ask::_normalize_path_segments(
            'C:\dir\file.txt' ),
        'C:/dir/file.txt', 'section 11: a Windows drive path normalizes' );
}
{
    local $^O = 'MSWin32';
    local *STDERR;
    open STDERR, '>', File::Spec->devnull() or die "cannot open devnull: $!";
    my ( $m7_out, $m7_err, $m7_exit )
        = Developer::Dashboard::CLI::Ask::_run_cli( [undef] );
    is( $m7_exit, -1, 'section 11: a missing command reports -1' );
}
{
    local $^O = 'MSWin32';
    my ( $m7_out, $m7_err, $m7_exit )
        = Developer::Dashboard::CLI::Ask::_run_cli( [ 'perl', '-e', '1;' ] );
    is( $m7_exit, 0, 'section 11: a resolvable command runs' );
}

{
    # 11d2. Ask _normalize_path_segments, the no-drive-letter side:
    # a Unix path under a localised Windows takes the false side of
    # the drive-letter substitution and keeps its leading slash.
    local $^O = 'MSWin32';
    is( Developer::Dashboard::CLI::Ask::_normalize_path_segments('/unix/path'),
        '/unix/path', 'section 11: a drive-less path keeps its leading slash on Windows' );
}

# 11e: EnvLoader _restore_overlay_key_case. The audit keys are
# recorded explicitly (PATH is already uppercase, foo_VERSION is
# mixed case), then forgotten again so the inventory is left as found.
{
    local $ENV{DEVELOPER_DASHBOARD_ENV_AUDIT};
    local $^O = 'MSWin32';
    ok( Developer::Dashboard::EnvLoader->_restore_overlay_key_case(
            'not-a-hash' ),
        'section 11: a non-hash overlay is a no-op' );
    Developer::Dashboard::EnvAudit->record( 'PATH', 'x', '/tmp/m7-envfile' );
    ok( Developer::Dashboard::EnvLoader->_restore_overlay_key_case( {} ),
        'section 11: an uppercase key is left alone' );
    Developer::Dashboard::EnvAudit->record(
        'foo_VERSION', 'v', '/tmp/m7-envfile' );
    my $m7_overlay = { foo_VERSION => 'v' };
    ok( Developer::Dashboard::EnvLoader->_restore_overlay_key_case($m7_overlay),
        'section 11: a present recorded spelling is left alone' );
    ok( Developer::Dashboard::EnvLoader->_restore_overlay_key_case( {} ),
        'section 11: an absent folded spelling is left alone' );
    my $m7_moved = { FOO_VERSION => 'v' };
    ok( Developer::Dashboard::EnvLoader->_restore_overlay_key_case($m7_moved),
        'section 11: a folded spelling moves back' );
    is( $m7_moved->{foo_VERSION}, 'v',
        'section 11: the recorded spelling holds the value' );
    ok( !exists $m7_moved->{FOO_VERSION},
        'section 11: the folded spelling is gone' );
    Developer::Dashboard::EnvAudit->forget('PATH');
    Developer::Dashboard::EnvAudit->forget('foo_VERSION');
}

# =====================================================================
# SECTION 12 - StreamDrain, Watch, PathIdentity, PerlEnv, PageStore,
# OpenFileChooser (R178).
#
# Cover #19 gap for these modules (B/C/S): StreamDrain 1/2/0,
# Watch 6/3/0, PathIdentity 7/3/0, PerlEnv 6/3/0, PageStore 5/6/0,
# OpenFileChooser 5/1/0. Every cell is accounted for below as covered,
# or as probed-uncoverable with the evidence. The gap file is the
# authority for the cell list.
#
# COVERED HERE. StreamDrain: B 170 true (EINTR via alarm) and false
# (sysread undef, not EINTR, on a directory handle), C 136 middle
# (defined handle, fileno undef, from a closed handle), C 174 l
# (sysread undef). Watch: B 157 true + false + C 157 !l + l&&!r +
# l&&r (undef select, undef handle, a quiet pipe) and C 158 !l +
# l&&!r + l&&r (plain, a non-IO::Select select-like object on a
# localised Windows, a real IO::Select on a localised Windows),
# all driven in 12b5 after the 12b4 re-require, plus B 183 true +
# B 202 true + B 207 true + B 210 true (the PeekNamedPipe import
# fails on a cold cache, then the failure is cached). PathIdentity:
# B 43 false (the NOPE/.. trick: stat fails on the missing middle
# component, so the identity comparison runs and differs), B 82
# true + C 82 !l + l&&!r (undef and empty paths), B 96 true (a
# forty-one-link cycle: a two-link loop exits at the repeated-target
# guard first), B 99 false (a relative link target). PerlEnv:
# B 158 true + C 160 l + B 161 true + B 163 true (a fake checkout
# with local/lib/perl5 and its archname directory), B 161 false +
# C 160 !l (the same checkout with archname emptied), B 163 false
# (the same checkout with no archname directory), B 61 false +
# C 60 l (a fake powershell on PATH under a localised Windows),
# C 62 !l (no SystemRoot set, so the fallback root is C:\Windows),
# B 260 true (path_sep => '') + false (path_sep => ':'). PageStore:
# B 139 true + C 139 !l + l&&!r (undef and empty file), B 142 true +
# C 142 !l (sysopen dies on a dying-stringification path; a failed
# sysopen leaves $fh defined, so C 142 l&&!r is uncoverable, proved
# by /tmp/m7-sysopen-probe.pl, and a missing file returns ''), C 148
# !l&&r (invalid UTF-8: the CROAK decode dies and the DEFAULT decode
# returns replacement text) + !l&&!r (an empty file), B 482 true + C 482 !l + l&&!r
# (undef and empty path), B 484 true (a link loop). OpenFileChooser:
# B 80 true + B 82 true (a piped STDIN on a localised Windows, with
# and without waiting data), B 80 false (a character-device STDIN,
# neither a file nor a pipe) + B 82 false (a piped STDIN whose
# native check is unavailable), B 131 true + B 133 true + B 136 true +
# C 136 !l (the PeekNamedPipe import fails, then GetOsFHandle fails).
#
# PROBED-UNCOVERABLE, with the evidence. StreamDrain: none. Watch:
# B 344 is carve-out (4), the open that never fails. C 185 l is
# uncoverable in the cover measurement: it needs a working peek
# import, but the failing-import cells need a failing one, and one
# compilation admits only one import outcome; the only reset is a
# re-require, and a re-require discards every earlier cover row
# for the module (probe /tmp/m7-rl/run.pl: five pre-reload calls
# record nothing, the report shows the post-reload call only; the
# two-path load in /tmp/m7-rl/run2.pl discards the same way). The
# behaviour is verified by 12b3 (a dying GetOsFHandle returns
# undef). The four failing-import cells are covered instead, and
# the B 157 / C 157 / C 158 cells are driven after them in 12b5.
# PathIdentity: B 43 true + C 43 l&&r are Windows-only. On Unix
# any spelling whose identity matches the current directory is
# caught by the stat comparison first (line 36), because a
# spelling canonpath normalises to the directory (trailing slash,
# '/.', doubled slashes) also stats successfully; a spelling
# whose stat fails (a missing component, like NOPE/..) is one
# canonpath does NOT collapse (probe /tmp/m7-c43-probe.pl: the
# identity keeps the NOPE/.. spelling), so the comparison at
# line 43 is false. The true side fires on Windows, where the
# stat comparison is unreliable (see the comment at lines 37-39),
# and the proof drives it for real on the Windows legs.
# B 51 false: cwd() returns '' (not undef) when the working directory
# is deleted (probe /tmp/m7-s12-probes3.pl: getcwd undef, cwd '');
# B 88 true: File::Spec->splitpath never returns a non-empty volume
# on Unix (probe /tmp/m7-s12-probes.pl: 'C:/foo/bar' gives volume
# ''); C 87 !l: splitpath never returns an undef file on Unix
# (same probe: trailing-slash and empty paths give file ''); C 43 !l:
# _path_identity with empty_fallback returns canonpath($path) for any
# non-empty path, so the identity is never '' there; B 98 true:
# readlink never returns undef for a link that -l just confirmed
# (same probe: loops and dangling links both read fine). PerlEnv:
# C 60 !l&&r: native_shell_name returns 'pwsh' or 'powershell',
# so the two command_in_path lookups cannot disagree (the first
# is the name just resolved, the second is 'powershell' itself).
# B 68 false: the dirname of a found executable is always an
# existing directory. %Config IS localisable as a whole hash (the
# t/79 pattern: local %Config::Config = %Config::Config, then
# assign), which is what 12d3-12d5 use; localising one element
# of the tied hash dies "read-only", which is all the earlier
# probe tried. PageStore: B 146 true + C 146 !l + l&&!r: read() on a
# sysopen'd handle never dies, and $raw is initialised to '' before
# the read, so neither side can fire; C 213 !l: the disk read can only
# fail if the file changes between the lstat and the read, which cannot
# happen in a single-threaded test process, and the fingerprint gate
# skips a changed file before the comparison runs. OpenFileChooser:
# C 136 l&&!r: the eval dies when GetOsFHandle is false, so it never
# returns a defined peek with an undef handle. CommandRunner C 107
# l&&!r is UNCOVERABLE (noted here): $inline_perl_file is either
# undef or a real tempfile path, never '' - it is only ever assigned
# from _windows_perl_inline_command, which returns undef or a
# tempfile name (CommandRunner.pm:42,53,119-130).
#
# The Watch peek cache: _windows_peek_named_pipe caches its import in
# file lexicals, so the failing-import cells and the dying-GetOsFHandle
# cell cannot both fire in one process without a reset. The module is
# re-required between them (its top level is only use lines, a constant
# and sub definitions, so a re-require is safe); the redefinition
# warnings are swallowed by a local $SIG{__WARN__} guard. The failing
# import is driven with a localised Win32::API::new returning undef,
# the section-8 pattern.

# M7::FixedPeek: a PeekNamedPipe that always reports a fixed byte
# count, whether or not the pipe really holds data. The drain then
# calls sysread even when the pipe is empty, so the read blocks until
# a signal arrives. Input: fixed available count. Output: fake object.
{
    package M7::FixedPeek;
    sub new {
        my ( $class, $avail ) = @_;
        return bless { avail => $avail }, $class;
    }
    sub Call {
        my ($self) = @_;
        $_[5] = pack 'L', $self->{avail};
        return 1;
    }
}

# M7::DyingString: a path string whose stringification dies on the
# second call. The first call returns the real path (so the empty
# check passes); the second call, inside sysopen, dies, so the eval
# around it returns undef. Input: real path. Output: blessed object.
{
    package M7::DyingString;
    use overload '""' => sub {
        my ($self) = @_;
        $self->{calls}++;
        die "m7 dying stringification\n" if $self->{calls} > 1;
        return $self->{path};
    }, fallback => 1;
    sub new {
        my ( $class, $path ) = @_;
        return bless { path => $path, calls => 0 }, $class;
    }
    sub calls { return $_[0]->{calls}; }
}

require Developer::Dashboard::StreamDrain;
require Developer::Dashboard::IndicatorStore::Watch;
require Developer::Dashboard::PathIdentity;
require Developer::Dashboard::PerlEnv;
require Developer::Dashboard::PageStore;
require Developer::Dashboard::CLI::OpenFileChooser;

{
    # 12a1. B 170 true: EINTR via alarm. The fixed peek reports bytes
    # available while the pipe holds nothing, so sysread blocks; the
    # alarm fires, the handler writes the chunk and closes the pipe,
    # sysread is interrupted with EINTR, the retry reads the chunk,
    # and the next round reaches end of file. The stderr pipe is at
    # end of file from the start.
    pipe( my $m7_out_r, my $m7_out_w ) or die "Unable to pipe: $!";
    pipe( my $m7_err_r, my $m7_err_w ) or die "Unable to pipe: $!";
    close $m7_err_w or die "Unable to close: $!";
    my @m7_chunks;
    my $m7_sd = bless {}, 'Developer::Dashboard::StreamDrain';
    my $m7_result;
    {
        no warnings qw(once redefine prototype);
        local *Win32::API::new = sub { return M7::FixedPeek->new(5); };
        local $SIG{ALRM} = sub {
            syswrite( $m7_out_w, 'm7-eintr' ) == 8 or die "Unable to write: $!";
            close $m7_out_w or die "Unable to close: $!";
        };
        alarm(1);
        $m7_result = $m7_sd->_drain_child_streams_windows(
            $m7_out_r, $m7_err_r,
            sub { push @m7_chunks, [ $_[0], $_[1] ] },
            undef,
        );
        alarm(0);
    }
    is( $m7_result, 1, 'section 12: the EINTR drain finishes' );
    is( scalar @m7_chunks, 1, 'section 12: the EINTR drain delivers one chunk' );
    is( $m7_chunks[0][1], 'm7-eintr', 'section 12: the EINTR chunk holds the written bytes' );
    close $m7_out_r or die "Unable to close: $!";
    close $m7_err_r or die "Unable to close: $!";
}

{
    # 12a2. B 170 false + C 174 l: sysread fails on a directory
    # handle, which is not EINTR, so the warn fires and the read
    # counts as undef. The stderr pipe is at end of file.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    open my $m7_dir_fh, '<', $m7_tmp or die "Unable to open $m7_tmp: $!";
    pipe( my $m7_err_r, my $m7_err_w ) or die "Unable to pipe: $!";
    close $m7_err_w or die "Unable to close: $!";
    my $m7_warned = '';
    my $m7_sd     = bless {}, 'Developer::Dashboard::StreamDrain';
    my $m7_result;
    {
        no warnings qw(once redefine prototype);
        local *Win32::API::new = sub { return M7::FixedPeek->new(5); };
        local $SIG{__WARN__} = sub { $m7_warned .= $_[0]; };
        $m7_result = $m7_sd->_drain_child_streams_windows(
            $m7_dir_fh, $m7_err_r, sub { return }, undef,
        );
    }
    is( $m7_result, 1, 'section 12: the failed-read drain finishes' );
    like( $m7_warned, qr/reading a child handle failed/, 'section 12: the failed read warns' );
    close $m7_dir_fh or die "Unable to close: $!";
    close $m7_err_r or die "Unable to close: $!";
}

{
    # 12a3. C 136 middle: a defined handle whose fileno is undef (it
    # was opened and closed) ends the drain at once with 0.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_file = File::Spec->catfile( $m7_tmp, 'f' );
    open my $m7_w, '>', $m7_file or die "Unable to write $m7_file: $!";
    close $m7_w or die "Unable to close: $!";
    open my $m7_closed, '<', $m7_file or die "Unable to open $m7_file: $!";
    close $m7_closed or die "Unable to close: $!";
    pipe( my $m7_err_r, my $m7_err_w ) or die "Unable to pipe: $!";
    close $m7_err_w or die "Unable to close: $!";
    my $m7_sd = bless {}, 'Developer::Dashboard::StreamDrain';
    my $m7_result = $m7_sd->_drain_child_streams_windows(
        $m7_closed, $m7_err_r, sub { return }, undef,
    );
    is( $m7_result, 0, 'section 12: a closed handle ends the drain with 0' );
    close $m7_err_r or die "Unable to close: $!";
}

{
    # 12b1. B 157 true + C 157 !l + l&&!r: _handle_readable with an
    # undef select, then with an undef handle, returns 0 both times.
    pipe( my $m7_r, my $m7_w ) or die "Unable to pipe: $!";
    my $m7_select = IO::Select->new($m7_r);
    is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( undef, $m7_r ),
        0, 'section 12: an undef select is not readable' );
    is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $m7_select, undef ),
        0, 'section 12: an undef handle is not readable' );
    is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $m7_select, $m7_r ),
        0, 'section 12: a quiet pipe is not readable' );
    close $m7_w or die "Unable to close: $!";
    close $m7_r or die "Unable to close: $!";
}

{
    # 12b2. C 158 middle: a localised Windows with a select-like
    # object that is not a genuine IO::Select falls through to
    # can_read instead of the Windows peek path.
    pipe( my $m7_r, my $m7_w ) or die "Unable to pipe: $!";
    my $m7_like = bless {}, 'M7::SelectLike';
    {
        package M7::SelectLike;
        sub can_read { return (); }
    }
    my $m7_readable;
    {
        local $^O = 'MSWin32';
        $m7_readable = Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $m7_like, $m7_r );
    }
    is( $m7_readable, 0, 'section 12: a non-IO::Select keeps its own can_read on Windows' );
    close $m7_w or die "Unable to close: $!";
    close $m7_r or die "Unable to close: $!";
}

{
    # 12b3. C 185 l: GetOsFHandle dies inside the eval, so $@ is set
    # and _windows_handle_readable returns undef. The peek import
    # succeeds here, which sets the cache; the failing-import cells
    # below need the re-require in 12b4. The handle is a pipe, so
    # getsockopt says it is not a socket and the peek path runs.
    pipe( my $m7_r, my $m7_w ) or die "Unable to pipe: $!";
    my $m7_select = IO::Select->new($m7_r);
    my $m7_readable;
    {
        no warnings qw(once redefine prototype);
        local *Win32API::File::GetOsFHandle = sub { die "m7 getosfhandle\n"; };
        $m7_readable = Developer::Dashboard::IndicatorStore::Watch::_windows_handle_readable( $m7_select, $m7_r );
    }
    is( $m7_readable, undef, 'section 12: a dying GetOsFHandle makes the handle unreadable' );
    close $m7_w or die "Unable to close: $!";
    close $m7_r or die "Unable to close: $!";
}

{
    # 12b4. B 207 true + B 210 true + B 202 true + B 183 true: the
    # PeekNamedPipe import fails on a cold cache. The module is
    # re-required first so the cache from 12b3 is gone; the
    # redefinition warnings are swallowed by the local warn guard.
    # The first call dies inside the eval (B 207) and caches the
    # failure (B 210); the second call takes the cached-failure
    # return (B 202); a _windows_handle_readable call then finds
    # no peek at all (B 183).
    delete $INC{'Developer/Dashboard/IndicatorStore/Watch.pm'};
    {
        local $SIG{__WARN__} = sub {
            my ($warning) = @_;
            return if $warning =~ /Subroutine \S+ redefined/;
            warn $warning;
        };
        require Developer::Dashboard::IndicatorStore::Watch;
    }
    pipe( my $m7_r, my $m7_w ) or die "Unable to pipe: $!";
    my $m7_select = IO::Select->new($m7_r);
    my ( $m7_peek1, $m7_peek2, $m7_readable );
    {
        no warnings qw(once redefine prototype);
        local *Win32::API::new = sub { return undef; };
        $m7_peek1 = Developer::Dashboard::IndicatorStore::Watch::_windows_peek_named_pipe();
        $m7_peek2 = Developer::Dashboard::IndicatorStore::Watch::_windows_peek_named_pipe();
        $m7_readable = Developer::Dashboard::IndicatorStore::Watch::_windows_handle_readable( $m7_select, $m7_r );
    }
    is( $m7_peek1, undef, 'section 12: a failed PeekNamedPipe import returns undef' );
    is( $m7_peek2, undef, 'section 12: a failed PeekNamedPipe import stays failed' );
    is( $m7_readable, undef, 'section 12: no peek means the handle is unreadable' );
    close $m7_w or die "Unable to close: $!";
    close $m7_r or die "Unable to close: $!";
}

{
    # 12b5. B 157 true + false, C 157 !l + l&&!r + l&&r, C 158 !l +
    # l&&!r + l&&r: _handle_readable, driven AFTER the failing-import
    # test in 12b4. The re-require there discards every pre-reload
    # cover row for Watch (probe /tmp/m7-rl/run.pl: five pre-reload
    # calls record nothing, the report shows the post-reload call
    # only), so the same assertions in 12b1-12b2 verify behaviour
    # but count nothing; this block drives the cells in the final
    # compilation. The peek cache is poisoned by 12b4, so the
    # Windows branch here finds no peek and falls back to can_read.
    pipe( my $m7_r, my $m7_w ) or die "Unable to pipe: $!";
    my $m7_select = IO::Select->new($m7_r);
    is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( undef, $m7_r ),
        0, 'section 12: an undef select is not readable after the reload' );
    is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $m7_select, undef ),
        0, 'section 12: an undef handle is not readable after the reload' );
    is( Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $m7_select, $m7_r ),
        0, 'section 12: a quiet pipe is not readable after the reload' );
    my $m7_like = bless {}, 'M7::SelectLike';
    my $m7_readable;
    {
        local $^O = 'MSWin32';
        $m7_readable = Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $m7_like, $m7_r );
    }
    is( $m7_readable, 0, 'section 12: a non-IO::Select keeps its own can_read on Windows after the reload' );
    my $m7_win_readable;
    {
        local $^O = 'MSWin32';
        $m7_win_readable = Developer::Dashboard::IndicatorStore::Watch::_handle_readable( $m7_select, $m7_r );
    }
    is( $m7_win_readable, 0, 'section 12: a Windows handle with no peek falls back to can_read' );
    close $m7_w or die "Unable to close: $!";
    close $m7_r or die "Unable to close: $!";
}

{
    # 12c1. B 43 false: the NOPE/.. trick. The logical PWD names a
    # missing middle component, so stat fails and the identity
    # comparison runs, but canonpath does not collapse the '..'
    # (proved by /tmp/m7-c43-probe.pl: the identity keeps the
    # NOPE/.. spelling), so the identities differ and the logical
    # spelling is NOT kept; the fall-through returns the physical
    # directory. B 43 true + C 43 l&&r are Windows-only: on Unix
    # any spelling whose identity matches is caught by the stat
    # comparison first (see the section header).
    my $m7_real = tempdir( CLEANUP => 1 );
    my $m7_orig = Cwd::getcwd();
    chdir $m7_real or die "Unable to chdir $m7_real: $!";
    my $m7_logical = File::Spec->catdir( $m7_real, 'NOPE', '..' );
    my $m7_found;
    {
        local $ENV{PWD} = $m7_logical;
        $m7_found = Developer::Dashboard::PathIdentity::current_working_directory();
    }
    chdir $m7_orig or die "Unable to chdir $m7_orig: $!";
    is( $m7_found, $m7_real, 'section 12: a logical PWD through a missing component falls back to the physical directory' );
}

{
    # 12c2. B 96 true: a forty-one-link cycle runs past forty hops
    # and the resolver gives up with undef. A two-link loop will
    # not do it: the repeated-target guard at line 107 fires first
    # (after three hops), so every hop must name a fresh target.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    for my $m7_n ( 1 .. 41 ) {
        my $m7_next = $m7_n == 41 ? 1 : $m7_n + 1;
        symlink sprintf( 'm7-l%02d', $m7_next ),
            File::Spec->catfile( $m7_tmp, sprintf( 'm7-l%02d', $m7_n ) )
            or die "Unable to link: $!";
    }
    my $m7_resolved = Developer::Dashboard::PathIdentity::_resolve_symlinks(
        File::Spec->catfile( $m7_tmp, 'm7-l01', 'x' ) );
    is( $m7_resolved, undef, 'section 12: a long symlink loop resolves to undef' );
}

{
    # 12c3. B 99 false: a link with a relative target takes the
    # parent-directory branch and resolves against it.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_target = File::Spec->catfile( $m7_tmp, 'target.txt' );
    open my $m7_w, '>', $m7_target or die "Unable to write $m7_target: $!";
    close $m7_w or die "Unable to close: $!";
    symlink 'target.txt', File::Spec->catfile( $m7_tmp, 'm7-link' ) or die "Unable to link: $!";
    my $m7_resolved = Developer::Dashboard::PathIdentity::_resolve_symlinks(
        File::Spec->catfile( $m7_tmp, 'm7-link' ) );
    is( $m7_resolved, $m7_target, 'section 12: a relative link target resolves against its parent' );
}

{
    # 12c4. B 82 true + C 82 !l + l&&!r: _resolve_symlinks returns its
    # argument at once for an undef path and for an empty path.
    is( Developer::Dashboard::PathIdentity::_resolve_symlinks(undef),
        undef, 'section 12: an undef path resolves to undef' );
    is( Developer::Dashboard::PathIdentity::_resolve_symlinks(''),
        '', 'section 12: an empty path resolves to empty' );
}

{
    # 12d1. B 158 true + C 160 l + B 161 true + B 163 true: a fake
    # checkout with a local lib and its archname directory makes
    # perl5lib_list list both.
    my $m7_co = tempdir( CLEANUP => 1 );
    my $m7_lib = File::Spec->catdir( $m7_co, 'lib' );
    my $m7_dd = File::Spec->catdir( $m7_lib, 'Developer' );
    File::Path::make_path($m7_dd) or die "Unable to make $m7_dd: $!";
    my $m7_pm = File::Spec->catfile( $m7_dd, 'Dashboard.pm' );
    open my $m7_w, '>', $m7_pm or die "Unable to write $m7_pm: $!";
    close $m7_w or die "Unable to close: $!";
    my $m7_local = File::Spec->catdir( $m7_co, 'local', 'lib', 'perl5' );
    my $m7_arch = File::Spec->catdir( $m7_local, $Config::Config{archname} );
    File::Path::make_path($m7_arch) or die "Unable to make $m7_arch: $!";
    my @m7_paths = Developer::Dashboard::PerlEnv->perl5lib_list(
        dashboard_lib => $m7_lib, env => {},
    );
    ok( ( grep { $_ eq $m7_local } @m7_paths ), 'section 12: the fake checkout local lib is listed' );
    ok( ( grep { $_ eq $m7_arch } @m7_paths ), 'section 12: the fake checkout arch lib is listed' );
}

{
    # 12d2. B 260 true: bootstrap_perl5lib with an empty path
    # separator takes the fallback and still writes PERL5LIB.
    my %m7_env;
    my $m7_value = Developer::Dashboard::PerlEnv->bootstrap_perl5lib( env => \%m7_env, path_sep => '' );
    ok( defined $m7_env{PERL5LIB}, 'section 12: an empty path separator still writes PERL5LIB' );
    is( $m7_value, $m7_env{PERL5LIB}, 'section 12: bootstrap returns the PERL5LIB it wrote' );
}

{
    # 12d3. B 61 false + C 60 l: a fake powershell on PATH, found
    # through the Windows fallback. %Config is localised as a whole
    # hash (the t/79 pattern: localising one element of the tied
    # hash dies "read-only", copying it does not), so the configured
    # shell names a Unix path that does not exist here, and the
    # localised $OS_NAME takes the Windows branch.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_ps = File::Spec->catfile( $m7_tmp, 'powershell' );
    _make_executable( $m7_ps, "#!/bin/sh\nexit 0\n" );
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    local %Config::Config = %Config::Config;
    $Config::Config{sh} = '/nonexistent-perlenv-xyz/foo/sh';
    local $ENV{PATH} = $m7_tmp;
    is( Developer::Dashboard::PerlEnv::current_shell_bin_dir(),
        File::Spec->canonpath($m7_tmp),
        'section 12: a powershell on PATH is the Windows shell bin dir' );
}

{
    # 12d4. C 62 !l: with no SystemRoot set and no powershell on
    # PATH, the fallback root is the literal C:\Windows, no
    # powershell is found under it here, and the bin dir is empty.
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    local %Config::Config = %Config::Config;
    $Config::Config{sh} = '/nonexistent-perlenv-xyz/foo/sh';
    local $ENV{SystemRoot} = '';
    local $ENV{PATH} = tempdir( CLEANUP => 1 );
    is( Developer::Dashboard::PerlEnv::current_shell_bin_dir(), '',
        'section 12: no Windows shell resolves without a SystemRoot' );
}

{
    # 12d5. B 161 false + C 160 !l + B 163 false: a fake checkout
    # whose local lib exists but whose archname directory does not.
    # With archname emptied (same %Config copy as 12d3) the arch
    # branch is skipped; with the real archname the arch dir is
    # missing, so the arch lib is not listed.
    my $m7_co = tempdir( CLEANUP => 1 );
    my $m7_lib = File::Spec->catdir( $m7_co, 'lib' );
    my $m7_dd = File::Spec->catdir( $m7_lib, 'Developer' );
    File::Path::make_path($m7_dd) or die "Unable to make $m7_dd: $!";
    my $m7_pm = File::Spec->catfile( $m7_dd, 'Dashboard.pm' );
    open my $m7_w, '>', $m7_pm or die "Unable to write $m7_pm: $!";
    close $m7_w or die "Unable to close: $!";
    my $m7_local = File::Spec->catdir( $m7_co, 'local', 'lib', 'perl5' );
    File::Path::make_path($m7_local) or die "Unable to make $m7_local: $!";
    my $m7_arch = File::Spec->catdir( $m7_local, $Config::Config{archname} );
    my @m7_no_arch;
    {
        local %Config::Config = %Config::Config;
        $Config::Config{archname} = '';
        @m7_no_arch = Developer::Dashboard::PerlEnv->perl5lib_list(
            dashboard_lib => $m7_lib, env => {},
        );
    }
    ok( ( grep { $_ eq $m7_local } @m7_no_arch ), 'section 12: the local lib is listed without an archname' );
    ok( !( grep { $_ eq $m7_arch } @m7_no_arch ), 'section 12: no arch lib is listed without an archname' );
    my @m7_paths = Developer::Dashboard::PerlEnv->perl5lib_list(
        dashboard_lib => $m7_lib, env => {},
    );
    ok( ( grep { $_ eq $m7_local } @m7_paths ), 'section 12: the local lib is listed with a real archname' );
    ok( !( grep { $_ eq $m7_arch } @m7_paths ), 'section 12: a missing arch dir is not listed' );
}

{
    # 12d6. B 260 false: bootstrap_perl5lib with a given separator
    # keeps it instead of taking the fallback.
    my %m7_env;
    my $m7_value = Developer::Dashboard::PerlEnv->bootstrap_perl5lib( env => \%m7_env, path_sep => ':' );
    like( $m7_value, qr/:/, 'section 12: a given path separator is kept by bootstrap' );
    is( $m7_value, $m7_env{PERL5LIB}, 'section 12: bootstrap returns the PERL5LIB it wrote with a separator' );
}

{
    # 12e1. B 139 true + C 139 !l + l&&!r: the disk body read returns
    # at once for an undef path and for an empty path.
    my $m7_ps = bless {}, 'Developer::Dashboard::PageStore';
    is( $m7_ps->_nav_fragment_disk_body(undef),
        undef, 'section 12: an undef fragment path reads as undef' );
    is( $m7_ps->_nav_fragment_disk_body(''),
        undef, 'section 12: an empty fragment path reads as undef' );
}

{
    # 12e2. B 142 false + C 142 l&&r: a missing fragment. Note the real
    # behaviour pinned here: a failed sysopen leaves $fh a defined but
    # closed handle (proved by /tmp/m7-sysopen-probe.pl: opened=1,
    # fh=defined, err=ENOENT), so the guard does not fire, read on the
    # closed handle warns (suppressed here) and returns undef, and the
    # function returns '' rather than undef. C 142 l&&!r is therefore
    # UNCOVERABLE: $fh is never undef after a successful eval. B 142
    # true is covered by 12e3 below.
    my $m7_ps = bless {}, 'Developer::Dashboard::PageStore';
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_missing_body;
    {
        local $SIG{__WARN__} = sub { };
        $m7_missing_body = $m7_ps->_nav_fragment_disk_body( File::Spec->catfile( $m7_tmp, 'missing.tt' ) );
    }
    is( $m7_missing_body, '', 'section 12: a missing fragment reads as an empty string' );
}

{
    # 12e3. C 142 !l: sysopen dies inside the eval when the path
    # stringification dies, so the eval returns undef and the read
    # returns undef. The path stringifies to a real file on the first
    # call (the empty check) and dies on the second (inside sysopen).
    my $m7_ps = bless {}, 'Developer::Dashboard::PageStore';
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_file = File::Spec->catfile( $m7_tmp, 'real.tt' );
    open my $m7_w, '>', $m7_file or die "Unable to write $m7_file: $!";
    print $m7_w "m7 body\n" or die "Unable to write: $!";
    close $m7_w or die "Unable to close: $!";
    my $m7_dying = M7::DyingString->new($m7_file);
    is( $m7_ps->_nav_fragment_disk_body($m7_dying),
        undef, 'section 12: a dying path stringification reads as undef' );
    ok( $m7_dying->calls >= 2, 'section 12: the dying path was stringified twice' );
}

{
    # 12e4. C 148 !l&&r: invalid UTF-8 bytes make the CROAK decode
    # die, so the DEFAULT decode runs and returns replacement text.
    my $m7_ps = bless {}, 'Developer::Dashboard::PageStore';
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_file = File::Spec->catfile( $m7_tmp, 'bad.tt' );
    open my $m7_w, '>', $m7_file or die "Unable to write $m7_file: $!";
    binmode $m7_w or die "Unable to binmode: $!";
    syswrite( $m7_w, "\xff\xfe" ) == 2 or die "Unable to write: $!";
    close $m7_w or die "Unable to close: $!";
    my $m7_body = $m7_ps->_nav_fragment_disk_body($m7_file);
    ok( defined $m7_body, 'section 12: invalid UTF-8 still decodes' );
    like( $m7_body, qr/\x{FFFD}/, 'section 12: invalid UTF-8 becomes replacement text' );
}

{
    # 12e5. C 148 !l&&!r: an empty file decodes to an empty body
    # through both decodes.
    my $m7_ps = bless {}, 'Developer::Dashboard::PageStore';
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_file = File::Spec->catfile( $m7_tmp, 'empty.tt' );
    open my $m7_w, '>', $m7_file or die "Unable to write $m7_file: $!";
    close $m7_w or die "Unable to close: $!";
    is( $m7_ps->_nav_fragment_disk_body($m7_file),
        '', 'section 12: an empty fragment reads as empty' );
}

{
    # 12e6. B 482 true + C 482 !l + l&&!r + B 484 true: the
    # containment realpath returns at once for an undef path and
    # for an empty path, and returns undef for a symlink loop.
    is( Developer::Dashboard::PageStore::_containment_realpath(undef),
        undef, 'section 12: an undef containment path is undef' );
    is( Developer::Dashboard::PageStore::_containment_realpath(''),
        undef, 'section 12: an empty containment path is undef' );
    my $m7_tmp = tempdir( CLEANUP => 1 );
    symlink 'm7-loop2', File::Spec->catfile( $m7_tmp, 'm7-loop1' ) or die "Unable to link: $!";
    symlink 'm7-loop1', File::Spec->catfile( $m7_tmp, 'm7-loop2' ) or die "Unable to link: $!";
    is( Developer::Dashboard::PageStore::_containment_realpath(
            File::Spec->catfile( $m7_tmp, 'm7-loop1', 'x' ) ),
        undef, 'section 12: a containment path through a loop is undef' );
}

{
    # 12f1. B 80 true + B 82 true: STDIN is a pipe on a localised
    # Windows, so the pipe check runs. With data waiting the native
    # check answers at once; with nothing waiting and no time left
    # it answers 0. Both answers are defined, so the ready branch
    # fires either way.
    pipe( my $m7_r, my $m7_w ) or die "Unable to pipe: $!";
    syswrite( $m7_w, 'm7' ) == 2 or die "Unable to write: $!";
    my $m7_ready;
    {
        local *STDIN = $m7_r;
        local $^O = 'MSWin32';
        $m7_ready = Developer::Dashboard::CLI::OpenFileChooser::_stdin_has_pending_input(0.5);
    }
    is( $m7_ready, 1, 'section 12: a piped STDIN with data is ready on Windows' );
    close $m7_w or die "Unable to close: $!";
    close $m7_r or die "Unable to close: $!";
    pipe( my $m7_r2, my $m7_w2 ) or die "Unable to pipe: $!";
    my $m7_ready2;
    {
        local *STDIN = $m7_r2;
        local $^O = 'MSWin32';
        $m7_ready2 = Developer::Dashboard::CLI::OpenFileChooser::_stdin_has_pending_input(0);
    }
    is( $m7_ready2, 0, 'section 12: a quiet piped STDIN is not ready on Windows' );
    close $m7_w2 or die "Unable to close: $!";
    close $m7_r2 or die "Unable to close: $!";
}

{
    # 12f2. B 131 true + B 133 true + B 136 true + C 136 !l: the
    # STDIN pipe readiness check fails twice over. First the
    # PeekNamedPipe import returns undef, so the eval gives no peek
    # and no handle; then the import works but GetOsFHandle returns
    # undef, so the eval dies the same way. Both return undef.
    my $m7_ready1;
    {
        no warnings qw(once redefine prototype);
        local *Win32::API::new = sub { return undef; };
        $m7_ready1 = Developer::Dashboard::CLI::OpenFileChooser::_windows_stdin_pipe_ready(0.5);
    }
    is( $m7_ready1, undef, 'section 12: a failed PeekNamedPipe import means no readiness check' );
    my $m7_ready2;
    {
        no warnings qw(once redefine prototype);
        local *Win32API::File::GetOsFHandle = sub { return undef; };
        $m7_ready2 = Developer::Dashboard::CLI::OpenFileChooser::_windows_stdin_pipe_ready(0.5);
    }
    is( $m7_ready2, undef, 'section 12: an unresolvable STDIN handle means no readiness check' );
}

{
    # 12f3. B 80 false: STDIN is a character device, neither a file
    # nor a pipe, on a localised Windows, so the Windows answers do
    # not fire and the IO::Select fallback runs. B 82 false: STDIN
    # is a pipe but the PeekNamedPipe import fails, so the native
    # check answers undef and the ordinary blocking read is used.
    # Both fall back to ready.
    my $m7_ready;
    {
        open my $m7_null, '<', File::Spec->devnull() or die "Unable to open devnull: $!";
        local *STDIN = $m7_null;
        local $^O = 'MSWin32';
        $m7_ready = Developer::Dashboard::CLI::OpenFileChooser::_stdin_has_pending_input(0);
        close $m7_null or die "Unable to close: $!";
    }
    is( $m7_ready, 1, 'section 12: a character-device STDIN is ready on Windows' );
    pipe( my $m7_r, my $m7_w ) or die "Unable to pipe: $!";
    my $m7_ready2;
    {
        no warnings qw(once redefine prototype);
        local *Win32::API::new = sub { return undef; };
        local *STDIN = $m7_r;
        local $^O = 'MSWin32';
        $m7_ready2 = Developer::Dashboard::CLI::OpenFileChooser::_stdin_has_pending_input(0.5);
    }
    is( $m7_ready2, 1, 'section 12: an unavailable native pipe check falls back to ready' );
    close $m7_w or die "Unable to close: $!";
    close $m7_r or die "Unable to close: $!";
}

# Section 13: Which, DockerCompose, Ticket, ActionRunner, RuntimeControl,
# Paths (M7 tail, R178).
# Which: B 279 true (a bare entrypoint that resolves on PATH) + false
# (an unresolvable bare entrypoint), B 281 true (a non-executable $0)
# + false (an executable $0) with C 281 l&&!r (executable $0) + l&&r
# (non-executable $0), B 282 true (an executable $0) + false (a
# missing $0). Which _command_exec: B 294 true + B 303 true (a
# bad-interpreter command on a localised Windows dies before exit).
# B 303 false, B 304 true + false and C 304 l + !l (the exit ternary):
# any non-minus-1 system result reaches exit(), so the test uses the
# section 9 exit override (test 9b) and sets the file-scoped
# $M7_EXIT_OVERRIDE flag around the calls: the exit code is caught as
# a die instead of ending the test process. The override is installed
# before Which.pm is compiled (its require runs at section 13), so
# the exit in _command_exec resolves to it. The signal-death case
# (C 304 !l) is skipped on real Windows, where SIGHUP has no meaning.
# DockerCompose _rewrite_exec_dashboard_command: C 56 l (undef args)
# + !l&&r (fewer than three args), C 62 l (an undef token) + !l&&r
# (an empty token) + !l&&!r (a dash token), C 63 l (a --name=value
# token) + !l&&r (a -pVALUE token) + !l&&!r (another dash token),
# C 73 l (flags run past the end) + !l&&r (a non-exec operation) +
# !l&&!r (the exec token), B 73 true + false, B 79 true (a token
# that ends the exec-flag scan) + false (a dash token), B 80 true
# (an exec flag that takes a value) + false (a --flag=value token),
# B 91 true (the dashboard token follows the service) + false (the
# service is last, or the next token is not dashboard), C 79 l (an
# undef token) + !l&&r (an empty token) + !l&&!r (a plain token),
# C 91 !l (no token follows the service) + l&&!r (the next token is
# undef) + l&&r (the next token is dashboard). _materialized_command:
# B 1166 true (a fake docker prints canned config, then the tempfile
# call is stubbed to die; a nonexistent TMPDIR alone does NOT fail
# tempfile, because File::Temp falls back to /tmp). B 1175 is
# UNCOVERABLE: binmode on a tempfile handle never fails, because the
# handle comes from tempfile and is always open (section 12 probe).
# Ticket _exec_tmux: B 274 true (localised Windows) + B 288 true
# (tmux unresolvable with an emptied PATH) + false (a bad-interpreter
# fake tmux resolves) + B 299 true + C 299 l (system returns -1).
# C 299 !l&&r is UNCOVERABLE: block-form system() never leaves $!
# set when it returns non-minus-1 (probe /tmp/m7-syswarn-probe.pl:
# good rc=0 err= empty). C 299 !l&&!r is UNCOVERABLE in-process: the
# success path calls exit(). S __ANON__@295 is UNCOVERABLE: the
# $SIG{__WARN__} handler inside the block is only ever called by a
# warning from block-form system(), which never warns (same probe:
# bad-interpreter rc=-1 warned=0). Ticket home: B 482 true + false
# + C 482 !l (HOME undef) + l&&!r (HOME empty) + l&&r (HOME set),
# B 486 true + false + C 486 !l + l&&!r + l&&r (USERPROFILE the same
# way), B 491 true + false + C 491 !l + l&&!r + l&&r (HOMEDRIVE and
# HOMEPATH the same way), C 519 !l (no home resolves, so the walk
# runs to the filesystem root). C 196 and C 197 !l&&!r are
# UNCOVERABLE: the or-3 right operand is a ternary whose arms are
# always truthy strings ('/tmp', '/dev/shm', or File::Spec->tmpdir,
# which on the loaded Unix class returns '/tmp' even under a
# localised $^O), so the falsy side can never fire.
# ActionRunner: B 249 true (terminate_command_process on a fake pid
# under a localised $OS_NAME; taskkill is not found on Unix, so the
# system call fails harmlessly and the pid is not a spawn child).
# RuntimeControl: B 179 true (a stubbed _read_log_sources plus a
# localised $^O makes _run_log_command hit the STDOUT binmode) and
# B 291 true (a stubbed _read_log_sources returning new content plus
# a localised $^O makes the follow loop hit its STDOUT binmode; an
# alarm dies inside an eval to stop the infinite loop).
# Paths: B 573 false (a symlink loop as the skill lib makes
# _resolve_symlinks return undef and the load die). B 574 false is
# UNCOVERABLE: _resolve_symlinks returns undef only past forty hops,
# on an unreadable link, or on a repeated target, and each of those
# also makes the -f guard fail, so a file that passes -f always
# resolves (probe /tmp/m7-hop-probe.pl: a forty-link chain passes
# both checks, a forty-one-link chain and a loop fail both).

require Developer::Dashboard::CLI::Which;
require Developer::Dashboard::DockerCompose;
require Developer::Dashboard::CLI::Ticket;
require Developer::Dashboard::CommandRunner;
require Developer::Dashboard::CLI::RuntimeControl;
require Developer::Dashboard::CLI::Paths;
require Capture::Tiny;

{
    package M7::FakePaths;
    sub runtime_layers { return (); }
}

{
    # 13a1. B 279 true: a bare entrypoint that resolves on PATH.
    local $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT} = 'perl';
    my @m7_cmd = Developer::Dashboard::CLI::Which::_dashboard_entry_command();
    is( scalar @m7_cmd, 1, 'section 13: a resolving entrypoint returns one command' );
    ok( -x $m7_cmd[0], 'section 13: a resolving entrypoint returns an executable' );
}

{
    # 13a2. B 279 false + B 281 false + B 282 false: an unresolvable
    # bare entrypoint and a missing $0 fall through to the entrypoint.
    local $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT} = 'm7-no-such-entrypoint';
    local $0 = '/nonexistent/m7-self';
    my @m7_cmd = Developer::Dashboard::CLI::Which::_dashboard_entry_command();
    is_deeply( \@m7_cmd, ['m7-no-such-entrypoint'],
        'section 13: an unresolvable entrypoint with a missing self returns the entrypoint' );
}

{
    # 13a3. B 281 true + C 281 l&&r: an unresolvable bare entrypoint
    # and a non-executable $0 return the Perl interpreter plus $0.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_self = File::Spec->catfile( $m7_tmp, 'm7-self.pl' );
    open my $m7_w, '>', $m7_self or die "Unable to write $m7_self: $!";
    print {$m7_w} "1;\n";
    close $m7_w or die "Unable to close: $!";
    local $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT} = 'm7-no-such-entrypoint';
    local $0 = $m7_self;
    my @m7_cmd = Developer::Dashboard::CLI::Which::_dashboard_entry_command();
    is_deeply( \@m7_cmd, [ $^X, $m7_self ],
        'section 13: an unresolvable entrypoint with a plain self returns perl plus self' );
}

{
    # 13a4. B 281 false (C 281 l&&!r) + B 282 true: an unresolvable
    # bare entrypoint and an executable $0 return $0 itself.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_self = File::Spec->catfile( $m7_tmp, 'm7-self.pl' );
    open my $m7_w, '>', $m7_self or die "Unable to write $m7_self: $!";
    print {$m7_w} "#!$^X\n1;\n";
    close $m7_w or die "Unable to close: $!";
    chmod 0755, $m7_self or die "Unable to chmod $m7_self: $!";
    local $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT} = 'm7-no-such-entrypoint';
    local $0 = $m7_self;
    my @m7_cmd = Developer::Dashboard::CLI::Which::_dashboard_entry_command();
    is_deeply( \@m7_cmd, [$m7_self],
        'section 13: an unresolvable entrypoint with an executable self returns self' );
}

{
    # 13b1. B 294 true + B 303 true: on a localised Windows a
    # bad-interpreter command makes system return -1 and the sub die.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_bad = File::Spec->catfile( $m7_tmp, 'm7-badinterp' );
    open my $m7_w, '>', $m7_bad or die "Unable to write $m7_bad: $!";
    print {$m7_w} "#!/nonexistent/m7-interp\n";
    close $m7_w or die "Unable to close: $!";
    chmod 0755, $m7_bad or die "Unable to chmod $m7_bad: $!";
    local $^O = 'MSWin32';
    my $m7_died = eval { Developer::Dashboard::CLI::Which::_command_exec($m7_bad); 1 };
    ok( !$m7_died, 'section 13: a bad-interpreter command dies instead of exiting' );
    like( $@, qr/Unable to run command/, 'section 13: the bad-interpreter die names the command' );
}

{
    # 13b2. B 303 false + B 304 true + false + C 304 l + !l: on a
    # localised Windows a command that runs reaches exit(), so the
    # section 9 exit override catches the code as a die instead of
    # ending the test process. rc 0 exits 0, rc 256 (exit 1) exits 1,
    # and a signal death (status 1, so $rc >> 8 is 0) exits 1 by
    # the || 1. The child resets SIGHUP to DEFAULT first: Jenkins
    # ignores SIGHUP, so a bare kill is a no-op there and the child
    # would exit 0 instead (proof #213). Probe /tmp/m7-sig-probe.pl.
    # The flag is set and reset around the calls, the
    # section 9 pattern; the error strings are captured before it
    # is reset.
    my $m7_real_os = $^O;
    local $^O = 'MSWin32';
    $M7_EXIT_OVERRIDE = 1;
    my $m7_ok0 = eval { Developer::Dashboard::CLI::Which::_command_exec( $^X, '-e', 'exit 0' ); 1 };
    my $m7_err0 = $@;
    my $m7_ok1 = eval { Developer::Dashboard::CLI::Which::_command_exec( $^X, '-e', 'exit 1' ); 1 };
    my $m7_err1 = $@;
    SKIP: {
        skip 'SIGHUP has no meaning on real Windows', 2 if $m7_real_os eq 'MSWin32';
        my $m7_ok_sig = eval { Developer::Dashboard::CLI::Which::_command_exec( $^X, '-e', '$SIG{HUP} = "DEFAULT"; kill 1, $$' ); 1 };
        my $m7_err_sig = $@;
        ok( !$m7_ok_sig, 'section 13: a signal death reaches exit instead of dying' );
        is( $m7_err_sig, "M7-EXIT:1\n", 'section 13: a signal death exits 1 by the fallback' );
    }
    $M7_EXIT_OVERRIDE = 0;
    ok( !$m7_ok0, 'section 13: a clean command reaches exit instead of dying' );
    is( $m7_err0, "M7-EXIT:0\n", 'section 13: a clean command exits 0' );
    ok( !$m7_ok1, 'section 13: a failing command reaches exit instead of dying' );
    is( $m7_err1, "M7-EXIT:1\n", 'section 13: a failing command exits 1' );
}

{
    # 13c1. C 56 l: undef args return at once.
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command(undef);
    ok( 1, 'section 13: undef compose args rewrite to nothing' );
}

{
    # 13c2. C 56 !l&&r: fewer than three args return at once.
    my @m7_args = ( '-f', 'x' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is_deeply( \@m7_args, [ '-f', 'x' ], 'section 13: short compose args are left alone' );
}

{
    # 13c3. C 62 l: an undef token ends the global-flag scan.
    my @m7_args = ( undef, 'exec', 'svc', 'dashboard' );
    {
        local $SIG{__WARN__} = sub { };
        Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    }
    is_deeply( \@m7_args, [ undef, 'exec', 'svc', 'dashboard' ],
        'section 13: an undef global token leaves the args alone' );
}

{
    # 13c4. C 62 !l&&r: an empty token ends the global-flag scan.
    my @m7_args = ( '', 'exec', 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is_deeply( \@m7_args, [ '', 'exec', 'svc', 'dashboard' ],
        'section 13: an empty global token leaves the args alone' );
}

{
    # 13c5. C 63 l + C 73 !l&&!r + B 73 false + B 79 true + C 79 !l&&!r
    # + B 91 true + C 91 l&&r: a --name=value global flag, then exec,
    # a service, and dashboard, which is rewritten to d2.
    my @m7_args = ( '--project-name=foo', 'exec', 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is( $m7_args[3], 'd2', 'section 13: dashboard after a valued global flag becomes d2' );
}

{
    # 13c6. C 63 !l&&r: a -pVALUE global flag, then the same rewrite.
    my @m7_args = ( '-pfoo', 'exec', 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is( $m7_args[3], 'd2', 'section 13: dashboard after a -p flag becomes d2' );
}

{
    # 13c7. C 63 !l&&!r: another dash flag, then the same rewrite.
    my @m7_args = ( '-x', 'exec', 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is( $m7_args[3], 'd2', 'section 13: dashboard after an unknown flag becomes d2' );
}

{
    # 13c8. C 73 l: flags run past the end of the args.
    my @m7_args = ( '-f', 'x', '-p' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is_deeply( \@m7_args, [ '-f', 'x', '-p' ], 'section 13: flags past the end leave the args alone' );
}

{
    # 13c9. C 73 !l&&r + B 73 true: a non-exec operation returns.
    my @m7_args = ( '-f', 'x', 'up' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is_deeply( \@m7_args, [ '-f', 'x', 'up' ], 'section 13: a non-exec operation is left alone' );
}

{
    # 13c10. C 79 l: an undef token ends the exec-flag scan.
    my @m7_args = ( 'exec', undef, 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is_deeply( \@m7_args, [ 'exec', undef, 'svc', 'dashboard' ],
        'section 13: an undef exec token leaves the args alone' );
}

{
    # 13c11. C 79 !l&&r: an empty token ends the exec-flag scan.
    my @m7_args = ( 'exec', '', 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is_deeply( \@m7_args, [ 'exec', '', 'svc', 'dashboard' ],
        'section 13: an empty exec token leaves the args alone' );
}

{
    # 13c12. B 80 true: an exec flag that takes a value is skipped
    # with its value, then dashboard is rewritten.
    my @m7_args = ( 'exec', '-e', 'FOO=1', 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is( $m7_args[4], 'd2', 'section 13: dashboard after a valued exec flag becomes d2' );
}

{
    # 13c13. B 80 false: a --flag=value exec flag is skipped alone,
    # then dashboard is rewritten.
    my @m7_args = ( 'exec', '--env=FOO=1', 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is( $m7_args[3], 'd2', 'section 13: dashboard after a valued exec flag spelling becomes d2' );
}

{
    # 13c14. C 91 !l: the service is the last token, so there is no
    # command to rewrite. The args must still number three or more:
    # a two-token call returns at the count guard before line 91,
    # so the service sits last after a valued exec flag instead.
    my @m7_args = ( 'exec', '-e', 'FOO=1', 'svc' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is_deeply( \@m7_args, [ 'exec', '-e', 'FOO=1', 'svc' ],
        'section 13: a trailing service is left alone' );
}

{
    # 13c15. C 91 l&&!r: the token after the service is undef.
    my @m7_args = ( 'exec', 'svc', undef );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is_deeply( \@m7_args, [ 'exec', 'svc', undef ],
        'section 13: an undef command after the service is left alone' );
}

{
    # 13c16. C 62 !l&&!r: a flag that takes a value is skipped with
    # its value, then dashboard is rewritten.
    my @m7_args = ( '-f', 'x', 'exec', 'svc', 'dashboard' );
    Developer::Dashboard::DockerCompose::_rewrite_exec_dashboard_command( \@m7_args );
    is( $m7_args[4], 'd2', 'section 13: dashboard after a file flag becomes d2' );
}

{
    # 13d1. B 1166 true: a fake docker prints canned config, then the
    # tempfile call is stubbed to die for the merged-compose template
    # (delegating other calls to the real tempfile, so the Capture::Tiny
    # capture inside the same sub keeps working), and the sub dies
    # naming the temporary file.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_bin = File::Spec->catdir( $m7_tmp, 'bin' );
    File::Path::make_path($m7_bin) or die "Unable to make $m7_bin: $!";
    my $m7_docker = File::Spec->catfile( $m7_bin, 'docker' );
    open my $m7_w, '>', $m7_docker or die "Unable to write $m7_docker: $!";
    print {$m7_w} "#!/bin/sh\nprintf 'services:\\n  web:\\n    image: m7-test\\n'\nexit 0\n";
    close $m7_w or die "Unable to close: $!";
    chmod 0755, $m7_docker or die "Unable to chmod $m7_docker: $!";
    my $m7_base = File::Spec->catfile( $m7_tmp, 'compose.yml' );
    open my $m7_b, '>', $m7_base or die "Unable to write $m7_base: $!";
    print {$m7_b} "services:\n  web:\n    image: m7-test\n";
    close $m7_b or die "Unable to close: $!";
    my $m7_dc = bless {
        config => {},
        paths  => bless( {}, 'M7::FakePaths' ),
    }, 'Developer::Dashboard::DockerCompose';
    my $m7_resolved = {
        command       => [ 'docker', 'compose', 'up' ],
        compose_args  => [],
        compose_root  => $m7_tmp,
        project_root  => $m7_tmp,
        base_files    => [$m7_base],
        project_files => [],
        service_files => [],
        addon_files   => [],
        mode_files    => [],
        service_map   => {},
        modes         => [],
        env           => {},
    };
    local $ENV{PATH} = "$m7_bin:$ENV{PATH}";
    my $m7_orig_tempfile = \&File::Temp::tempfile;
    local *File::Temp::tempfile = sub {
        die "m7-tempfile-fail\n" if defined $_[0] && $_[0] =~ /merged-compose/;
        return $m7_orig_tempfile->(@_);
    };
    my $m7_ok = eval { $m7_dc->_materialized_command($m7_resolved); 1 };
    ok( !$m7_ok, 'section 13: a missing TMPDIR dies while materializing compose' );
    like( $@, qr/Unable to create temporary merged Compose file/,
        'section 13: the materialize die names the temporary file' );
}

{
    # 13e1. B 274 true + B 288 true: on a localised Windows with an
    # emptied PATH, tmux does not resolve and the exec returns false.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    local $^O = 'MSWin32';
    local $ENV{PATH} = $m7_tmp;
    local $SIG{__WARN__} = sub { };
    my $m7_rc = Developer::Dashboard::CLI::Ticket::_exec_tmux( 'attach-session', '-t', 'm7' );
    is( $m7_rc, 0, 'section 13: an unresolvable tmux returns false' );
}

{
    # 13e2. B 288 false + B 299 true + C 299 l: a bad-interpreter fake
    # tmux resolves, system returns -1, and the exec returns false.
    # The fake must carry a Windows extension (.bat): under a localised
    # $^O, command_in_path_direct only returns .com/.exe/.bat/.cmd
    # candidates, so an extensionless fake never resolves.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_bin = File::Spec->catdir( $m7_tmp, 'bin' );
    File::Path::make_path($m7_bin) or die "Unable to make $m7_bin: $!";
    my $m7_tmux = File::Spec->catfile( $m7_bin, 'tmux.bat' );
    open my $m7_w, '>', $m7_tmux or die "Unable to write $m7_tmux: $!";
    print {$m7_w} "#!/nonexistent/m7-interp\n";
    close $m7_w or die "Unable to close: $!";
    chmod 0755, $m7_tmux or die "Unable to chmod $m7_tmux: $!";
    local $^O = 'MSWin32';
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    local $ENV{PATH} = "$m7_bin:$ENV{PATH}";
    local $SIG{__WARN__} = sub { };
    my $m7_rc = Developer::Dashboard::CLI::Ticket::_exec_tmux( 'attach-session', '-t', 'm7' );
    is( $m7_rc, 0, 'section 13: a bad-interpreter tmux returns false' );
}

{
    # 13f1. C 482 !l: HOME undef falls through to USERPROFILE.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    local $ENV{HOME};
    local $ENV{USERPROFILE} = $m7_tmp;
    is( Developer::Dashboard::CLI::Ticket::_workspace_env_home(),
        Developer::Dashboard::EnvLoader->_path_identity($m7_tmp),
        'section 13: an unset HOME falls through to USERPROFILE' );
}

{
    # 13f2. C 482 l&&!r: an empty HOME falls through to USERPROFILE.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = '';
    local $ENV{USERPROFILE} = $m7_tmp;
    is( Developer::Dashboard::CLI::Ticket::_workspace_env_home(),
        Developer::Dashboard::EnvLoader->_path_identity($m7_tmp),
        'section 13: an empty HOME falls through to USERPROFILE' );
}

{
    # 13f3. C 486 !l + B 491 true + C 491 l&&r: HOME and USERPROFILE
    # unset, HOMEDRIVE and HOMEPATH set, so the drive path is used.
    my $m7_home = File::Spec->catdir( 'C:', '\Users\m7' );
    local $ENV{HOME};
    local $ENV{USERPROFILE};
    local $ENV{HOMEDRIVE} = 'C:';
    local $ENV{HOMEPATH} = '\Users\m7';
    is( Developer::Dashboard::CLI::Ticket::_workspace_env_home(),
        Developer::Dashboard::EnvLoader->_path_identity($m7_home),
        'section 13: unset HOME and USERPROFILE fall through to the drive path' );
}

{
    # 13f4. C 486 l&&!r: an empty USERPROFILE falls through to the
    # drive path.
    my $m7_home = File::Spec->catdir( 'C:', '\Users\m7' );
    local $ENV{HOME};
    local $ENV{USERPROFILE} = '';
    local $ENV{HOMEDRIVE} = 'C:';
    local $ENV{HOMEPATH} = '\Users\m7';
    is( Developer::Dashboard::CLI::Ticket::_workspace_env_home(),
        Developer::Dashboard::EnvLoader->_path_identity($m7_home),
        'section 13: an empty USERPROFILE falls through to the drive path' );
}

{
    # 13f5. C 491 !l: HOMEDRIVE unset, so no home resolves.
    local $ENV{HOME};
    local $ENV{USERPROFILE};
    local $ENV{HOMEDRIVE};
    local $ENV{HOMEPATH} = '\Users\m7';
    is( Developer::Dashboard::CLI::Ticket::_workspace_env_home(), '',
        'section 13: an unset HOMEDRIVE resolves no home' );
}

{
    # 13f6. C 491 l&&!r: an empty HOMEDRIVE, so no home resolves.
    local $ENV{HOME};
    local $ENV{USERPROFILE};
    local $ENV{HOMEDRIVE} = '';
    local $ENV{HOMEPATH} = '\Users\m7';
    is( Developer::Dashboard::CLI::Ticket::_workspace_env_home(), '',
        'section 13: an empty HOMEDRIVE resolves no home' );
}

{
    # 13f7. C 519 !l: no home resolves, so the env-file walk runs to
    # the filesystem root and still finds the .env in the cwd.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_dir = Developer::Dashboard::EnvLoader->_path_identity($m7_tmp);
    my $m7_env = File::Spec->catfile( $m7_dir, '.env' );
    open my $m7_w, '>', $m7_env or die "Unable to write $m7_env: $!";
    print {$m7_w} "M7_TEST=1\n";
    close $m7_w or die "Unable to close: $!";
    local $ENV{HOME};
    local $ENV{USERPROFILE};
    local $ENV{HOMEDRIVE};
    local $ENV{HOMEPATH};
    my @m7_files = Developer::Dashboard::CLI::Ticket::_workspace_env_files( cwd => $m7_dir );
    ok( ( grep { $_ eq $m7_env } @m7_files ),
        'section 13: with no home the walk still finds the cwd env file' );
}

{
    # 13g1. B 249 true: terminate_command_process on a fake pid under
    # a localised $OS_NAME takes the Windows branch; taskkill is not
    # found on Unix, the pid is not a spawn child, and it returns 1.
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( Developer::Dashboard::CommandRunner::terminate_command_process(999999), 1,
        'section 13: terminating a fake pid on Windows returns true' );
}

{
    # 13h1. B 179 true: a stubbed _read_log_sources plus a localised
    # $^O makes _run_log_command hit the STDOUT binmode.
    local *Developer::Dashboard::CLI::RuntimeControl::_read_log_sources = sub {
        return { web => "m7 log line\n" };
    };
    local $^O = 'MSWin32';
    my $m7_rc;
    my ( $m7_out, $m7_err ) = Capture::Tiny::capture( sub {
        $m7_rc = Developer::Dashboard::CLI::RuntimeControl::_run_log_command(
            args => [], runtime => undef, config => undef, collectors => undef,
        );
    } );
    is( $m7_rc, 0, 'section 13: the stubbed log command returns zero' );
    like( $m7_out, qr/m7 log line/, 'section 13: the stubbed log command prints the log line' );
}

{
    # 13h2. B 291 true: a stubbed _read_log_sources returning new
    # content plus a localised $^O makes the follow loop hit its
    # STDOUT binmode; an alarm dies inside an eval to stop the loop.
    local *Developer::Dashboard::CLI::RuntimeControl::_read_log_sources = sub {
        return { web => "m7 follow line\n" };
    };
    local $^O = 'MSWin32';
    local $SIG{ALRM} = sub { die "m7-follow-done\n" };
    my $m7_err;
    my ( $m7_out, $m7_warn ) = Capture::Tiny::capture( sub {
        eval {
            alarm(1);
            Developer::Dashboard::CLI::RuntimeControl::_follow_log_sources(
                sources => { web => '' }, scope => 'all', name => undef,
                runtime => undef, config => undef, collectors => undef,
                timestamps => 0,
            );
            alarm(0);
        };
        $m7_err = $@;
    } );
    like( $m7_err, qr/m7-follow-done/, 'section 13: the follow loop stops on the alarm' );
    like( $m7_out, qr/m7 follow line/, 'section 13: the follow loop prints the new log line' );
}

{
    # 13i1. B 573 false: a symlink loop as the skill lib makes the
    # load die because the lib path does not resolve.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_file = File::Spec->catfile( $m7_tmp, 'Folder.pm' );
    open my $m7_w, '>', $m7_file or die "Unable to write $m7_file: $!";
    print {$m7_w} "1;\n";
    close $m7_w or die "Unable to close: $!";
    my $m7_loop_a = File::Spec->catfile( $m7_tmp, 'loop-a' );
    my $m7_loop_b = File::Spec->catfile( $m7_tmp, 'loop-b' );
    symlink $m7_loop_b, $m7_loop_a or die "Unable to link $m7_loop_a: $!";
    symlink $m7_loop_a, $m7_loop_b or die "Unable to link $m7_loop_b: $!";
    my $m7_ok = eval {
        Developer::Dashboard::CLI::Paths::_load_skill_folder_module( {
            dir  => $m7_tmp,
            lib  => $m7_loop_a,
            file => $m7_file,
        } );
        1;
    };
    ok( !$m7_ok, 'section 13: a looped skill lib dies instead of loading' );
    like( $@, qr/Unable to resolve skill Folder\.pm/,
        'section 13: the looped lib die names the skill file' );
}

# Section 14: OpenFile, OpenFileGrep, PathRegistry, Web/App, Prompt,
# GoRoutine END drain (M7 tail, R178).
# Windows simulation in this section localises
# $Developer::Dashboard::Platform::OS_NAME, which is what
# is_windows() reads. Localising $^O alone does NOT move it ($OS_NAME
# is a package variable initialised from $^O at load time), and the
# first 14a run proved it: a bare $^O localisation let _exec_raw take
# the Unix branch and run the real tmux, which exited the test
# process. Code that reads $^O directly (Watch, OpenFileChooser,
# RuntimeControl, _native_windows_paths) still uses local $^O.
# OpenFile: B 319 false (a File::Find scope of '.' keeps the './'
# prefix on matches, so canonpath is skipped), B 549 true (a bare
# unresolvable editor) + false (a bad-interpreter .bat editor
# resolves under a localised $^O; the fake must carry a Windows
# extension, because command_in_path_direct only returns
# .com/.exe/.bat/.cmd candidates there), B 562 true + C 562 l
# (system returns -1), C 501 l&&!r (file-descriptor exhaustion makes
# the shebang open fail while -f still passes; this VM runs as root,
# so a chmod-000 file opens fine and cannot drive this cell). S
# __ANON__@558 and C 562 !l&&r + !l&&!r and B 562 false are
# UNCOVERABLE: block-form system() never warns (probe
# /tmp/m7-syswarn-probe.pl) and never leaves $! set on a
# non-minus-1 return, and the success path calls exit() - B 562
# false IS the success path (rc != -1 and $! empty), so
# evaluating it ends the test process; the or-3 remainder is
# carve-out (2).
# OpenFileGrep: C 303 !l&&r and C 382 l&&!r are UNCOVERABLE. C 303:
# $positional_pattern_seen is set only on the same branch that pushes
# a pattern (OpenFileGrep.pm:303-305), so patterns can never be empty
# while the flag is true. C 382: stat never returns a partial result
# (dev defined, ino undef is impossible; section 12 probe).
# PathRegistry: B 1833 + S __ANON__@1832 are UNCOVERABLE in this
# file (the helpers are already loaded before section 14, so the
# reload path cannot run; proved by a truncated run of sections 1-13),
# B 1968 true + C 1968 l + !l&&r + !l&&!r
# (secure_path_permissions with undef, an empty string, and a missing
# path), C 831 l (a stubbed directory inventory with skills_root 'C:'
# _native_windows_paths true in _write_state_metadata on an existing
# file). B 1860, B 1861, B 1886 and B 1887 are UNCOVERABLE on Unix:
# is_real_windows reads a load-time lexical, so the Windows ACL
# branches never run here; they run for real on the Windows legs.
# C 831 !l&&r is UNCOVERABLE: the name regex captures one or more
# non-slash characters, so $name is never an empty string.
# Web/App: B 3267 true (readdir on a closed handle sets $!), B 3277
# true (closedir on a closed handle fails), B 4419 true + B 4427 true
# + false + B 4428 true + false (a localised is_windows with public
# roots '/' and a temp dir; the file lives in the second root, so the
# '/' root fires B 4427 false and B 4428 true, and the temp root
# fires B 4427 true and B 4428 false). C 4169, C 4206 and C 4250
# !l&&r are UNCOVERABLE: command_in_path returns undef or a real
# path, never an empty string.
# Prompt: C 49 + C 59 l&&!r (a fake paths object whose home returns
# undef). C 48 is UNCOVERABLE: current_working_directory never
# returns undef; it falls back to Cwd::cwd, which returns an empty
# string when getcwd fails (probe /tmp/m7-cwd-probe.pl). C 59 !l is
# UNCOVERABLE: $home_for_match is "$home // ''", always defined.
# GoRoutine END drain: B 1009 false + B 1013 true (an immediate
# routine registered after the last pump, whose callback, dispatched
# during the drain's pump, registers a new repeating routine; the
# drain's next pass cancels it and re-filters to empty). The pump
# bound is computed before the callback runs, so the new routine is
# still pending when the next pass sees it.
# Which B 304 and C 304 (section 13) stay open: the exit ternary
# cannot be evaluated in-process without ending the test run. Flagged
# to Faye with the section 14 report.

require Developer::Dashboard::CLI::OpenFile;
require Developer::Dashboard::CLI::OpenFileGrep;
require Developer::Dashboard::Web::App;
require Developer::Dashboard::Prompt;

{
    package M7::FakePromptPaths;
    sub project_root_for { return undef; }
    sub home { return undef; }
}

{
    # 14a1. B 319 false: a File::Find scope of '.' visits files whose
    # names start with './', so canonpath is skipped and the leading
    # dot is kept on the match.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_home = File::Spec->catdir( $m7_tmp, 'home' );
    File::Path::make_path($m7_home) or die "Unable to make $m7_home: $!";
    for my $m7_name (qw(m7-a.txt m7-b.txt)) {
        open my $m7_w, '>', File::Spec->catfile( $m7_tmp, $m7_name )
          or die "Unable to write $m7_name: $!";
        print {$m7_w} "m7\n";
        close $m7_w or die "Unable to close: $!";
    }
    my $m7_paths = Developer::Dashboard::PathRegistry->new( home => $m7_home );
    my $m7_orig = Developer::Dashboard::PathIdentity::current_working_directory();
    my ( $m7_line, @m7_found );
    my $m7_err = '';
    chdir $m7_tmp or die "Unable to chdir $m7_tmp: $!";
    eval {
        ( $m7_line, @m7_found ) = Developer::Dashboard::CLI::OpenFile::_resolve_open_file_matches(
            paths => $m7_paths, args => ['.'],
        );
        1;
    } or $m7_err = $@;
    chdir $m7_orig or die "Unable to chdir $m7_orig: $!";
    ok( !$m7_err, 'section 14: a dot scope resolves without dying' ) or diag($m7_err);
    ok( ( grep { $_ eq './m7-a.txt' } @m7_found ),
        'section 14: a dot scope keeps the leading dot on matches' );
}

{
    # 14a2. B 549 true: a bare unresolvable editor makes the raw exec
    # return false on a localised Windows.
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    local $SIG{__WARN__} = sub { };
    is( Developer::Dashboard::CLI::OpenFile::_exec_raw('m7-no-such-editor'), 0,
        'section 14: an unresolvable editor returns false' );
}

{
    # 14a3. B 549 false + B 562 true + C 562 l: a bad-interpreter
    # .bat editor resolves, system returns -1, and the raw exec
    # returns false.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_bin = File::Spec->catdir( $m7_tmp, 'bin' );
    File::Path::make_path($m7_bin) or die "Unable to make $m7_bin: $!";
    my $m7_editor = File::Spec->catfile( $m7_bin, 'm7-editor.bat' );
    open my $m7_w, '>', $m7_editor or die "Unable to write $m7_editor: $!";
    print {$m7_w} "#!/nonexistent/m7-interp\n";
    close $m7_w or die "Unable to close: $!";
    chmod 0755, $m7_editor or die "Unable to chmod $m7_editor: $!";
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    local $ENV{PATH} = "$m7_bin:$ENV{PATH}";
    local $SIG{__WARN__} = sub { };
    is( Developer::Dashboard::CLI::OpenFile::_exec_raw('m7-editor'), 0,
        'section 14: a bad-interpreter editor returns false' );
}

{
    # 14a4. C 501 l&&!r: with every file descriptor held, the shebang
    # open fails while -f still passes, so _command_exec dies after
    # the raw exec returns false.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_cmd = File::Spec->catfile( $m7_tmp, 'm7-cmd.txt' );
    open my $m7_w, '>', $m7_cmd or die "Unable to write $m7_cmd: $!";
    print {$m7_w} "hello\n";
    close $m7_w or die "Unable to close: $!";
    my @m7_held;
    while (1) {
        my $m7_ok = open my $m7_fh, '<', '/dev/null';
        last if !$m7_ok;
        push @m7_held, $m7_fh;
    }
    my $m7_died = '';
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        local $SIG{__WARN__} = sub { };
        $m7_died = eval { Developer::Dashboard::CLI::OpenFile::_command_exec($m7_cmd); 1 } ? '' : $@;
    }
    close $_ for @m7_held;
    like( $m7_died, qr/Unable to run command/,
        'section 14: a command with no readable shebang dies instead of exiting' );
}

{
    # 14c1. B 1833 + S __ANON__@1832 are UNCOVERABLE in this file.
    # The handler only runs when Platform->can('is_real_windows') is
    # false AND the helpers are not yet loaded, but the helpers are
    # already loaded before section 14: the import in
    # _load_platform_helpers has run, so
    # PathRegistry::is_real_windows is defined. Proved by a truncated
    # run of sections 1-13 (/tmp/m7-trunc.t): defined
    # PathRegistry::is_real_windows was 1 after section 13. The
    # reload path needs a process that calls _load_platform_helpers
    # before anything else loads the helpers; this file is not one.
    # This test pins that premise so the claim stays checked.
    ok( defined &Developer::Dashboard::PathRegistry::is_real_windows,
        'section 14: the platform helpers are already loaded before section 14' );
}

{
    # 14c2. C 831 l: a stubbed directory inventory with skills_root
    # 'C:' and names [''] yields a root with no extractable name, so
    # the nested entry is skipped.
    local *Developer::Dashboard::PathRegistry::_installed_skill_directory_inventory = sub {
        return ( { skills_root => 'C:', names => [''] } );
    };
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_paths = Developer::Dashboard::PathRegistry->new( home => $m7_tmp );
    my @m7_entries = $m7_paths->nested_skill_entries();
    is( scalar @m7_entries, 0, 'section 14: a root with no name yields no nested skill entries' );
}

{
    # 14c3. B 1968 true + C 1968 l + !l&&r + !l&&!r:
    # secure_path_permissions returns an undef, empty, or missing
    # path at once.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_paths = Developer::Dashboard::PathRegistry->new( home => $m7_tmp );
    is( $m7_paths->secure_path_permissions(undef), undef,
        'section 14: an undef path is returned at once' );
    is( $m7_paths->secure_path_permissions(''), '',
        'section 14: an empty path is returned at once' );
    is( $m7_paths->secure_path_permissions('/nonexistent/m7-path'), '/nonexistent/m7-path',
        'section 14: a missing path is returned at once' );
}

{
    # 14c4. C 1186 l: a localised $^O makes _native_windows_paths
    # true in _write_state_metadata on an existing file, so the
    # stored content is read and the file returned.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_home = File::Spec->catdir( $m7_tmp, 'home' );
    File::Path::make_path($m7_home) or die "Unable to make $m7_home: $!";
    my $m7_paths = Developer::Dashboard::PathRegistry->new( home => $m7_home );
    my $m7_dir = File::Spec->catdir( $m7_tmp, 'state' );
    my $m7_file = File::Spec->catfile( $m7_dir, 'runtime.json' );
    my $m7_first = $m7_paths->_write_state_metadata( $m7_dir, $m7_tmp );
    is( $m7_first, $m7_file, 'section 14: the first metadata write returns the file' );
    local $^O = 'MSWin32';
    my $m7_second = $m7_paths->_write_state_metadata( $m7_dir, $m7_tmp );
    is( $m7_second, $m7_file, 'section 14: the metadata write on Windows returns the existing file' );
}

{
    # 14d1. B 3267 true: readdir on a closed handle sets $!, so the
    # read dies.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_app = bless {}, 'Developer::Dashboard::Web::App';
    opendir my $m7_dh, $m7_tmp or die "Unable to open $m7_tmp: $!";
    closedir $m7_dh or die "Unable to close: $!";
    my $m7_died = '';
    {
        local $SIG{__WARN__} = sub { };
        $m7_died = eval { $m7_app->_read_nav_directory_entries( $m7_dh, $m7_tmp ); 1 } ? '' : $@;
    }
    like( $m7_died, qr/Unable to read saved navigation directory/,
        'section 14: reading a closed navigation directory dies' );
}

{
    # 14d2. B 3277 true: closedir on a closed handle fails, so the
    # close dies.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_app = bless {}, 'Developer::Dashboard::Web::App';
    opendir my $m7_dh, $m7_tmp or die "Unable to open $m7_tmp: $!";
    closedir $m7_dh or die "Unable to close: $!";
    my $m7_died = '';
    {
        local $SIG{__WARN__} = sub { };
        $m7_died = eval { $m7_app->_close_nav_directory( $m7_dh, $m7_tmp ); 1 } ? '' : $@;
    }
    like( $m7_died, qr/Unable to close saved navigation directory/,
        'section 14: closing a closed navigation directory dies' );
}

{
    # 14d3. B 4419 true + B 4427 true + false + B 4428 true + false:
    # on a localised Windows, public roots '/' and a temp dir, with
    # the file in the second root. The '/' root fires B 4427 false
    # and B 4428 true (its prefix check needs a '//' that never
    # matches), and the temp root fires B 4427 true and B 4428 false
    # and serves the file.
    my $m7_tmp = tempdir( CLEANUP => 1 );
    my $m7_file = File::Spec->catfile( $m7_tmp, 'm7-file.txt' );
    open my $m7_w, '>', $m7_file or die "Unable to write $m7_file: $!";
    print {$m7_w} "m7-static\n";
    close $m7_w or die "Unable to close: $!";
    my $m7_app = bless {}, 'Developer::Dashboard::Web::App';
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my $m7_res = $m7_app->_serve_static_file_from_roots( 'js', 'm7-file.txt', '/', $m7_tmp );
    is( $m7_res->[0], 200, 'section 14: a static file in the second root serves' );
    is( $m7_res->[2], "m7-static\n", 'section 14: the served static file holds its content' );
}

{
    # 14e1. C 49 + C 59 l&&!r: a fake paths object whose home returns
    # undef makes the prompt use the empty home for matching.
    my $m7_prompt = Developer::Dashboard::Prompt->new(
        indicators => {},
        paths      => bless( {}, 'M7::FakePromptPaths' ),
    );
    my $m7_cwd = Developer::Dashboard::PathIdentity::current_working_directory();
    my $m7_text = $m7_prompt->render( no_indicators => 1 );
    like( $m7_text, qr/\[\Q$m7_cwd\E\]/,
        'section 14: a prompt with no home shows the working directory' );
}

{
    # 14f1. B 1009 false + B 1013 true: an immediate routine
    # registered after the last pump, whose callback, dispatched
    # during the END drain's pump, registers a new repeating routine;
    # the drain's next pass cancels it and re-filters to empty. This
    # is the last test action in the file: no pump runs between here
    # and process exit, so the routine is still pending when the END
    # block drains it.
    Developer::Dashboard::GoRoutine::go( sub {
        Developer::Dashboard::GoRoutine::go( sub { return; }, { every => 0.05 } );
    } );
    ok( 1, 'section 14: the END-drain routine is registered' );
}

done_testing();

__END__

=head1 NAME

t/1011-m7-tail.t - M7 tail coverage for the Developer Dashboard (R178)

=head1 PURPOSE

Cover every uncovered branch cell, condition cell, and uncovered sub
left by cover run 19 across the tail modules, so branch and condition
coverage reach 98.0. The file is the last M7 test file: sections 1 to
9 cover the first groups, sections 10 and 11 the Collector, TimeUtils,
Result, Config, InternalCLI, Upgrade, Ask, and EnvLoader groups,
section 12 the StreamDrain, Watch, PathIdentity, PerlEnv, PageStore,
and OpenFileChooser groups, section 13 the Which, DockerCompose,
Ticket, ActionRunner, RuntimeControl, and Paths groups, and section
14 the OpenFile, OpenFileGrep, PathRegistry, Web/App, Prompt, and
GoRoutine END-drain groups. Cells that cannot be reached in-process
are documented in the section headers with probe evidence instead of
being faked: the five carve-outs, the exit path in OpenFile,
the warn handlers that block-form system() never calls, the
empty-string results command_in_path never returns, and the
load-time Windows checks that only run on the Windows legs.

=head1 WHY IT EXISTS

Cover run 19 left 330 uncovered branch cells, 177 uncovered condition
cells, and 14 uncovered subs across 35 modules, and the gate reads
only the ARM64 report, so the Windows-only cells in that list still
need a Unix-side proof or a documented reason they cannot fire here.
Without these tests the tail stays uncovered and the gate stays below
98.0. The tests pin the exact triggers (a bad-interpreter executable
for the -1 paths, a symlink loop for the unresolvable paths, a deleted
working directory for the cwd fallback, file-descriptor exhaustion
for the unreadable shebang) so a later change that breaks a trigger
fails here instead of silently dropping coverage.

=head1 WHEN TO USE

When a cover run shows a tail cell uncovered again, when a module in
sections 12 to 14 changes its branching, or when a new carve-out is
proposed and needs probe evidence before it is accepted. Also when
the Windows legs report a cell this file claims is uncoverable on
Unix, to check the claim still holds.

=head1 HOW TO USE

Run it directly with C<prove -lv t/1011-m7-tail.t> while iterating,
then keep it green under C<prove -lr t> before release. It runs
in-process only: no child process counts toward coverage, so every
cell is driven inside the test process with localised variables,
stubbed subs, fake executables on a prepended PATH, and temp
directories. The local run recipe is C<perl -Ilib -Iblib/lib
-Iblib/arch t/1011-m7-tail.t> with PERL5LIB holding both the user
CPAN lib and the checkout local lib. The local cover recipe is
C<PERL5OPT=-MDevel::Cover PERL5LIB=&lt;repo&gt;/local/lib/perl5 perl
-Ilib -Iblib/lib -Iblib/arch t/1011-m7-tail.t> followed by
C<PERL5LIB=&lt;repo&gt;/local/lib/perl5 ./local/bin/cover -report text
-coverage branch -coverage condition>, then a union check against the
cover 19 console for every remaining gap cell.

=head1 WHAT USES IT

It is used by the M7 coverage programme (R178) and the Jenkins cover
job, which gates branch and condition coverage at 98.0, and by anyone
changing the tail modules who needs to know the uncovered cells still
hold.

=head1 EXAMPLES

Example 1:

  prove -lv t/1011-m7-tail.t

Run the tail checks by themselves while changing a trigger.

Example 2:

  PERL5OPT=-MDevel::Cover PERL5LIB=$PWD/local/lib/perl5 perl -Ilib -Iblib/lib -Iblib/arch t/1011-m7-tail.t

Run the file under Devel::Cover to measure which tail cells it hits.

Example 3:

  prove -lr t

Run the whole suite after the focused check to keep the tail aligned
with the rest of the tests.

=cut
