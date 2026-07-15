#!/usr/bin/env perl

use strict;
use warnings;

# The CORE::GLOBAL::rename override must be installed before
# Developer::Dashboard::Collector is compiled so the module's own rename call
# resolves through this intercept. $FAIL_RENAME is a test-controlled switch:
# when it is true the override reports a rename failure, otherwise it delegates
# to the real rename so unrelated renames keep working.
our $FAIL_RENAME;

BEGIN {
    *CORE::GLOBAL::rename = sub {
        return 0 if $FAIL_RENAME;
        return CORE::rename( $_[0], $_[1] );
    };
}

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use Developer::Dashboard::Collector;
use Developer::Dashboard::PathRegistry;

# build_collector()
# Builds a Collector backed by a throwaway home-rooted path registry so the
# atomic write helper can be exercised in isolation.
# Input: none.
# Output: a Developer::Dashboard::Collector object.
sub build_collector {
    my $home  = tempdir( CLEANUP => 1 );
    my $paths = Developer::Dashboard::PathRegistry->new(
        home            => $home,
        workspace_roots => [ File::Spec->catdir( $home, 'workspace' ) ],
    );
    return Developer::Dashboard::Collector->new( paths => $paths );
}

# read_file($file)
# Slurps a file so a written target can be compared against expected contents.
# Input: file path string.
# Output: full file content string.
sub read_file {
    my ($file) = @_;
    open my $fh, '<:raw', $file or die "Unable to read $file: $!";
    local $/;
    return scalar <$fh>;
}

# Finding: _atomic_write_text unlinked the existing target before the rename,
# so a rename that failed destroyed the previous file and broke the atomicity
# the method name promises. The fixed helper must rename over the target in one
# step and leave the previous file untouched when the rename cannot complete.
{
    my $collector = build_collector;

    # A sibling temp directory (outside the registry home) keeps the secure
    # permission hook a no-op so this test isolates the rename behaviour only.
    my $outside = tempdir( CLEANUP => 1 );
    my $target  = File::Spec->catfile( $outside, 'status.json' );
    open my $seed, '>:raw', $target or die "Unable to seed $target: $!";
    print {$seed} 'ORIGINAL' or die "Unable to seed $target: $!";
    close $seed or die "Unable to close $target: $!";

    my $failed;
    {
        local $FAIL_RENAME = 1;
        $failed = !eval {
            $collector->_atomic_write_text( $target, 'REPLACEMENT' );
            1;
        };
    }

    ok( $failed,
        '_atomic_write_text dies when the atomic rename cannot complete' );
    ok( -f $target,
        '_atomic_write_text preserves the existing target after a failed rename (no pre-rename unlink)'
    );
    is( read_file($target), 'ORIGINAL',
        '_atomic_write_text leaves the previous contents intact after a failed rename'
    );

    # Sanity: with rename working, the helper replaces the target atomically.
    my $written = $collector->_atomic_write_text( $target, 'REPLACEMENT' );
    is( $written, $target, '_atomic_write_text returns the written target path' );
    is( read_file($target), 'REPLACEMENT',
        '_atomic_write_text replaces the target contents when the rename succeeds'
    );
}

# Finding: _atomic_write_text ignored close(), so a short or failed flush was
# renamed into place as a truncated file. /dev/full forces the flush to fail on
# close while the small payload stays buffered until then, proving the fixed
# helper surfaces the failure instead of publishing a broken file.
SKIP: {
    skip 'requires a writable /dev/full to force a flush failure', 1
      if !-e '/dev/full' || !-w '/dev/full';

    my $collector = build_collector;
    my $outside   = tempdir( CLEANUP => 1 );
    my $target    = File::Spec->catfile( $outside, 'stdout' );
    my $pending   = "$target.pending";

    skip "unable to symlink /dev/full: $!", 1
      if !symlink( '/dev/full', $pending );

    my $died = !eval {
        $collector->_atomic_write_text( $target, "chunk\n" );
        1;
    };
    ok( $died,
        '_atomic_write_text dies on a failed flush instead of renaming a truncated file into place'
    );

    unlink $pending if -l $pending;
}

done_testing;

__END__

=head1 NAME

54-hunt-collector.t - collector atomic-write durability regression tests

=head1 DESCRIPTION

This test pins down the durability contract of
C<Developer::Dashboard::Collector::_atomic_write_text>: it must publish
collector state only after a fully flushed write, and it must replace the
target through a single rename that never leaves the destination missing.

=for comment FULL-POD-DOC START

=head1 PURPOSE

This test is the executable regression contract for the collector atomic-write
helper. It proves that a failed rename never destroys the previous file and
that a failed flush is raised as an error instead of being renamed into place as
a truncated file, so consumers that read cached collector state always observe a
whole file.

=head1 WHY IT EXISTS

It exists because collector status, output, and log files are written from
background work and read by prompt rendering, the web status strip, and CLI
inspection. A pre-rename unlink or an unchecked close would let those readers
briefly see a missing file or permanently keep a truncated one, and a code-only
review can miss both. Encoding the expectation here keeps the TDD loop, coverage
loop, and release gate concrete.

=head1 WHEN TO USE

Use this file when changing the collector atomic-write helper, its temporary
file handling, or the order in which the pending file is flushed and renamed,
and whenever a focused failure points here.

=head1 HOW TO USE

Run it directly with C<prove -lv t/54-hunt-collector.t> while iterating, then
keep it green under C<prove -lr t> and the coverage runs before release. The
flush-failure assertion uses C</dev/full> and self-skips where that device is
unavailable.

=head1 WHAT USES IT

Developers during TDD, the full C<prove -lr t> suite, the coverage gates, and
the release verification loop all rely on this file to keep collector state
writes durable and atomic.

=head1 EXAMPLES

Example 1:

  prove -lv t/54-hunt-collector.t

Run the focused regression test by itself while changing the behavior it owns.

Example 2:

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lv t/54-hunt-collector.t

Exercise the same focused test while collecting coverage for the collector code
it reaches.

Example 3:

  prove -lr t

Put the focused fix back through the whole repository suite before calling the
work finished.

=for comment FULL-POD-DOC END

=cut
