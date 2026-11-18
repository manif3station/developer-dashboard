use strict;
use warnings;

# MICRO (scratch only, never merge): why does `d2 of` blank-enter exit 2
# and open matches WITHOUT the vim -p flag on Windows (build #81, tests
# 694/696)? The fake editor log in #81 showed both files with no -p,
# which is exactly what the previous multi-select test left behind - so
# the log may be STALE and the fake vim may never have run at all.
# Candidates:
#   (a) the extensionless fake `vim` (a #!/bin/sh script) cannot be
#       spawned on Windows at all, so the editor never runs and the
#       command dies with exit 2 (same family as the docker fake);
#   (b) the editor runs but the -p flag decision differs on Windows;
#   (c) a REAL vim on the node's PATH runs instead of the fake.
# Each case prints its raw outcome with diag.

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use Cwd qw(getcwd);
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);
use Developer::Dashboard::CLI::OpenFileChooser qw(_editor_supports_tabs);
use Developer::Dashboard::Platform qw(command_in_path);

my $is_windows = $^O eq 'MSWin32';
my $repo = getcwd();
my $lib = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
my $perl = $^X;

# Same fixtures as t/05's open-file block, in a fresh temp HOME.
my $tmp_home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $tmp_home;
my $open_root = File::Spec->catdir( $tmp_home, 'open-file-fixtures' );
make_path($open_root);
for my $name ( 'alpha-notes.txt', 'alpha-second.txt' ) {
    open my $fh, '>', File::Spec->catfile( $open_root, $name ) or die $!;
    print {$fh} "alpha\n";
    close $fh;
}
my $fake_editor_bin = File::Spec->catdir( $tmp_home, 'fake-editor-bin' );
make_path($fake_editor_bin);
my $fake_editor_log = File::Spec->catfile( $tmp_home, 'fake-editor.log' );

my $fake_vim = File::Spec->catfile( $fake_editor_bin, 'vim' );
open my $vfh, '>', $fake_vim or die "Unable to write $fake_vim: $!";
print {$vfh} <<"SH";
#!/bin/sh
printf '%s\\n' "\$*" > '$fake_editor_log'
SH
close $vfh;
chmod 0755, $fake_vim or die "Unable to chmod $fake_vim: $!";

sub read_log {
    open my $fh, '<', $fake_editor_log or return '<no log file>';
    my $content = do { local $/; <$fh> };
    close $fh;
    return defined $content ? $content : '<empty>';
}

sub write_sentinel {
    open my $fh, '>', $fake_editor_log or die "Unable to write $fake_editor_log: $!";
    print {$fh} "SENTINEL\n";
    close $fh;
}

sub run_blank_enter {
    my ( $out, $err, $exit ) = run_shell_command(
        "printf '\\n' | PATH='$fake_editor_bin':\"\$PATH\" $perl -I'$lib' '$dashboard' of '$open_root' alpha",
        {},
    );
    return ( $out . $err, $exit );
}

# CASE 1: is there a REAL vim anywhere on PATH (excluding fake-editor-bin)?
{
    my @real_vims;
    for my $dir ( File::Spec->path() ) {
        next if !defined $dir || $dir eq '';
        next if File::Spec->canonpath($dir) eq File::Spec->canonpath($fake_editor_bin);
        for my $cand ( 'vim.exe', 'vim.bat', 'vim.cmd', 'vim.com', 'vim' ) {
            my $p = File::Spec->catfile( $dir, $cand );
            push @real_vims, $p if -f $p;
        }
    }
    diag 'CASE 1 real vim on PATH (outside fake-editor-bin): ' . ( @real_vims ? join( ', ', @real_vims ) : 'none' );
    ok( 1, 'CASE 1: real-vim scan recorded' );
}

# CASE 2: does the -p decision itself say yes for vim?
{
    my $supports = _editor_supports_tabs( command => ['vim'] );
    diag "CASE 2 _editor_supports_tabs(['vim']): $supports";
    ok( $supports, 'CASE 2: vim is a tab-supporting editor' );
}

# CASE 3: end-to-end blank-enter with the extensionless fake vim only.
# A sentinel in the log proves whether the fake ran at all.
{
    write_sentinel();
    my ( $combined, $exit ) = run_blank_enter();
    my $log = read_log();
    diag "CASE 3 extensionless vim only: exit=$exit log=[$log]";
    if ($is_windows) {
        ok( $exit != 0, 'CASE 3 Windows: blank-enter exits non-zero with the extensionless fake vim' );
        diag "CASE 3 Windows: log still sentinel means the fake vim never ran; log rewritten means it ran without -p";
    }
    else {
        ok( $exit == 0 && $log =~ /^-p /, 'CASE 3 Unix: blank-enter exits 0 and opens all matches with -p' );
    }
}

# CASE 4: add a vim.bat twin and repeat end-to-end.
my $fake_vim_bat = File::Spec->catfile( $fake_editor_bin, 'vim.bat' );
open my $bfh, '>', $fake_vim_bat or die "Unable to write $fake_vim_bat: $!";
print {$bfh} <<"BAT";
\@echo off
echo %*>"$fake_editor_log"
BAT
close $bfh;
{
    write_sentinel();
    my ( $combined, $exit ) = run_blank_enter();
    my $log = read_log();
    diag "CASE 4 with vim.bat twin: exit=$exit log=[$log]";
    ok( $exit == 0 && $log =~ /^-p /, 'CASE 4: blank-enter exits 0 and opens all matches with -p once the vim.bat twin exists' );
}

done_testing();
