#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use POSIX qw(strftime);
use Time::Local qw(timegm);
use Test::More;

my $ROOT       = File::Spec->rel2abs( File::Spec->catdir( $FindBin::Bin, File::Spec->updir ) );
my $PERL_GATE  = File::Spec->catfile( $ROOT, 'script', 'cpan-audit-declared-chain' );
my $BASH_GATE  = File::Spec->catfile( $ROOT, 'script', 'cpan-audit-project' );
my $GATE_SRC   = $PERL_GATE;

plan skip_all => "declared-chain gate not present at $PERL_GATE" if !-f $PERL_GATE;
plan skip_all => "project gate not present at $BASH_GATE"        if !-f $BASH_GATE;

# WHY THIS FILE EXISTS (DD-790)
#   On 2026-09-06 both CVE gates reported the declared runtime closure clean.
#   The verdict was true of what they read and useless as an answer: the advisory
#   database was CPANSA::DB 20260807.001, thirty days old, and did not contain URI
#   at all. A real advisory against the installed URI 5.34 could not have been
#   reported by that run - not missed, but STRUCTURALLY UNREPORTABLE. The gate said
#   "clean" with exactly the confidence it uses when it has looked.
#
#   Upstream already knows a stale database is worth mentioning: cpan-audit --fresh
#   prints "Database is N days old" through CPAN::Audit::FreshnessCheck, with the
#   threshold in CPAN_AUDIT_FRESH_DAYS. Measured on 2026-09-06, that warning goes to
#   STDERR and does NOT change the exit code - 91 with the flag and 91 without. So no
#   caller reading a status can see it. That is the right call for an interactive
#   audit and the wrong one for a release gate, and this file pins the escalation:
#   the age reaches the VERDICT, and the corpus is NAMED on every run.
#
# WHAT THIS FILE DELIBERATELY DOES NOT ASSERT
#   It never accepts a bare exit 2 as proof of an age refusal. Both gates already
#   exit 2 for unrelated reasons - an unreadable root, absent .meta files, a
#   cpanfile with no runtime requirements - so an assertion on the status alone
#   would pass against the UNMODIFIED gates and certify nothing. Every check here
#   requires a positive marker that only the new code can emit: the database stamp
#   itself, or a refusal naming the age in days. This is the project's own
#   "verify the subject actually ran" rule, applied to an exit code that is already
#   reachable by another path.

# Purpose: an advisory-database stamp N days from today, in CPANSA's own
#          YYYYMMDD.NNN form.
# Input:   $days_ago - integer days before today.
# Output:  the stamp string.
#
# Computed from time() rather than written as a literal, so the file does not rot:
# a hardcoded "fresh" stamp becomes stale by the calendar and the test starts
# failing for a reason that has nothing to do with the code.
sub _stamp {
    my ($days_ago) = @_;
    return strftime( '%Y%m%d', localtime( time - $days_ago * 86_400 ) ) . '.001';
}

# Purpose: a library directory shadowing CPAN::Audit::DB with a chosen stamp.
# Input:   $stamp - the version the fake database reports.
# Output:  the directory to prepend to PERL5LIB.
#
# The Perl gate loads the database IN-PROCESS (require CPAN::Audit::DB), so a PATH
# shim cannot reach it - the mechanism that works for the bash gate is useless here.
# db() returns an empty dists map so the audit itself finds nothing: this file is
# about the CORPUS, and depending on the real advisory set would make it pass or
# fail for reasons unrelated to the code under test.
sub _fake_db_lib {
    my ($stamp) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my $pkg = File::Spec->catdir( $dir, 'CPAN', 'Audit' );
    make_path($pkg);
    open my $fh, '>', File::Spec->catfile( $pkg, 'DB.pm' ) or die "cannot write fake DB: $!";
    print {$fh} <<"FAKE";
package CPAN::Audit::DB;
our \$VERSION = '$stamp';
sub db { return { dists => {} } }
1;
FAKE
    close $fh;
    return $dir;
}

