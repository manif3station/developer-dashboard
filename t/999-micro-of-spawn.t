use strict;
use warnings;

# MICRO v2 (scratch only, never merge): build #82 proved the extensionless
# fake vim never runs on Windows and a vim.bat twin does NOT fix the
# end-to-end `d2 of` blank-enter run either (exit 2, log still SENTINEL).
# An SSH probe on win-ts then showed the split is in the SPAWN FORM:
#   A block-form system { 'vim' } : rc=65280, ENOENT, log SENTINEL (even
#     WITH a vim.bat twin present - the block form never finds .bat);
#   E list-form system('vim', ...) : rc=0 with the twin, log starts -p;
#   F cmd /c with the twin : rc=0, log starts -p.
# The product's _exec_raw uses the BLOCK form, so on Windows it can never
# reach the fake editor. Two questions remain, both Jenkins-env only:
#   (1) what editor does the Jenkins leg actually resolve (EDITOR/VISUAL
#       in the leg's environment may differ from an SSH session);
#   (2) what rc does the block form return INSIDE the Jenkins leg - the
#       product exits 2, which is exit(512 >> 8), so the leg's spawn must
#       return 512, not the 65280 the SSH probe saw.
# This micro re-runs the spawn probe inside the Jenkins leg and prints
# the full end-to-end output, so the fix targets the real behaviour.

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use Cwd qw(getcwd);
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);
use Developer::Dashboard::CLI::OpenFile ();

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
my @target_files;
for my $name ( 'alpha-notes.txt', 'alpha-second.txt' ) {
    my $p = File::Spec->catfile( $open_root, $name );
    open my $fh, '>', $p or die $!;
    print {$fh} "alpha\n";
    close $fh;
    push @target_files, $p;
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

# CASE 1: what editor does THIS leg's environment resolve?
{
    diag 'CASE 1 EDITOR=[' . ( $ENV{EDITOR} // '' ) . '] VISUAL=[' . ( $ENV{VISUAL} // '' ) . ']';
    my @editor = Developer::Dashboard::CLI::OpenFile::_default_editor('');
    diag 'CASE 1 _default_editor(""): [' . join( ' ', @editor ) . ']';
    ok( 1, 'CASE 1: editor resolution recorded' );
}

# CASE 2: run the spawn probe (all six variants) inside this leg.
my $probe = File::Spec->catfile( $tmp_home, 'probe-of-spawn.pl' );
{
    open my $pfh, '>', $probe or die "Unable to write $probe: $!";
    print {$pfh} do { local $/; <DATA> };
    close $pfh;
}
my $probe_out;
{
    my ( $out, $err, $exit ) = run_shell_command(
        "PATH='$fake_editor_bin':\"\$PATH\" $perl '$probe' '$fake_editor_bin' '$fake_editor_log' '$target_files[0]' '$target_files[1]'",
        {},
    );
    $probe_out = $out . $err;
    diag "CASE 2 spawn probe (exit=$exit):\n$probe_out";
    ok( $probe_out =~ /E list-form with vim\.bat: rc=0/ && $probe_out =~ /log=\[-p /,
        'CASE 2: list-form system() finds the vim.bat twin in this leg' );
}

# CASE 3: what rc does the BLOCK form return in this leg?
{
    my ($a_rc) = $probe_out =~ /A block-form extensionless-only: rc=(\d+)/;
    my ($d_rc) = $probe_out =~ /D block-form with vim\.bat: rc=(\d+)/;
    diag "CASE 3 block-form rc: extensionless-only=" . ( defined $a_rc ? $a_rc : '?' )
      . " with-vim.bat=" . ( defined $d_rc ? $d_rc : '?' )
      . " (product exit 2 implies rc 512; SSH probe saw 65280)";
    if ($is_windows) {
        ok( defined $a_rc && $a_rc != 0 && defined $d_rc && $d_rc != 0,
            'CASE 3: block-form system() fails in this leg with and without the twin' );
    }
    else {
        ok( defined $a_rc && $a_rc == 0,
            'CASE 3 Unix: block-form system() runs the fake vim' );
    }
}

# CASE 4: end-to-end blank-enter WITH the vim.bat twin (the probe wrote it).
# Print the FULL output: any "Can't exec" / "Unable to run" line decides
# whether the process dies in _command_exec (exit 255) or in _exec_raw
# exit(rc >> 8) (exit 2).
{
    write_sentinel();
    my ( $combined, $exit ) = run_blank_enter();
    my $log = read_log();
    $combined =~ s/\n/\\n/g;
    $log =~ s/\n/\\n/g;
    diag "CASE 4 with vim.bat twin: exit=$exit log=[$log] output=[$combined]";
    ok( $exit == 0 && $log =~ /^-p /, 'CASE 4: blank-enter exits 0 and opens all matches with -p once the vim.bat twin exists' );
}

# CASE 5: end-to-end blank-enter WITHOUT the twin (baseline).
{
    my $bat = File::Spec->catfile( $fake_editor_bin, 'vim.bat' );
    unlink $bat;
    write_sentinel();
    my ( $combined, $exit ) = run_blank_enter();
    my $log = read_log();
    $combined =~ s/\n/\\n/g;
    $log =~ s/\n/\\n/g;
    diag "CASE 5 extensionless only: exit=$exit log=[$log] output=[$combined]";
    if ($is_windows) {
        ok( $exit != 0, 'CASE 5 Windows: blank-enter exits non-zero with the extensionless fake vim' );
    }
    else {
        ok( $exit == 0 && $log =~ /^-p /, 'CASE 5 Unix: blank-enter exits 0 and opens all matches with -p' );
    }
}

done_testing();

__DATA__
use File::Spec;
use strict;
use warnings;

my ( $fake_bin, $log, $f1, $f2 ) = @ARGV;
die "usage: $0 <fake-bin> <log> <file1> <file2>\n" if !defined $f2;

open STDIN, '<', File::Spec->devnull() or die "Unable to open devnull for stdin: $!";
my $path_sep = $^O eq 'MSWin32' ? ';' : ':';
$ENV{PATH} = $fake_bin . $path_sep . ( $ENV{PATH} // '' );

print "EDITOR=[" . ( $ENV{EDITOR} // '' ) . "]\n";
print "VISUAL=[" . ( $ENV{VISUAL} // '' ) . "]\n";
print "PATH has fake-bin: ", ( index( $ENV{PATH}, $fake_bin ) >= 0 ? "yes\n" : "NO\n" );

sub read_log {
    open my $fh, '<', $log or return '<no log file>';
    my $content = do { local $/; <$fh> };
    close $fh;
    return defined $content ? $content : '<empty>';
}

sub write_sentinel {
    open my $fh, '>', $log or die "Unable to write $log: $!";
    print {$fh} "SENTINEL\n";
    close $fh;
}

sub run_variant {
    my ( $label, $code ) = @_;
    write_sentinel();
    my $rc = $code->();
    my $bang = $!;
    my $quest = $?;
    my $log_content = read_log();
    $log_content =~ s/\n/\\n/g;
    print "$label: rc=$rc bang=[$bang] quest=$quest log=[$log_content]\n";
}

run_variant( 'A block-form extensionless-only', sub {
    local $SIG{__WARN__} = sub { return };
    $! = 0;
    return system { 'vim' } ( 'vim', '-p', $f1, $f2 );
} );

run_variant( 'B list-form extensionless-only', sub {
    local $SIG{__WARN__} = sub { return };
    $! = 0;
    return system( 'vim', '-p', $f1, $f2 );
} );

run_variant( 'C cmd-/c extensionless-only', sub {
    local $SIG{__WARN__} = sub { return };
    $! = 0;
    return system( 'cmd', '/c', 'vim', '-p', $f1, $f2 );
} );

print "--- now writing vim.bat twin ---\n";
my $bat = "$fake_bin\\vim.bat";
open my $bfh, '>', $bat or die "Unable to write $bat: $!";
print {$bfh} "\@echo off\r\n";
print {$bfh} "echo \%*>" . $log . "\r\n";
close $bfh;

run_variant( 'D block-form with vim.bat', sub {
    local $SIG{__WARN__} = sub { return };
    $! = 0;
    return system { 'vim' } ( 'vim', '-p', $f1, $f2 );
} );

run_variant( 'E list-form with vim.bat', sub {
    local $SIG{__WARN__} = sub { return };
    $! = 0;
    return system( 'vim', '-p', $f1, $f2 );
} );

run_variant( 'F cmd-/c with vim.bat', sub {
    local $SIG{__WARN__} = sub { return };
    $! = 0;
    return system( 'cmd', '/c', 'vim', '-p', $f1, $f2 );
} );

print "probe done\n";
