#!/usr/bin/env perl
# MICRO: why is fake-editor.log never written on Windows? (t/05 line-2403
# death diagnosis)
#
# t/05 writes an extensionless #!/bin/sh fake editor and runs
# `d2 of grep ...` with EDITOR=<fake>. The d2 command exits 0 (its _run
# check passes in build #52) yet fake-editor.log is never created, and the
# test then dies reading it at line 2403. The product routes sh scripts on
# Windows through a POSIX shell (OpenFile.pm _command_exec ->
# Platform::command_argv_for_path -> _posix_shell_binary), so the question
# is whether a shell is found on win-ts and what argv the editor gets.
#
# Phase 1: resolve the editor argv via command_argv_for_path and dump the
# shell lookup (sh on PATH? git on PATH? Git usr/bin/sh.exe present?).
# Phase 2: run the resolved argv + a dummy file via IPC::Open3 and dump
# exit/stdout/stderr plus whether the log appears and what it holds.
# Dumps go to STDERR (prove shows them even for a passing test). Always
# passes by design; the dumps are the result.
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3;
use Test::More;
use Developer::Dashboard::Platform qw(command_argv_for_path command_in_path);

my $home            = tempdir( CLEANUP => 1 );
my $fake_editor_bin = File::Spec->catdir( $home, 'fake-editor-bin' );
make_path($fake_editor_bin);
my $fake_editor_log = File::Spec->catfile( $home, 'fake-editor.log' );
my $fake_editor     = File::Spec->catfile( $fake_editor_bin, 'fake-editor' );
open my $fh, '>', $fake_editor or die "Unable to write $fake_editor: $!";
print {$fh} <<"SH";
#!/bin/sh
printf '%s\\n' "\$*" > '$fake_editor_log'
SH
close $fh;
chmod 0755, $fake_editor or die "Unable to chmod $fake_editor: $!";

my $target = File::Spec->catfile( $home, 'alpha-notes.txt' );
open my $tfh, '>', $target or die "Unable to write $target: $!";
print {$tfh} "alpha\n";
close $tfh;

diag "MICRO-EDITOR os=$^O fake_editor=$fake_editor";
diag "MICRO-EDITOR sh_in_path=" . ( command_in_path('sh')   // 'undef' );
diag "MICRO-EDITOR git_in_path=" . ( command_in_path('git')  // 'undef' );
for my $pf ( grep { defined && $_ ne '' } $ENV{ProgramFiles}, $ENV{'ProgramFiles(x86)'} ) {
    my $sh = File::Spec->catfile( $pf, 'Git', 'usr', 'bin', 'sh.exe' );
    diag "MICRO-EDITOR git_sh_at $sh exists=" . ( -f $sh ? 1 : 0 );
}

my @argv;
my $resolve_error = '';
eval { @argv = command_argv_for_path($fake_editor); 1 } or $resolve_error = $@;
$resolve_error =~ s/\s+\z//;
diag "MICRO-EDITOR resolve_error=[$resolve_error]";
diag "MICRO-EDITOR argv=[" . join( '|', @argv ) . "]";

if ( @argv && !$resolve_error ) {
    my $out_file = File::Spec->catfile( $home, 'out.txt' );
    my $err_file = File::Spec->catfile( $home, 'err.txt' );
    open my $out_fh, '>', $out_file or die "Unable to write $out_file: $!";
    open my $err_fh, '>', $err_file or die "Unable to write $err_file: $!";
    open my $in_fh, '<', File::Spec->devnull() or die "Unable to read devnull: $!";
    my $pid = eval { open3( $in_fh, $out_fh, $err_fh, @argv, $target ) };
    my $spawn_error = $@;
    close $in_fh;
    close $out_fh;
    close $err_fh;
    my $exit = -1;
    if ( defined $pid ) {
        waitpid $pid, 0;
        $exit = $? >> 8;
    }
    my $stdout = do { open my $r, '<', $out_file or die $!; local $/; <$r> // '' };
    my $stderr = do { open my $r, '<', $err_file or die $!; local $/; <$r> // '' };
    my $log_contents = 'MISSING';
    if ( -f $fake_editor_log ) {
        open my $r, '<', $fake_editor_log or die $!; local $/; $log_contents = <$r> // '';
    }
    $stdout =~ s/\s+\z//;
    $stderr =~ s/\s+\z//;
    $log_contents =~ s/\s+\z// if $log_contents ne 'MISSING';
    $spawn_error =~ s/\s+\z//;
    diag "MICRO-EDITOR run spawn_error=[$spawn_error] exit=$exit";
    diag "MICRO-EDITOR run stdout=[$stdout]";
    diag "MICRO-EDITOR run stderr=[$stderr]";
    diag "MICRO-EDITOR run log=[$log_contents]";
}
else {
    diag "MICRO-EDITOR run skipped (no argv)";
}

ok( 1, 'micro editor probe dump complete' );
done_testing();