# Purpose: run the Perl gate against a chosen database stamp.
# Input:   $stamp, %env - extra environment (CPAN_AUDIT_FRESH_DAYS).
# Output:  ($exit, $combined_output)
#
# The status is read from CHILD_ERROR_NATIVE, never through a pipe: a pipe reports
# the LAST stage's status, which has already laundered a gate result on this project
# and did so again while this card was being researched.
sub _run_perl_gate {
    my ( $stamp, %env ) = @_;
    my $lib  = _fake_db_lib($stamp);
    my $root = tempdir( CLEANUP => 1 );
    local $ENV{PERL5LIB} = join ':', $lib, ( $ENV{PERL5LIB} // () );
    local @ENV{ keys %env } = values %env;
    my $out = `$^X \Q$PERL_GATE\E \Q$root\E 2>&1`;
    return ( ${^CHILD_ERROR_NATIVE} >> 8, $out );
}

# Purpose: a cpan-audit shim whose --version names a chosen database stamp.
# Input:   $stamp
# Output:  the directory to prepend to PATH.
#
# It answers --version in cpan-audit's real layout, indented under "using:", because
# the gate has to parse what the binary actually prints. The audit runs report no
# advisories, so any refusal observed here is about the CORPUS and not the findings.
sub _version_shim {
    my ($stamp) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my $bin = File::Spec->catfile( $dir, 'cpan-audit' );
    open my $fh, '>', $bin or die "cannot write shim: $!";
    print {$fh} <<"SHIM";
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "--version" ]; then
    echo "cpan-audit version 1.503 using:"
    echo "	CPAN::Audit      20260622.001"
    echo "	CPANSA::DB       $stamp"
    exit 0
  fi
done
exit 0
SHIM
    close $fh;
    chmod 0755, $bin;
    return $dir;
}

# Purpose: run the bash gate with a shimmed cpan-audit.
# Input:   $stamp, %env
# Output:  ($exit, $combined_output)
sub _run_bash_gate {
    my ( $stamp, %env ) = @_;
    my $tmp  = tempdir( CLEANUP => 1 );
    my $root = File::Spec->catdir( $tmp, 'local', 'lib', 'perl5' );
    make_path($root);
    local $ENV{PATH} = join ':', _version_shim($stamp), $ENV{PATH};
    local $ENV{DD_CPAN_AUDIT_ALLOW_EXTERNAL_ROOT} = 1;
    local @ENV{ keys %env } = values %env;
    my $out = `bash \Q$BASH_GATE\E \Q$root\E 2>&1`;
    return ( ${^CHILD_ERROR_NATIVE} >> 8, $out );
}

my $FRESH = _stamp(0);
my $STALE = _stamp(400);
my $MID   = _stamp(5);      # inside the default limit, outside a tightened one

# The phrase "N days old" appears in the CORPUS REPORT by design, on every run,
# including accepted ones. So a matcher looking for it cannot tell a report from a
# refusal - the first version of this file used exactly that matcher and reported
# a refusal on a run that had accepted the database. That is this file's own subject
# in miniature: a signal being PRESENT is not the verdict having CHANGED, and the
# assertion has to name the half it means. REFUSAL matches only the declining
# sentence, which carries the configured limit; the report never does.
my $REFUSAL = qr/advisory database is \d+ days? old .* and the limit is \d+/i;

