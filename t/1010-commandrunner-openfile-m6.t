#!/usr/bin/env perl

# M6 (R173): CommandRunner + CLI/OpenFile coverage tests.
#
# Written first, before any implementation change, as the M6 milestone
# requires. Cover build #18 measured CommandRunner.pm at stmt 85.7,
# branch 76.7, cond 87.5, sub 100.0, total 84.7 and CLI/OpenFile.pm at
# stmt 90.2, branch 87.5, cond 85.8, sub 96.9, total 89.2. Both gaps
# are Windows paths never taken on the ARM64 cover run: CommandRunner's
# Windows rewrite, unlink, inline-command success path, single-quote
# escaping and spawn-child reap loop, and OpenFile's grep-missing path,
# canonpath, _command_exec Windows block and _exec_raw Windows block.
#
# THE $OS_NAME HOOK. Both modules dispatch on is_windows(), which reads
# Developer::Dashboard::Platform::$OS_NAME, a load-time copy of $^O
# (the M4 pattern, not the M5 one: Watch.pm reads $^O directly, but
# these two modules do not). Localising $OS_NAME to 'MSWin32' drives
# every Windows branch below on Unix, and the Jenkins proof drives
# them for real on the Windows legs. The mock spawn in this file is
# installed only on non-Windows, so on a real Windows leg the real
# spawn_windows_command runs against the real powershell. The
# spawn-count assertions are therefore guarded to non-Windows: with
# no mock installed nothing is recorded there, and the proof on a
# real Windows leg is the $out the child really printed (R175: proof
# #208 failed both Windows legs on the unguarded count).
#
# THE MOCK. On Unix, spawn_windows_command cannot run: its body is
# `system 1, @argv`, the Windows-only asynchronous spawn form, and on
# Unix Perl that tries to exec a program literally named "1" (probed:
# returns -1, "Can't exec \"1\""). The mock below stands in for that
# one Windows-only primitive only: it records the argv it receives and
# spawns a real short-lived child through GoRoutine's native process
# API, returning a real pid that await_windows_command waitpids for
# real. Everything else in run_command - the rewrite, the PowerShell
# argv build, the await loop, the unlink - runs unmocked. The mock is
# the M5 shape: fake the primitive, drive the pure-Perl logic.
#
# THE REGISTRY TRICK. terminate_command_process polls the GoRoutine
# spawn registry only for a registry-tracked pid, and the registry is
# populated by _keep_spawn_handle, which returns early unless $^O is
# 'MSWin32' at spawn time. Localising $^O to 'MSWin32' around the
# spawn (as well as $OS_NAME for is_windows) makes the spawn record
# the pid on Unix too, so the reap loop runs here; on a real Windows
# leg the same test runs with a real registry entry and real taskkill.
#
# THE CHILDREN. Two tests run in spawned children (GoRoutine's native
# process API, R169: t/246 forbids a direct fork() in t/). The
# _exec_raw exit test must run in a child because a successful system
# call ends in exit(), which would replace the test process. The
# _command_exec open-failure test must run in a child because its
# only honest mechanism is exhausting the file-descriptor table, which
# must not be done to the test process itself. The child is spawned
# through sh, which lowers the child's own NOFILE limit to 128 first:
# on a leg with a high limit the open loop cannot exhaust the table
# inside the 10s wait bound (R175: proof #208 timed out on both Linux
# legs). Each child is a separate perl process, so it installs its own
# localisation and its own _exec_raw stub and reports back by exit
# code only.
#
# WRITE WITH SYSWRITE. A print to a pipe handle buffers: the bytes sit
# in Perl's output buffer and never reach the pipe until the handle is
# flushed or closed. Every write to a test pipe below uses syswrite,
# which is unbuffered. (No pipes are used in this file; the rule is
# kept here because the child scripts write files, and print to a file
# handle is checked with `or die` wherever it matters.)
#
# CARVE-OUTS (R173). The print/close `or die` branches at
# CommandRunner lines 126-127 are NOT covered here: the tempfile is
# created inside _windows_perl_inline_command, so no caller can make
# its print or close fail without contrivance (a disk-full injection);
# a probe with an unwritable TMPDIR showed tempfile itself dies at
# creation, before the print is ever reached, and as root the
# permission route does not even apply. They stand for M7 like the
# 2101 finding. The _exec_raw condition cell at OpenFile line 562
# ($rc != -1 and $! set) is likewise unreachable: a probe showed a
# successful system() leaves $! empty and a failed one returns -1, so
# $! is set exactly when $rc is -1. It stands for M7 too. Both were
# reported to Ryan with the probe evidence.

