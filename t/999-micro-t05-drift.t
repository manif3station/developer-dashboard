use strict;
use warnings;

# MICRO PROBE — NEVER MERGE. Diagnoses the NEW Windows t/05 failures at
# lines 497 ('d2 doctor reports success after helper restaging repair')
# and 536 ('d2 doctor reports success after repairing misplaced bash
# bootstrap lines') seen in Jenkins build #45 (tip 1abbd774) but NOT in
# build #38 (tip 69f88a61). The only change between those tips is the
# _dashboard-core asset (commit 1abbd774: stage a missing init helper).
# Theory: the test process loads InternalCLI from the node's EXISTING
# blib tree (stale 6.30-era code), while the doctor subprocess loads it
# from dd-source lib (the loop tip), so the test's "expected" core
# content (old) no longer matches what the doctor compares against
# (new). The drift-block restore then writes stale content, and every
# later ok=1 doctor check (497, 536) fails. This micro dumps, on all
# four legs: which InternalCLI.pm each side loads, which core asset
# each side reads, and the content hash + new/old marker; then it
# replays the drift block exactly as t/05 does (stale -> doctor ->
# --fix -> restore from the test-process expected -> doctor), and then
# restores from the SAVED staged bytes instead and re-runs doctor, to
# test the save-before-clobber fix before it is applied to t/05.
# Dumps to STDERR; passes by design. Run as a Jenkins solo:
# TEST_FILE=t/999-micro-t05-drift.t

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use Digest::SHA qw(sha256_hex);
use Developer::Dashboard::JSON qw(json_decode);
use Developer::Dashboard::InternalCLI;
use FindBin;

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo      = getcwd();
my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
local $ENV{HOME} = tempdir( CLEANUP => 1 );