# AC-0: the date arithmetic itself, against an INDEPENDENT ORACLE.
#
# The gate deliberately does its own days-from-civil arithmetic rather than using
# Time::Local, so that no timezone rule or year-interpretation heuristic can move a
# release decision. That choice is only safe if the arithmetic is right, and until
# now it was exercised only indirectly, through two stamps that happen to sit far
# apart. Leap years and century rules were untested.
#
# The oracle is Time::Local rather than hand-written constants, and that is not
# fussiness: writing this check the first time with constants I worked out myself,
# one of eight was wrong - the CODE was correct and MY EXPECTATION was not. A test
# whose expected values come from the same head as the argument for the code proves
# only that the head is self-consistent.
{
    my $gate_src = do {
        open my $fh, '<', $GATE_SRC or die "cannot read gate: $!";
        local $/;
        <$fh>;
    };
    my ($body) = $gate_src =~ /(sub _days_from_civil \{.*?\n\})/s;
    ok $body, 'the gate still defines _days_from_civil (this spec reads the real one)';

    my $dfc = eval "$body; \\&_days_from_civil";
    die "could not load _days_from_civil: $@" if !$dfc;

    # Cases chosen for the rules that actually differ between calendars, not for
    # coverage of a range: both century rules, an ordinary leap year, and a date
    # before the epoch so a negative result is exercised.
    for my $case (
        [ 1970, 1,  1,  'the civil epoch' ],
        [ 1969, 12, 31, 'the day before the epoch - a negative result' ],
        [ 2000, 2,  29, '2000 IS a leap year: divisible by 400' ],
        [ 1900, 3,  1,  '1900 is NOT a leap year: divisible by 100, not 400' ],
        [ 2024, 2,  29, 'an ordinary leap year' ],
        [ 2026, 9,  6,  'a date in the range this gate actually sees' ],
      )
    {
        my ( $y, $m, $d, $why ) = @{$case};
        my $oracle = timegm( 0, 0, 0, $d, $m - 1, $y ) / 86_400;
        is $dfc->( $y, $m, $d ), $oracle, "days_from_civil agrees with Time::Local: $why";
    }
}

# AC-1: the Perl gate names its corpus on EVERY run, including a clean one.
# The clean path is the one people believe, so it is the one that must carry the
# stamp. A gate that names the database only when refusing tells you what it read
# exactly when you no longer need to know.
{
    my ( undef, $out ) = _run_perl_gate($FRESH);
    like $out, qr/\Q$FRESH\E/,
      'declared-chain names the advisory database stamp it audited against';
}

# AC-2: a database past the threshold is refused, and the refusal NAMES the age.
# Asserting on the message, not on the status: exit 2 is already reachable here
# through _unusable for an unreadable root or absent metadata, so a status-only
# assertion would pass against the unmodified gate.
{
    my ( $exit, $out ) = _run_perl_gate($STALE);
    like $out, $REFUSAL,
      'declared-chain refuses a stale database with a message naming its age';
    like $out, qr/\Q$STALE\E/,
      'the stale refusal names the offending stamp, not just the fact of staleness';
    # THIS ASSERTION CANNOT STAND ALONE, measured rather than supposed: run against
    # the unmodified gate it PASSED, because _unusable already exits 2 for an
    # unreadable root. It is meaningful only beside the two message assertions
    # above. Deleting either of them leaves a check that certifies nothing while
    # still going green.
    is $exit, 2,
      'the stale refusal uses the existing UNUSABLE exit rather than a new code';
}

# AC-3: the threshold is upstream's knob, and it moves the verdict BOTH ways.
# A guard only ever seen to fire proves it can fire, not that it discriminates.
{
    my ( undef, $default ) = _run_perl_gate($MID);
    unlike $default, $REFUSAL,
      'a 5-day-old database is accepted under the default limit';

    my ( undef, $tight ) = _run_perl_gate( $MID, CPAN_AUDIT_FRESH_DAYS => 2 );
    like $tight, $REFUSAL,
      'the SAME database is refused once CPAN_AUDIT_FRESH_DAYS drops below its age';

    my ( undef, $loose ) = _run_perl_gate( $STALE, CPAN_AUDIT_FRESH_DAYS => 9999 );
    unlike $loose, $REFUSAL,
      'CPAN_AUDIT_FRESH_DAYS=9999 accepts a 400-day database (guard is not stuck on)';
    like $loose, qr/\Q$STALE\E/,
      'and the stamp is still named when the age is accepted - reporting is not conditional on judging';
}

