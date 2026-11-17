#!/usr/bin/env perl
# MICRO: does the t/05 fake-bin cpanm (extensionless #!/bin/sh script) break
# the real Strawberry cpanm.bat on Windows? (t/05 line-1974 death diagnosis)
#
# Hypothesis: the product runs bare `cpanm` via IPC::Open3. On Windows
# CreateProcess skips the extensionless fake and runs the real cpanm.bat,
# whose `@perl -x -S %0` then finds the FAKE `cpanm` first on PATH by plain
# name search; perl -x scans it, finds `#!/bin/sh` (no "perl") and dies
# "No Perl script found in input" (perldiag: perl -x with no #!...perl line).
# That aborts `d2 skills install` at the cpanfile step, so Makefile/ddfile
# steps never run and the fake npx never runs, hence no npx.log -> the test
# dies at t/05 line 1974.
#
# Phase 1: fake sh cpanm only, run `cpanm --version` via IPC::Open3 (the
# product's spawn shape). Phase 2: add a fake cpanm.bat twin, run again.
# Dumps go to STDERR (prove shows them even for a passing test). Always
# passes by design; the dumps are the result.
use strict;
use warnings;
use Config qw(%Config);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3;
use Test::More;

my $tmp      = tempdir( CLEANUP => 1 );
my $fake_bin = File::Spec->catdir( $tmp, 'fake-bin' );
make_path($fake_bin);
my $log = File::Spec->catfile( $fake_bin, 'cpanm.log' );

# Fake sh cpanm, exactly as t/05 writes it.
my $fake_cpanm = File::Spec->catfile( $fake_bin, 'cpanm' );
open my $fh, '>', $fake_cpanm or die "Unable to write $fake_cpanm: $!";
print {$fh} "#!/bin/sh\nprintf '\%s\\n' \"\$*\" >> '$log'\nexit 0\n";
close $fh;
chmod 0755, $fake_cpanm or die "Unable to chmod $fake_cpanm: $!";

my $sep = $Config{path_sep};
local $ENV{PATH} = $fake_bin . $sep . ( $ENV{PATH} // '' );
diag "MICRO-CPANM os=$^O fake_bin=$fake_bin";

sub run_cpanm_version {
    my ($phase) = @_;
    my $out_file = File::Spec->catfile( $tmp, "out-$phase.txt" );
    my $err_file = File::Spec->catfile( $tmp, "err-$phase.txt" );
    open my $out_fh, '>', $out_file or die "Unable to write $out_file: $!";
    open my $err_fh, '>', $err_file or die "Unable to write $err_file: $!";
    open my $in_fh, '<', File::Spec->devnull() or die "Unable to read devnull: $!";
    my $pid = eval { open3( $in_fh, $out_fh, $err_fh, 'cpanm', '--version' ) };
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
    if ( -f $log ) {
        open my $r, '<', $log or die $!; local $/; $log_contents = <$r> // '';
        unlink $log;
    }
    $stdout =~ s/\s+\z//;
    $stderr =~ s/\s+\z//;
    $log_contents =~ s/\s+\z// if $log_contents ne 'MISSING';
    diag "MICRO-CPANM phase=$phase spawn_error=[$spawn_error] exit=$exit";
    diag "MICRO-CPANM phase=$phase stdout=[$stdout]";
    diag "MICRO-CPANM phase=$phase stderr=[$stderr]";
    diag "MICRO-CPANM phase=$phase cpanm_log=[$log_contents]";
    return $exit;
}

# Phase 1: sh fake only.
run_cpanm_version('1-sh-only');

# Phase 2: add a cmd twin for the fake, as the candidate fix would.
my $fake_bat = File::Spec->catfile( $fake_bin, 'cpanm.bat' );
open my $bfh, '>', $fake_bat or die "Unable to write $fake_bat: $!";
print {$bfh} "\@echo off\r\necho %*>>\"$log\"\r\nexit /b 0\r\n";
close $bfh;
run_cpanm_version('2-with-bat');

ok( 1, 'micro cpanm fake probe dump complete' );
done_testing();