use strict;
use warnings;

use Config;
use Capture::Tiny qw(capture);
use Encode qw(decode);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use MIME::Base64 qw(decode_base64);
use Test::More;
use Time::HiRes ();

use lib File::Spec->catdir( $Bin, '..', 'lib' );

use Developer::Dashboard::GoRoutine ();

require_ok('Developer::Dashboard::CommandRunner');
require_ok('Developer::Dashboard::CLI::OpenFile');
require_ok('Developer::Dashboard::Platform');
require_ok('Developer::Dashboard::CLI::OpenFileGrep');
require_ok('Developer::Dashboard::PathRegistry');

my $IS_WINDOWS = $^O eq 'MSWin32';

# Mock spawn_windows_command (non-Windows only). See the header comment.
# Records the argv and spawns a real child that exits at once, returning
# a real pid for await_windows_command to waitpid.
my @SPAWN_ARGV_SEEN;
if ( !$IS_WINDOWS ) {
    no warnings 'redefine';
    *Developer::Dashboard::CommandRunner::spawn_windows_command = sub {
        my (@argv) = @_;
        push @SPAWN_ARGV_SEEN, \@argv;
        my $pid = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'exit 0' ], {} );
        return defined $pid ? $pid : 0;
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
        Time::HiRes::sleep(0.05);
    }
    kill 'KILL', $pid;
    Developer::Dashboard::GoRoutine::wait_process($pid);
    return undef;
}

# _decode_powershell_argv(\@argv): decodes the -EncodedCommand
# argument of a _windows_powershell_argv result back to the script
# text, so the test can assert what the child would have run.
# Input: argv array reference.
# Output: script string, or undef when no -EncodedCommand is present.
sub _decode_powershell_argv {
    my ($argv) = @_;
    for my $i ( 0 .. $#$argv - 1 ) {
        next if $argv->[$i] ne '-EncodedCommand';
        return decode( 'UTF-16LE', decode_base64( $argv->[ $i + 1 ] ) );
    }
    return undef;
}

# _write_file($path, $content, $mode): writes one small test file.
# Input: path, content string, optional mode (default 0644).
# Output: nothing; dies on failure.
sub _write_file {
    my ( $path, $content, $mode ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    chmod( $mode, $path ) or die "Unable to chmod $path: $!" if defined $mode;
    return;
}

# _read_file($path): reads one small test file whole.
# Input: path.
# Output: content string; dies on failure.
sub _read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return defined $content ? $content : '';
}

# Feature: run_command rewrites a perl -e command on Windows and
# unlinks the temp file afterwards.
#
# Scenario: the command is a perl -e invocation and the platform is
# Windows. Given the rewrite succeeds, when run_command runs it, then
# the child runs the temp .pl file (not the -e string) and the file is
# gone once the run returns.
{
    my $tmp = tempdir( CLEANUP => 1 );
    local $ENV{TMPDIR} = $tmp;
    local $ENV{TEMP}   = $tmp;
    local $ENV{TMP}    = $tmp;
    my $before = scalar @SPAWN_ARGV_SEEN;
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my ( $out, $err, $exit, $timed_out ) = Developer::Dashboard::CommandRunner::run_command(
        source     => 'perl -e "print 42"',
        cwd        => $tmp,
        env        => {},
        timeout_ms => 10_000,
    );
    is( $exit,      0, 'run_command on Windows returns exit 0 for a rewritten perl -e command' );
    is( $timed_out, 0, 'run_command on Windows does not time out for a rewritten perl -e command' );
    SKIP: {
        skip 'the spawn count is only recorded by the Unix mock', 1 if $IS_WINDOWS;
        is( scalar @SPAWN_ARGV_SEEN, $before + 1, 'the Windows path spawned exactly once' );
    }
    if ($IS_WINDOWS) {
        like( $out, qr/42/, 'on real Windows the rewritten script really ran and printed 42' );
    }
    else {
        my $script = _decode_powershell_argv( $SPAWN_ARGV_SEEN[-1] );
        ok( defined $script, 'the spawned argv carries an -EncodedCommand script' );
        like( $script, qr/perl\s+\S+\.pl/, 'the script runs a temp .pl file, not the -e string' );
        unlike( $script, qr/-e\s+"print 42"/, 'the -e string does not reach the child' );
        my ($plfile) = $script =~ /(\S+\.pl)/;
        ok( defined $plfile, 'the .pl path can be read back from the script' );
        ok( !-f $plfile, 'the temp .pl file is unlinked after the run' ) if defined $plfile;
    }
    my @lingering = glob File::Spec->catfile( $tmp, 'dashboard-perl-inline-*' );
    is( scalar @lingering, 0, 'no inline temp files linger in the temp dir' );
}