# AC-4: the bash gate takes its stamp from the binary it actually shells out to.
# A perl one-liner here could resolve a different @INC than the cpan-audit on PATH
# and report a stamp for a database no verdict came from - this card's own defect,
# reproduced inside its fix.
{
    my ( undef, $out ) = _run_bash_gate($FRESH);
    like $out, qr/\Q$FRESH\E/,
      'cpan-audit-project names the database stamp reported by the binary it invokes';
}

# AC-5: the bash gate refuses a stale database, naming the age.
{
    my ( $exit, $out ) = _run_bash_gate($STALE);
    like $out, $REFUSAL,
      'cpan-audit-project refuses a stale database with a message naming its age';

    # FOUR, not two. The two gates do not share an exit vocabulary and this file
    # originally assumed they did: in cpan-audit-project, 2 is a USAGE error and 4
    # is "the gate could not run at all". The script's own header states the reason
    # this distinction was bought - "a gate that cannot look must never be mistaken
    # for a gate that looked and found something" (DD-517) - which is exactly what
    # an unusably old advisory database is. Collapsing it into 2 would tell CI the
    # caller mistyped an argument.
    is $exit, 4,
      'and uses cpan-audit-project OWN could-not-run exit, not the Perl gate 2';
}

# AC-6: the same knob, the same both-direction behaviour, in the bash gate.
{
    my ( undef, $loose ) = _run_bash_gate( $STALE, CPAN_AUDIT_FRESH_DAYS => 9999 );
    unlike $loose, $REFUSAL,
      'CPAN_AUDIT_FRESH_DAYS=9999 accepts a stale database in the bash gate too';
    like $loose, qr/\Q$STALE\E/,
      'and the stamp is still printed when accepted';
}

done_testing;

__END__

=head1 NAME

t/172-cpan-audit-database-age.t - the CVE gates must name the advisory database
they audited against, and refuse to answer from a stale one

=head1 PURPOSE

Assert that both CVE gates - C<script/cpan-audit-declared-chain> and
C<script/cpan-audit-project> - report the identity of the advisory database
behind every verdict, and decline to produce a verdict at all once that database
is older than C<CPAN_AUDIT_FRESH_DAYS>.

=head1 WHY IT EXISTS

On 2026-09-06 both gates reported the declared runtime closure clean while the
advisory database was thirty days old and did not contain C<URI> at all. The
installed C<URI> was 5.34 and a real advisory against it existed upstream. The
clean verdict was not a miss; the run was structurally incapable of producing the
finding, and said "clean" in the same words it uses when it has genuinely looked.

Two clean runs were then cited as evidence in a cross-session investigation and
narrowed another agent's search away from the true cause. A verdict whose validity
rests on a corpus the tool never names cannot be audited by its reader, because
nothing in the output distinguishes "nothing is wrong" from "nothing could have
been found".

Upstream already treats database age as worth reporting - C<cpan-audit --fresh>
warns through C<CPAN::Audit::FreshnessCheck> - but the warning goes to STDERR and
leaves the exit status unchanged (measured: 91 with the flag and 91 without). This
file pins the escalation of that existing signal into the verdict, rather than the
invention of a competing age policy.

=head1 WHEN TO USE

Whenever either CVE gate script changes, whenever the advisory database module or
its accessor changes, and before trusting any archived gate output as evidence
that a release was audited.

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/172-cpan-audit-database-age.t

The file is hermetic. The Perl gate is exercised against a temporary library that
shadows C<CPAN::Audit::DB> with a chosen stamp; the bash gate is exercised against
a C<cpan-audit> shim whose C<--version> names one. Neither reads the host's real
advisory database, so the file cannot pass or fail because of what upstream
published today.

=head1 WHAT USES IT

The suite, through C<prove -lr t>, and therefore the unit-test gate on every card
touching either script. CI runs it at the same step as the other audit specs.

=head1 EXAMPLES

To see the specs fail the way they were written to fail, remove the age check from
C<script/cpan-audit-declared-chain>: AC-1 through AC-3 then report a gate that
audits, answers, and never says what it read.

=cut
