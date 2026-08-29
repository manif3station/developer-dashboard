#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use Cwd qw(getcwd);
use Fcntl qw(:flock);
use File::Spec;
use File::Temp qw(tempdir);

# DD-526 renamed the gate's lock. A lock is only a mutex if every contender agrees
# on its name, so for as long as any process that started before the rename is
# still running, it guards the old filename and excludes nobody. That is not a
# theoretical window: three gates ran against one cover_db across it, each
# deleting the others' data and each reporting a number that meant nothing.
#
# The bridge is that a run on the DEFAULT database must also hold the old name.
# The restriction matters as much as the bridge - a run given its own --database
# was never in conflict with anything, and making it contend for one
# repository-wide file is the bug that stopped the gate passing its own suite.

my $repository = getcwd();
my $gate       = File::Spec->catfile( $repository, 'script', 'coverage-gate' );

plan skip_all => "the coverage gate is not present at $gate" if !-f $gate;

my $legacy_path = File::Spec->catfile( $repository, '.coverage-gate.lock' );

open my $legacy, '+>>', $legacy_path or plan skip_all => "cannot open $legacy_path: $!";

# Stand in for a gate that started before the rename. If it cannot be taken, a
# real gate holds it, and this test must not interfere with a genuine run.
if ( !flock $legacy, LOCK_EX | LOCK_NB ) {
    plan skip_all => 'a real gate holds the previous lock name on this host';
}

plan tests => 5;

truncate $legacy, 0;
seek $legacy, 0, 0;
print {$legacy} "$$\n";
$legacy->flush if $legacy->can('flush');

my $stub_dir = tempdir( CLEANUP => 1 );
_write_stub( File::Spec->catfile( $stub_dir, 'prove' ), "#!/bin/sh\nexit 0\n" );
_write_stub( File::Spec->catfile( $stub_dir, 'cover' ), "#!/bin/sh\nexit 0\n" );

# The default database is the one that has to be bridged, because that is the one
# a pre-rename gate is using.
my ( $default_status, $default_output ) = _run_gate($stub_dir);

is( $default_status, 4, 'a default-database run is refused while a pre-rename gate holds the old lock name' );
like(
    $default_output,
    qr/from before the lock was renamed/,
    'the refusal explains that the other run predates the rename, which is why two names are in play'
);
like(
    $default_output,
    qr/pid $$\b/,
    'the refusal names the process it is standing behind'
);

# The complement, and the reason the bridge is scoped rather than global: a run
# with its own database shares nothing with the pre-rename gate and must not be
# blocked by it. Without this, the gate could not run its own suite.
my $private = File::Spec->catdir( tempdir( CLEANUP => 1 ), 'cover_db' );

my ( $private_status, $private_output ) = _run_gate( $stub_dir, '--database', $private );

isnt( $private_status, 4, 'a run with its own database is not refused, because it contends for nothing' );
unlike(
    $private_output,
    qr/refusing to run/,
    'and it is not told about a lock it was never competing for'
);

# Purpose: write an executable stand-in onto the throwaway PATH.
# Input: the path to write, and the script body.
# Output: nothing; dies if the stub cannot be made runnable.
sub _write_stub {
    my ( $path, $body ) = @_;

    open my $handle, '>', $path or die "Unable to write the stub $path: $!";
    print {$handle} $body;
    close $handle or die "Unable to close the stub $path: $!";
    chmod 0755, $path or die "Unable to make the stub $path executable: $!";

    return;
}

# Purpose: run the gate with the stubbed commands ahead of the real ones.
# Input: the stub directory, then the gate's arguments.
# Output: the exit status already shifted, and the combined output.
sub _run_gate {
    my ( $directory, @arguments ) = @_;

    local $ENV{PATH} = $directory . ':' . $ENV{PATH};
    local $ENV{HARNESS_PERL_SWITCHES};
    delete $ENV{HARNESS_PERL_SWITCHES};

    my $command = join ' ', map { quotemeta } ( $^X, $gate, @arguments );
    my $output  = qx{$command 2>&1};

    return ( $? >> 8, defined $output ? $output : '' );
}

__END__

=head1 NAME

150-coverage-gate-lock-rename-bridge.t - prove a gate from before the lock's rename
still excludes one from after it

=head1 PURPOSE

Show that a run on the default database also takes the lock name used before
DD-526's rename, so processes started either side of that change cannot both run
against C<cover_db> - and that a run given its own C<--database> is not dragged
into that exclusion.

=head1 WHY IT EXISTS

A lock is a mutex only while every contender agrees on its name. Renaming one is
therefore never a pure refactor: during the changeover, processes that read the old
name and processes that read the new one are unsynchronised by construction, and
nothing in either of them can tell.

This was observed rather than predicted. After the rename landed, three gates were
running against one C<cover_db> - two guarding C<.coverage-gate.lock> and one
guarding C<.cover_db.lock>. Each deletes the database at startup, so all three were
reporting figures drawn from suites none of them ran alone. That is exactly the
failure the lock was introduced to prevent, reintroduced by the fix to it.

The bridge is deliberately scoped to the default database. A run with its own
database was never in conflict with anything, and making it contend for a single
repository-wide file is the defect that stopped the gate from passing its own suite
- the suite drives the gate, so the gate held the lock and then refused its own
tests.

=head1 WHEN TO USE

Run it whenever the gate's locking changes. It becomes removable once no process
that predates the rename can still be alive, at which point both this file and
C<_hold_legacy_lock> should go together.

=head1 HOW TO USE

    prove -lv t/150-coverage-gate-lock-rename-bridge.t

=head1 WHAT USES IT

The full suite via C<prove -lr t>, the all-metric coverage gate, and the CI workflow
that runs both.

=head1 EXAMPLES

The pre-rename gate is staged by holding the old filename directly, which is all
such a process does that matters here:

    open my $legacy, '+>>', '.coverage-gate.lock';
    flock $legacy, LOCK_EX | LOCK_NB;
    print {$legacy} "$$\n";

    my ( $status, $output ) = _run_gate($stub_dir);          # default database
    is( $status, 4, '...' );

    my ( $private_status ) = _run_gate( $stub_dir, '--database', $own );
    isnt( $private_status, 4, '...' );                        # and this one is free

=cut
