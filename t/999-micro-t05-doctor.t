use strict;
use warnings;

# MICRO PROBE — NEVER MERGE. Diagnoses the Windows t/05 doctor failures
# (lines 391/423): d2 doctor reports ok=0 on Windows where the test expects
# a clean report. Dumps the full doctor report (every issue with kind/path/
# problem) plus the staged helper dir listing, on all four legs.
# Replicates the t/05 pre-doctor state minimally: fresh HOME + d2 init.
# Run as a Jenkins solo: TEST_FILE=t/999-micro-t05-doctor.t

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use Developer::Dashboard::JSON qw(json_decode);
use FindBin;

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo      = getcwd();
my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
local $ENV{HOME} = tempdir( CLEANUP => 1 );
print "MICRO-DOCTOR: HOME=$ENV{HOME}\n";
print "MICRO-DOCTOR: repo=$repo\n";

print "MICRO-DOCTOR: before init\n";
my ( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$dashboard' init", {} );
print "MICRO-DOCTOR: after init rc=$rc\n";

print "MICRO-DOCTOR: before doctor\n";
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$dashboard' doctor", {} );
print "MICRO-DOCTOR: after doctor rc=$rc\n";
print "MICRO-DOCTOR: doctor stdout=$out\n";
print "MICRO-DOCTOR: doctor stderr=$err\n";
my $report = eval { json_decode($out) };
if ( $report && ref($report) eq 'HASH' ) {
    print "MICRO-DOCTOR: ok=" . ( $report->{ok} ? 1 : 0 ) . " issue_count=" . ( $report->{issue_count} // 'undef' ) . " hook_failures=" . ( $report->{hook_failures} // 'undef' ) . "\n";
    for my $issue ( @{ $report->{issues} || [] } ) {
        print "MICRO-DOCTOR-ISSUE: kind=" . ( $issue->{kind} // '' ) . " path=" . ( $issue->{path} // '' ) . " problem=" . ( $issue->{problem} // '' ) . " current=" . ( $issue->{current_mode} // '' ) . " expected=" . ( $issue->{expected_mode} // '' ) . "\n";
    }
}
else {
    print "MICRO-DOCTOR: doctor output did not decode as JSON: " . ( $@ || 'unknown' ) . "\n";
}

print "MICRO-DOCTOR: before doctor --fix\n";
( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$dashboard' doctor --fix", {} );
print "MICRO-DOCTOR: after doctor --fix rc=$rc\n";
print "MICRO-DOCTOR: fix stdout=$out\n";
my $fixed = eval { json_decode($out) };
if ( $fixed && ref($fixed) eq 'HASH' ) {
    print "MICRO-DOCTOR: fix ok=" . ( $fixed->{ok} ? 1 : 0 ) . " issue_count=" . ( $fixed->{issue_count} // 'undef' ) . "\n";
    for my $issue ( @{ $fixed->{issues} || [] } ) {
        print "MICRO-DOCTOR-FIX-ISSUE: kind=" . ( $issue->{kind} // '' ) . " path=" . ( $issue->{path} // '' ) . " problem=" . ( $issue->{problem} // '' ) . " current=" . ( $issue->{current_mode} // '' ) . " expected=" . ( $issue->{expected_mode} // '' ) . " fixed=" . ( $issue->{fixed} ? 1 : 0 ) . "\n";
    }
}

my $dd_dir = File::Spec->catdir( $ENV{HOME}, '.developer-dashboard', 'cli', 'dd' );
if ( -d $dd_dir ) {
    opendir my $dh, $dd_dir or die "Unable to read $dd_dir: $!";
    my @files = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    print "MICRO-DOCTOR: staged helpers (" . scalar(@files) . "): @files\n";
}
else {
    print "MICRO-DOCTOR: staged helper dir MISSING: $dd_dir\n";
}

# prove without -v swallows a passing test's STDOUT, so a probe that
# always passes prints nothing anywhere. Fail deliberately at the end so
# the harness shows the dump above; the build verdict is meaningless
# for this probe — the dumped lines are the result.
fail('micro doctor probe dump complete — deliberate fail so prove shows the dump');
done_testing;