sub _dump_report {
    my ( $tag, $out ) = @_;
    my $report = eval { json_decode($out) };
    if ( !$report || ref($report) ne 'HASH' ) {
        print STDERR "MICRO-DRIFT: $tag did not decode as JSON: " . ( $@ || 'unknown' ) . "\n";
        print STDERR "MICRO-DRIFT: $tag raw stdout=$out\n";
        return undef;
    }
    print STDERR "MICRO-DRIFT: $tag ok=" . ( $report->{ok} ? 1 : 0 )
      . " issue_count=" . ( $report->{issue_count} // 'undef' ) . "\n";
    for my $issue ( @{ $report->{issues} || [] } ) {
        print STDERR "MICRO-DRIFT-ISSUE: $tag kind=" . ( $issue->{kind} // '' )
          . " path=" . ( $issue->{path} // '' )
          . " problem=" . ( $issue->{problem} // '' )
          . " current=" . ( $issue->{current_mode} // '' )
          . " fixed=" . ( $issue->{fixed} ? 1 : 0 ) . "\n";
    }
    return $report;
}

sub _slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Unable to read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh or die "Unable to close $path: $!";
    return $content;
}

# --- Side A: the test process itself (what t/05 line 437 reads) ---
my $test_inc = $INC{'Developer/Dashboard/InternalCLI.pm'} // 'undef';
print STDERR "MICRO-DRIFT: test-process InternalCLI INC=$test_inc\n";
my $test_asset = Developer::Dashboard::InternalCLI::_helper_asset_path('_dashboard-core');
print STDERR "MICRO-DRIFT: test-process core asset=$test_asset\n";
my $test_expected = Developer::Dashboard::InternalCLI::_managed_helper_content('_dashboard-core');
print STDERR "MICRO-DRIFT: test-process expected len=" . length($test_expected)
  . " sha=" . sha256_hex($test_expected)
  . " has_init_target=" . ( index( $test_expected, 'init_target' ) >= 0 ? 1 : 0 ) . "\n";

# --- Side B: a subprocess with -I'$lib', exactly like the doctor runs ---
my $probe_file = File::Spec->catfile( $ENV{HOME}, 'drift-probe.pl' );
open my $probe_fh, '>', $probe_file or die "Unable to write $probe_file: $!";
print {$probe_fh} <<'PROBE';
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Developer::Dashboard::InternalCLI;
my $inc = $INC{'Developer/Dashboard/InternalCLI.pm'} // 'undef';
my $asset = Developer::Dashboard::InternalCLI::_helper_asset_path('_dashboard-core');
my $content = Developer::Dashboard::InternalCLI::_managed_helper_content('_dashboard-core');
print "PROBE-INC:$inc\n";
print "PROBE-ASSET:$asset\n";
print "PROBE-LEN:" . length($content) . "\n";
print "PROBE-SHA:" . sha256_hex($content) . "\n";
print "PROBE-NEW:" . ( index( $content, 'init_target' ) >= 0 ? 1 : 0 ) . "\n";
PROBE
close $probe_fh or die "Unable to close $probe_file: $!";
my ( $pout, $perr, $prc ) = run_shell_command( "$perl -I'$lib' '$probe_file'", {} );
print STDERR "MICRO-DRIFT: subprocess probe rc=$prc\n";
for my $line ( split /\r?\n/, $pout ) {
    print STDERR "MICRO-DRIFT: subprocess $line\n" if $line ne '';
}
print STDERR "MICRO-DRIFT: subprocess stderr=$perr\n" if $perr ne '';

# --- Replay the t/05 drift block (lines ~437-497) ---
my $runtime_dd_cli_root = File::Spec->catdir( $ENV{HOME}, '.developer-dashboard', 'cli', 'dd' );
my $runtime_doctor = File::Spec->catfile( $runtime_dd_cli_root, 'doctor' );
my $runtime_dashboard_core = File::Spec->catfile( $runtime_dd_cli_root, '_dashboard-core' );

print STDERR "MICRO-DRIFT: before init\n";
my ( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$dashboard' init", {} );
print STDERR "MICRO-DRIFT: after init rc=$rc\n";

my $staged_before = _slurp_raw($runtime_dashboard_core);
print STDERR "MICRO-DRIFT: staged core before drift len=" . length($staged_before)
  . " sha=" . sha256_hex($staged_before)
  . " has_init_target=" . ( index( $staged_before, 'init_target' ) >= 0 ? 1 : 0 ) . "\n";

my $managed_core_stale = $test_expected . "\n# stale helper drift\n";
open my $stale_fh, '>:raw', $runtime_dashboard_core or die "Unable to write $runtime_dashboard_core: $!";
print {$stale_fh} $managed_core_stale;
close $stale_fh or die "Unable to close $runtime_dashboard_core: $!";

print STDERR "MICRO-DRIFT: before doctor (stale)\n";
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$runtime_doctor'", {} );
_dump_report( 'doctor-stale', $out );

print STDERR "MICRO-DRIFT: before doctor --fix\n";
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$runtime_doctor' --fix", {} );
_dump_report( 'doctor-fix', $out );

# t/05's restore: write the TEST-process expected content back.
open my $restore_fh, '>:raw', $runtime_dashboard_core or die "Unable to write $runtime_dashboard_core: $!";
print {$restore_fh} $test_expected;
close $restore_fh or die "Unable to close $runtime_dashboard_core: $!";
print STDERR "MICRO-DRIFT: before doctor (after t/05-style restore)\n";
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$runtime_doctor'", {} );
my $after_restore = _dump_report( 'doctor-after-test-restore', $out );

# Proposed fix: restore from the SAVED staged bytes instead.
open my $save_fh, '>:raw', $runtime_dashboard_core or die "Unable to write $runtime_dashboard_core: $!";
print {$save_fh} $staged_before;
close $save_fh or die "Unable to close $runtime_dashboard_core: $!";
print STDERR "MICRO-DRIFT: before doctor (after saved-bytes restore)\n";
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$runtime_doctor'", {} );
my $after_saved = _dump_report( 'doctor-after-saved-restore', $out );

# Quick bashrc collateral check (t/05 line ~536): with the core clean, the
# bash-bootstrap repair should end in a clean doctor run.
my $bashrc = File::Spec->catfile( $ENV{HOME}, '.bashrc' );
my $local_lib_line = qq{eval "\$("/usr/bin/perl" -I "$ENV{HOME}/perl5/lib/perl5" -Mlocal::lib)"};
my $dashboard_line = qq{eval "\$("$ENV{HOME}/perl5/bin/d2" shell bash)"};
open my $bashrc_fh, '>', $bashrc or die "Unable to write $bashrc: $!";
print {$bashrc_fh} "[ -z \"\$PS1\" ] && return\n$local_lib_line\n$dashboard_line\n";
close $bashrc_fh or die "Unable to close $bashrc: $!";
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$runtime_doctor'", {} );
_dump_report( 'doctor-bashrc-misplaced', $out );
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$runtime_doctor' --fix", {} );
_dump_report( 'doctor-bashrc-fix', $out );
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$runtime_doctor'", {} );
my $bashrc_clean = _dump_report( 'doctor-bashrc-clean', $out );

print STDERR "MICRO-DRIFT: summary test-restore-ok=" . ( $after_restore && $after_restore->{ok} ? 1 : 0 )
  . " saved-restore-ok=" . ( $after_saved && $after_saved->{ok} ? 1 : 0 )
  . " bashrc-clean-ok=" . ( $bashrc_clean && $bashrc_clean->{ok} ? 1 : 0 ) . "\n";

# The dumps above go to STDERR, which prove passes through even for a
# passing test. This probe PASSES by design; the dumped lines are the result.
pass('micro drift probe ran');
done_testing;