# Feature: run_command leaves a non-perl command alone on Windows.
#
# Scenario: the command is not a perl -e invocation and the platform
# is Windows. Given the rewrite returns undef, when run_command runs
# it, then the command runs as given and no temp .pl file is made.
{
    my $tmp = tempdir( CLEANUP => 1 );
    local $ENV{TMPDIR} = $tmp;
    local $ENV{TEMP}   = $tmp;
    local $ENV{TMP}    = $tmp;
    my $before = scalar @SPAWN_ARGV_SEEN;
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my ( $out, $err, $exit, $timed_out ) = Developer::Dashboard::CommandRunner::run_command(
        source     => 'echo hello',
        cwd        => $tmp,
        env        => {},
        timeout_ms => 10_000,
    );
    is( $exit,      0, 'run_command on Windows returns exit 0 for a plain command' );
    is( $timed_out, 0, 'run_command on Windows does not time out for a plain command' );
    SKIP: {
        skip 'the spawn count is only recorded by the Unix mock', 1 if $IS_WINDOWS;
        is( scalar @SPAWN_ARGV_SEEN, $before + 1, 'the Windows path spawned exactly once for a plain command' );
    }
    if ($IS_WINDOWS) {
        like( $out, qr/hello/, 'on real Windows the plain command really ran' );
    }
    else {
        my $script = _decode_powershell_argv( $SPAWN_ARGV_SEEN[-1] );
        ok( defined $script, 'the spawned argv carries an -EncodedCommand script for a plain command' );
        unlike( $script, qr/\.pl/, 'no temp .pl file is named for a plain command' );
        like( $script, qr/echo hello/, 'the plain command reaches the child unchanged' );
    }
    my @lingering = glob File::Spec->catfile( $tmp, 'dashboard-perl-inline-*' );
    is( scalar @lingering, 0, 'no inline temp files linger for a plain command' );
}

# Feature: _windows_perl_inline_command rewrites only the exact
# perl -e shape.
#
# Scenario: the command is a perl -e invocation. Given the shape
# matches, when the rewrite runs, then it returns a command naming a
# real temp .pl file holding the code, and nothing else changes.
{
    my $tmp = tempdir( CLEANUP => 1 );
    local $ENV{TMPDIR} = $tmp;
    local $ENV{TEMP}   = $tmp;
    local $ENV{TMP}    = $tmp;
    is( Developer::Dashboard::CommandRunner::_windows_perl_inline_command(undef),
        undef, 'undef command rewrites to undef' );
    is( Developer::Dashboard::CommandRunner::_windows_perl_inline_command('echo hi'),
        undef, 'a non-perl command rewrites to undef' );
    is( Developer::Dashboard::CommandRunner::_windows_perl_inline_command('perl -e'),
        undef, 'a bare perl -e with no quoted code rewrites to undef' );
    is( Developer::Dashboard::CommandRunner::_windows_perl_inline_command('perl "print 1"'),
        undef, 'perl without -e rewrites to undef' );
    my $r = Developer::Dashboard::CommandRunner::_windows_perl_inline_command('perl -e "print 42"');
    ok( ref $r eq 'HASH', 'a perl -e command rewrites to a hash ref' );
    is( $r->{command}, "perl $r->{file}", 'the rewritten command names the temp file' );
    ok( -f $r->{file}, 'the temp .pl file exists' );
    is( _read_file( $r->{file} ), 'print 42', 'the temp .pl file holds the code' );
    unlink $r->{file} or die "Unable to unlink $r->{file}: $!";
    my $flags = Developer::Dashboard::CommandRunner::_windows_perl_inline_command('perl -w -Ilib -e "print 1"');
    ok( ref $flags eq 'HASH', 'a flagged perl -e command rewrites to a hash ref' );
    is( $flags->{command}, "perl -w -Ilib $flags->{file}", 'the flags survive the rewrite' );
    is( _read_file( $flags->{file} ), 'print 1', 'the flagged temp file holds the code' );
    unlink $flags->{file} or die "Unable to unlink $flags->{file}: $!";
    my $exe = Developer::Dashboard::CommandRunner::_windows_perl_inline_command('perl.exe -e "print 2"');
    ok( ref $exe eq 'HASH', 'a perl.exe -e command rewrites to a hash ref' );
    like( $exe->{command}, qr/\Aperl\.exe\s+\S+\.pl\z/, 'the perl.exe spelling survives the rewrite' );
    is( _read_file( $exe->{file} ), 'print 2', 'the perl.exe temp file holds the code' );
    unlink $exe->{file} or die "Unable to unlink $exe->{file}: $!";
    my $spaced = Developer::Dashboard::CommandRunner::_windows_perl_inline_command('  perl -e "x"');
    ok( ref $spaced eq 'HASH', 'leading whitespace does not stop the rewrite' );
    unlink $spaced->{file} or die "Unable to unlink $spaced->{file}: $!";
    my $multi = Developer::Dashboard::CommandRunner::_windows_perl_inline_command("perl -e \"print 1;\nprint 2\"");
    ok( ref $multi eq 'HASH', 'multi-line code rewrites to a hash ref' );
    is( _read_file( $multi->{file} ), "print 1;\nprint 2", 'multi-line code survives the rewrite whole' );
    unlink $multi->{file} or die "Unable to unlink $multi->{file}: $!";
}

