#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use Cwd qw(getcwd);
use Fcntl qw(:flock);
use File::Spec;
use File::Temp qw(tempdir);

# A lock is only a mutex if every contender agrees on its name. When the gate's
# lock was renamed from one fixed path to one named after the database, gates
# already running still guarded the old name - so the two populations were each
# internally exclusive and mutually invisible, and four of them ran against one
# cover_db at once, each deleting the others' data.
#
# The bridge is that a gate on the DEFAULT database takes both names. This file
# holds only the old name, the way a pre-rename gate does, and requires the
# current gate to refuse.

my $repository = getcwd();
my $gate       = File::Spec->catfile( $repository, 'script', 'coverage-gate' );

plan skip_all => "the coverage gate is not present at $gate" if !-f $gate;

my $legacy = File::Spec->catfile( $repository, '.coverage-gate.lock' );

# The real repository lock, not a private one: the behaviour under test is
# specifically about the DEFAULT database, which is the only one that ever had a
# legacy name. If a real gate is running here it already owns this, and the test
# must not interfere with it.
open my $held, '+>>', $legacy or plan skip_all => "cannot open $legacy: $!";
if ( !flock $held, LOCK_EX | LOCK_NB ) {
    plan skip_all => 'a real gate holds the legacy lock on this host';
}

plan tests => 5;

truncate $held, 0;
seek $held, 0, 0;
print {$held} "$$\n";
$held->flush if $held->can('flush');

# Purpose: run the gate and collect what it said and how it ended.
# Input: the argument list.
# Output: the exit status and the combined output.
sub run_gate {
    my @arguments = @_;

    my $output = qx{$^X \Q$gate\E @{[ join ' ', map { quotemeta } @arguments ]} 2>&1};

    return ( defined $output ? $output : '', $? >> 8 );
}

# Feature: a rename does not open a window in which the lock stops working.
# Scenario: a gate from before the rename holds the old name; a gate from after
# it starts on the same default database.
{
    my ( $output, $status ) = run_gate('t/00-load.t');

    is( $status, 4, 'a gate started after the rename is refused by one started before it' );
    like( $output, qr/refusing to run/, 'it refuses in words as well as in its exit code' );
    like( $output, qr/\Q$legacy\E/, 'it names the legacy lock, so the conflict is not a mystery' );
    like( $output, qr/pid $$\b/, 'it names the process holding that lock' );
}

# Scenario: a run with its own database never contended for the legacy name, so
# demanding it would refuse a run that conflicts with nothing - which is exactly
# the fault DD-526 was fixed to avoid, and it must not come back through the
# bridge.
{
    my $elsewhere = File::Temp::tempdir( CLEANUP => 1 );
    my ( undef, $status ) = run_gate( '--database', File::Spec->catdir( $elsewhere, 'cover_db' ), '--dry-run' );

    isnt( $status, 4, 'a run with its own database is not refused by the legacy lock it never shared' );
}

__END__

=head1 NAME

150-coverage-gate-lock-rename.t - prove the lock rename left no window in which
two gates can run

=head1 PURPOSE

Show that a gate holding only the pre-rename lock name still refuses a gate
started from the current script, and that bridging the two names does not refuse
runs which never shared a database.

=head1 WHY IT EXISTS

DD-526 gave the gate a lock. A later commit renamed that lock from one fixed
repository-wide path to one named after the database it guards, which was the
right design and was also, for the duration of the changeover, a period in which
the lock did not work at all: processes started before the rename guarded the old
name and processes started after it guarded the new one, so the two groups were
mutually invisible. Four gates ran against one C<cover_db> as a result, each
deleting the others' accumulated data and each on course to report a number that
described nothing.

The general rule is worth more than the incident. A lock is only a mutex if every
contender agrees on its name, so renaming one is never a pure refactor - during
the changeover, old and new are unsynchronised by construction. The fix is to hold
both names for one release.

A second property was found at the same time and is recorded in the script
alongside the constant: an C<flock>'s identity is an inode, not a path, so
deleting a lock file silently revokes exclusion for every process still holding
it. That is why nothing here unlinks these files.

=head1 WHEN TO USE

Run it while both names are still held, and delete it in the same change that
retires C<LEGACY_GATE_LOCK> - it is transitional by design, and a test for a
bridge that no longer exists is worse than no test.

It skips when a real gate holds the legacy lock, because on this project that is
a genuine run which must not be disturbed.

=head1 HOW TO USE

    prove -lv t/150-coverage-gate-lock-rename.t

=head1 WHAT USES IT

The full suite via C<prove -lr t>, the all-metric coverage gate, and the CI
workflow that runs both.

=head1 EXAMPLES

The pre-rename gate is impersonated rather than resurrected, since the old script
no longer exists to run. What made those processes exclusive was nothing more
than an C<flock> on a particular path, so holding that path reproduces them
exactly:

    open my $held, '+>>', $legacy;
    flock $held, LOCK_EX | LOCK_NB;
    print {$held} "$$\n";

    my ( $output, $status ) = run_gate('t/00-load.t');
    is( $status, 4, '...' );

The second scenario is the one that stops the fix over-reaching. Taking the
legacy lock for every run, rather than only for the default database, would
refuse runs that conflict with nothing - reintroducing the self-refusal bug that
made the gate unable to pass its own suite.

=cut