# Feature: _escape_windows_powershell_single_quotes escapes double
# quotes only inside single-quoted strings.
#
# Scenario: the command carries quotes in several shapes. Given the
# escaping runs, when a double quote sits inside single quotes, then
# it is escaped; everywhere else the command is untouched.
{
    my $esc = \&Developer::Dashboard::CommandRunner::_escape_windows_powershell_single_quotes;
    is( $esc->(undef),    undef,      'undef passes through unchanged' );
    is( $esc->(''),       '',         'an empty command passes through unchanged' );
    is( $esc->('echo hi'), 'echo hi', 'a plain command passes through unchanged' );
    is( $esc->('"quoted"'), '"quoted"', 'double quotes outside single quotes are left alone' );
    is( $esc->( q{'a"b'} ), q{'a\"b'}, 'a double quote inside single quotes is escaped' );
    is( $esc->( q{'it''s'} ), q{'it''s'}, 'a doubled quote inside single quotes passes through unchanged' );
    is( $esc->( q{'abc'} ), q{'abc'}, 'a plain single-quoted string passes through unchanged' );
    is( $esc->( q{don't "x"} ), q{don't \"x\"}, 'an apostrophe opens single-quote mode, so a later double quote is escaped' );
    is( $esc->( q{'a"b"c'} ), q{'a\"b\"c'}, 'several double quotes inside one single-quoted string are all escaped' );
    is( $esc->( q{'a"'} ), q{'a\"'}, 'a double quote just before the closing quote is escaped' );
}

# Feature: terminate_command_process polls the spawn registry until
# a registry-tracked child is collected.
#
# Scenario: the pid is a GoRoutine-spawned child that is still alive.
# Given the platform is Windows, when terminate runs, then the reap
# loop polls until the child exits and is collected, and terminate
# returns 1 with the child gone. On Unix the child lives out its
# 0.3s sleep, so the poll really waits; on real Windows taskkill ends
# it at once, so no wait is asserted there.
{
    local $^O = 'MSWin32';
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my $pid = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-e', 'select(undef, undef, undef, 0.3); exit 0' ], {} );
    ok( defined $pid && $pid > 0, 'a registry-tracked child spawns' );
    is( Developer::Dashboard::GoRoutine::is_spawn_child($pid), 1,
        'the spawned child is registry-tracked' );
    my $t0 = Time::HiRes::time();
    my $rc = Developer::Dashboard::CommandRunner::terminate_command_process($pid);
    my $dt = Time::HiRes::time() - $t0;
    is( $rc, 1, 'terminate returns 1 for a registry-tracked child' );
    ok( !Developer::Dashboard::GoRoutine::process_running($pid),
        'the child is gone after terminate' );
    is( Developer::Dashboard::GoRoutine::is_spawn_child($pid), 0,
        'the reap loop collected the registry entry' );
    if ( !$IS_WINDOWS ) {
        cmp_ok( $dt, '>=', 0.2, 'the reap loop waited for the child to exit' );
    }
}

# Feature: terminate_command_process skips the reap loop for a pid
# the registry never saw.
#
# Scenario: the pid is a real child that has already exited and been
# reaped, so the registry holds no entry for it. Given the platform
# is Windows, when terminate runs, then it returns 1 at once without
# polling the registry.
{
    my $pid = Developer::Dashboard::GoRoutine::spawn( [ $^X, '-e', 'exit 0' ], {} );
    ok( defined $pid && $pid > 0, 'a short-lived child spawns' );
    my $code = Developer::Dashboard::GoRoutine::wait_process($pid);
    is( $code, 0, 'the short-lived child exits 0 and is reaped' );
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    is( Developer::Dashboard::GoRoutine::is_spawn_child($pid), 0,
        'the reaped child is no longer registry-tracked' );
    is( Developer::Dashboard::CommandRunner::terminate_command_process($pid), 1,
        'terminate returns 1 for a pid the registry never saw' );
}

# Feature: run_open_file_command shows the built-in grep usage when
# no system grep exists.
#
# Scenario: the user asks for `of grep --help` on a box with no
# grep on PATH. Given grep does not resolve, when the command runs,
# then it prints the built-in search usage and exits 0 instead of
# dying on the missing binary.
{
    my $empty = tempdir( CLEANUP => 1 );
    local $ENV{PATH} = $empty;
    is( Developer::Dashboard::Platform::command_in_path('grep'), undef,
        'grep is not on the localised PATH' );
    my $exit_error;
    my ( $out, $err );
    {
        local *Developer::Dashboard::CLI::OpenFile::_command_exit = sub { die "EXIT:$_[0]\n" };
        ( $out, $err ) = capture {
            eval { Developer::Dashboard::CLI::OpenFile::run_open_file_command( args => [ 'grep', '--help' ] ) };
            $exit_error = $@;
        };
    }
    like( $exit_error, qr/^EXIT:0/, 'the grep-missing path exits 0' );
    is( $out, Developer::Dashboard::CLI::OpenFileGrep::native_grep_usage(),
        'the grep-missing path prints the built-in grep usage' );
    is( $err, '', 'the grep-missing path prints nothing to stderr' );
}

# Feature: _resolve_open_file_matches canonicalises absolute
# File::Find hits.
#
# Scenario: the search scope is an absolute directory. Given the
# walk finds files there, when the matches resolve, then every
# returned path is absolute, so the canonpath branch ran.
{
    my $scope = tempdir( CLEANUP => 1 );
    _write_file( File::Spec->catfile( $scope, 'foo-target.txt' ), "alpha\n" );
    _write_file( File::Spec->catfile( $scope, 'other.txt' ),      "beta\n" );
    my $reg = Developer::Dashboard::PathRegistry->new( home => $scope, cwd => $scope );
    my ( $line, @files ) = Developer::Dashboard::CLI::OpenFile::_resolve_open_file_matches(
        paths => $reg,
        args  => [$scope],
    );
    is( $line, 0, 'an absolute-scope resolve returns a zero line' );
    is( scalar @files, 2, 'an absolute-scope resolve finds both files' );
    ok( ( grep { m{foo-target\.txt\z} } @files ), 'the foo file is among the matches' );
    ok( ( grep { m{other\.txt\z} } @files ), 'the other file is among the matches' );
    ok( File::Spec->file_name_is_absolute($_), "match $_ is absolute" ) for @files;
}

# Feature: _command_exec routes a Windows shell script through the
# resolved POSIX shell.
#
# Scenario: the editor command is a shell script and the platform is
# Windows. Given the script is named by extension or by shebang,
# when _command_exec runs, then the command is rewritten through
# command_argv_for_path and the extra arguments stay as the script's
# own argv; when it is not a shell script, the command is left alone.
# The exec itself is replaced by a recording stub (the t/770 shape),
# so the die after a failed exec is reachable in-process.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $sh = File::Spec->catfile( $dir, 'run.sh' );
    _write_file( $sh, "#!/bin/sh\necho hi\n", 0755 );
    my $shebang = File::Spec->catfile( $dir, 'runner' );
    _write_file( $shebang, "#!/bin/sh\necho hi\n", 0755 );
    my $plain = File::Spec->catfile( $dir, 'plain' );
    _write_file( $plain, "#!/usr/bin/env python3\nprint(1)\n", 0755 );
    my $empty = File::Spec->catfile( $dir, 'empty' );
    _write_file( $empty, '' );
    my $missing = File::Spec->catfile( $dir, 'no-such-file' );
    my @seen;
    {
        no warnings 'redefine';
        local *Developer::Dashboard::CLI::OpenFile::_exec_raw = sub {
            push @seen, [@_];
            $! = 2;
            return 0;
        };
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        my $expect_sh = [ Developer::Dashboard::Platform::command_argv_for_path($sh) ];
        eval { Developer::Dashboard::CLI::OpenFile::_command_exec( $sh, 'arg1' ) };
        like( $@, qr/\QUnable to run command '$expect_sh->[0]'\E/, 'a .sh command dies naming the shell when the exec returns' );
        is_deeply( $seen[-1], [ @$expect_sh, 'arg1' ], 'a .sh command is rewritten through the POSIX shell' );
        my $expect_shebang = [ Developer::Dashboard::Platform::command_argv_for_path($shebang) ];
        eval { Developer::Dashboard::CLI::OpenFile::_command_exec( $shebang, 'arg' ) };
        like( $@, qr/\QUnable to run command '$expect_shebang->[0]'\E/, 'a shebang shell script dies naming the shell when the exec returns' );
        is_deeply( $seen[-1], [ @$expect_shebang, 'arg' ], 'a shebang shell script is rewritten through the POSIX shell' );
        eval { Developer::Dashboard::CLI::OpenFile::_command_exec( $plain, 'arg' ) };
        like( $@, qr/\QUnable to run command '$plain'\E/, 'a non-shell script dies naming the script when the exec returns' );
        is_deeply( $seen[-1], [ $plain, 'arg' ], 'a non-shell script is left alone' );
        eval { Developer::Dashboard::CLI::OpenFile::_command_exec( $empty, 'arg' ) };
        like( $@, qr/\QUnable to run command '$empty'\E/, 'an empty script dies naming the script when the exec returns' );
        is_deeply( $seen[-1], [ $empty, 'arg' ], 'an empty script is left alone' );
        eval { Developer::Dashboard::CLI::OpenFile::_command_exec($missing) };
        like( $@, qr/\QUnable to run command '$missing'\E/, 'a missing file dies naming it when the exec returns' );
        is_deeply( $seen[-1], [$missing], 'a missing file is left alone' );
        my @warns;
        local $SIG{__WARN__} = sub { push @warns, $_[0]; return };
        eval { Developer::Dashboard::CLI::OpenFile::_command_exec() };
        like( $@, qr/Unable to run command/, 'an empty command dies when the exec returns' );
        is_deeply( $seen[-1], [], 'an empty command reaches the exec empty' );
        is( scalar( grep { /uninitialized value/ } @warns ), 1,
            'an empty command warns once about the unnamed command' );
    }
}

# Feature: _command_exec leaves a script alone when its shebang
# cannot be read.
#
# Scenario: the file-descriptor table is exhausted, so the shebang
# open fails even though the file exists. Given the open fails, when
# _command_exec runs, then the command is left alone and the exec
# still dies naming it. This runs in a spawned child (GoRoutine
# process API, R169): exhausting descriptors must not be done to
# the test process itself, and the child reports back by exit code.
SKIP: {
    skip 'the open-failure child exhausts descriptors through /dev/null, which Windows has no', 1 if $IS_WINDOWS;
    my $dir = tempdir( CLEANUP => 1 );
    my $file = File::Spec->catfile( $dir, 'runner' );
    _write_file( $file, "#!/bin/sh\necho hi\n", 0755 );
    my $child_script = File::Spec->catfile( $dir, 'open-failure-child.pl' );
    {
        open my $sfh, '>', $child_script or die "Unable to write $child_script: $!";
        print {$sfh} "use strict;\n";
        print {$sfh} "use warnings;\n";
        print {$sfh} "no warnings 'once';\n";
        print {$sfh} "require Developer::Dashboard::CLI::OpenFile;\n";
        print {$sfh} "local \$Developer::Dashboard::Platform::OS_NAME = 'MSWin32';\n";
        print {$sfh} "no warnings 'redefine';\n";
        print {$sfh} "my \@seen;\n";
        print {$sfh} "*Developer::Dashboard::CLI::OpenFile::_exec_raw = sub { push \@seen, [\@_]; \$! = 2; return 0; };\n";
        print {$sfh} "my \$file = '$file';\n";
        print {$sfh} "my \@held;\n";
        print {$sfh} "while ( open my \$h, '<', '/dev/null' ) { push \@held, \$h; }\n";
        print {$sfh} "my \$msg = '';\n";
        print {$sfh} "eval { Developer::Dashboard::CLI::OpenFile::_command_exec( \$file, 'arg' ); };\n";
        print {$sfh} "\$msg = \$@;\n";
        print {$sfh} "my \$ok = \$msg =~ /Unable to run command/ && \@seen == 1 && \$seen[0][0] eq \$file && \$seen[0][1] eq 'arg';\n";
        print {$sfh} "exit( \$ok ? 0 : 1 );\n";
        close $sfh or die "Unable to close $child_script: $!";
    }
    # Lower the child's own NOFILE limit before perl starts: sh sets
    # it, then execs perl, and the limit is inherited across the exec.
    # 128 leaves ample room for perl startup and the requires, and
    # the open loop then exhausts in about a hundred opens on any
    # leg, however high its inherited limit is.
    my $pid = Developer::Dashboard::GoRoutine::spawn(
        [ '/bin/sh', '-c', 'ulimit -n 128; exec "$@"', 'sh', $^X, $child_script ],
        { env => { PERL5LIB => _child_perl5lib( File::Spec->catdir( $Bin, '..' ) ) } },
    );
    BAIL_OUT('GoRoutine spawn failed') if !defined $pid;
    my $rc = _wait_for_exit( $pid, 10 );
    BAIL_OUT('open-failure child did not exit') if !defined $rc;
    is( $rc, 0, 'a shebang open failure leaves the command alone' );
}

# Feature: _exec_raw fails exactly like a failed exec when the
# editor cannot be found on Windows.
#
# Scenario: the editor name is bare and resolves to nothing, or the
# editor path does not exist. Given the platform is Windows, when
# _exec_raw runs, then it warns "Can't exec" once and returns false,
# so _command_exec dies naming the cause.
{
    local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, $_[0]; return };
    my $bare = Developer::Dashboard::CLI::OpenFile::_exec_raw( 'definitely-not-on-path-xyz', 'x' );
    ok( !$bare, 'a bare editor name that resolves to nothing returns false' );
    is( scalar @warns, 1, 'a bare unresolvable editor warns exactly once' );
    like( $warns[0], qr/\QCan't exec "definitely-not-on-path-xyz"\E/,
        'a bare unresolvable editor warns naming the editor' );
    @warns = ();
    my $missing = Developer::Dashboard::CLI::OpenFile::_exec_raw( '/nonexistent/dir/editor', 'x' );
    ok( !$missing, 'a missing editor path returns false' );
    is( scalar @warns, 1, 'a missing editor path warns exactly once' );
    like( $warns[0], qr/\QCan't exec "\/nonexistent\/dir\/editor"\E/,
        'a missing editor path warns naming the editor' );
}

# Feature: _exec_raw exits with the child status when the Windows
# system call succeeds.
#
# Scenario: the editor is a bare name that resolves to a runnable
# file on PATH, and the file exits 3. Given the platform is Windows,
# when _exec_raw runs, then it exits with the child status, so the
# caller never returns. This runs in a spawned child (GoRoutine
# process API, R169): a successful system call ends in exit(), which
# would replace the test process. The vim.bat fake is a Unix
# executable (a Perl script under a .bat name, which is exactly what
# command_in_path_direct returns on simulated Windows), so this test
# is skipped on real Windows; the exit-code proof belongs on Unix
# and the ARM64 cover run is where the line is measured.
SKIP: {
    skip 'the vim.bat fake is a Unix executable, not a Windows one', 3 if $IS_WINDOWS;
    my $dir = tempdir( CLEANUP => 1 );
    my $bindir = File::Spec->catdir( $dir, 'bin' );
    mkdir $bindir or die "Unable to mkdir $bindir: $!";
    my $marker = File::Spec->catfile( $dir, 'vim-ran.txt' );
    my $bat    = File::Spec->catfile( $bindir, 'vim.bat' );
    my $bat_content = '#!/usr/bin/env perl' . "\n"
      . 'use strict;' . "\n"
      . 'use warnings;' . "\n"
      . "open my \$m, '>', '$marker' or exit 9;" . "\n"
      . 'print {$m} "ran\\n";' . "\n"
      . 'close $m;' . "\n"
      . 'exit 3;' . "\n";
    _write_file( $bat, $bat_content, 0755 );
    my $child_script = File::Spec->catfile( $dir, 'exec-raw-child.pl' );
    {
        open my $sfh, '>', $child_script or die "Unable to write $child_script: $!";
        print {$sfh} "use strict;\n";
        print {$sfh} "use warnings;\n";
        print {$sfh} "no warnings 'once';\n";
        print {$sfh} "my (\$bindir) = \@ARGV;\n";
        print {$sfh} "local \$ENV{PATH} = join ':', \$bindir, \$ENV{PATH};\n";
        print {$sfh} "require Developer::Dashboard::CLI::OpenFile;\n";
        print {$sfh} "local \$Developer::Dashboard::Platform::OS_NAME = 'MSWin32';\n";
        print {$sfh} "Developer::Dashboard::CLI::OpenFile::_exec_raw('vim', 'extra');\n";
        print {$sfh} "exit 99;\n";
        close $sfh or die "Unable to close $child_script: $!";
    }
    my $pid = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, $child_script, $bindir ],
        { env => { PERL5LIB => _child_perl5lib( File::Spec->catdir( $Bin, '..' ) ) } },
    );
    BAIL_OUT('GoRoutine spawn failed') if !defined $pid;
    my $rc = _wait_for_exit( $pid, 10 );
    BAIL_OUT('exec-raw child did not exit') if !defined $rc;
    is( $rc, 3, 'a successful Windows system call exits with the child status' );
    ok( -f $marker, 'the resolved vim.bat really ran' );
    is( -f $marker ? _read_file($marker) : '', "ran\n", 'the resolved vim.bat wrote its marker' );
}

done_testing();

__END__

=head1 NAME

t/1010-commandrunner-openfile-m6.t - M6 CommandRunner and OpenFile coverage tests

=head1 PURPOSE

Covers the CommandRunner.pm and CLI/OpenFile.pm remainder from the
R83 coverage programme: the Windows rewrite, the unlink, the
inline-command success path, the single-quote escaping and the
spawn-child reap loop in CommandRunner, and the grep-missing path,
the canonpath, the _command_exec Windows block and the _exec_raw
Windows block in OpenFile. Written first, before any implementation
change, as the M6 milestone requires. The print/close `or die`
branches at CommandRunner lines 126-127 are NOT covered here: they
are unreachable without contrivance, and R173 ruled they stand for
M7; the _exec_raw condition cell at OpenFile line 562 ($rc != -1
and $! set) is likewise unreachable, and stands for M7 too.

=head1 WHY IT EXISTS

Cover build #18 measured CommandRunner.pm at stmt 85.7, branch
76.7, cond 87.5, sub 100.0, total 84.7 and CLI/OpenFile.pm at stmt
90.2, branch 87.5, cond 85.8, sub 96.9, total 89.2. Both gaps are
Windows paths never taken on the ARM64 cover run. This file drives
them with a localised $OS_NAME and a mocked Windows-only spawn
primitive on Unix and the real primitives on the Windows legs of
the Jenkins proof, so the cover re-measure after M6 shows both
files moving toward the 98.0 gate.

=head1 WHEN TO USE

Run this file whenever CommandRunner.pm or CLI/OpenFile.pm changes.
It is part of the normal suite, not a probe: if it fails, a
command-runner or open-file behaviour regressed.

=head1 HOW TO USE

    prove -v t/1010-commandrunner-openfile-m6.t

Run it directly with C<prove -lv t/1010-commandrunner-openfile-m6.t>
while iterating, then keep it green under C<prove -lr t> and the
Devel::Cover run before release.

=head1 WHAT USES IT

It is used by developers during TDD, by the full C<prove -lr t>
suite, by the Devel::Cover coverage gate, and by release
verification before commit or push.

=head1 EXAMPLES

Example 1:

    prove -lv t/1010-commandrunner-openfile-m6.t

Run this coverage-gap test by itself while editing the covered modules.

Example 2:

    HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lv t/1010-commandrunner-openfile-m6.t

Confirm the targeted lines are reported as covered.

=cut
