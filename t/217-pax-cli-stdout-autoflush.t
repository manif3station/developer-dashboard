#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;

my $path = 'share/private-cli/pax';
my $body = do { local $/; open my $fh, '<', $path or die "cannot read $path: $!"; <$fh> };

# AC-1: STDOUT must be set to autoflush (unbuffered) mode, and this must
# happen BEFORE any real work starts (right after the binmode calls).
like(
    $body,
    qr/binmode STDOUT.*?binmode STDERR.*?\$\|\s*=\s*1/s,
    'pax sets $| = 1 (STDOUT autoflush) immediately after the binmode calls, before any real work'
);

done_testing();

__END__

=pod

=head1 NAME

217-pax-cli-stdout-autoflush.t - proves DD-1015's STDOUT-autoflush fix for the pax CLI

=head1 PURPOSE

Guards that C<share/private-cli/pax> sets C<$| = 1> (STDOUT autoflush)
immediately, so its build-progress output is written as it happens
rather than sitting in Perl's block-buffer until the process exits or
the buffer fills.

=head1 WHY IT EXISTS

A real GitHub Actions windows-amd64 run of C<PAX Release> made zero
visible progress for over 40 minutes (frozen at "Compile application
units (4/117: ...)") before hitting its 45-minute job timeout and being
cancelled. Local reproduction of the same file with
C<Developer::Dashboard::Pax::CodeUnitCompiler> directly showed it takes
only ~3 seconds, and a batch of all 117 files in one warm interpreter
took only 59 seconds total - nowhere near 40 minutes. STDOUT is fully
block-buffered (not line-buffered) when a Perl process's stdout is not
attached to a TTY, which is exactly GitHub Actions' case running under
pwsh on Windows - so the actual build could have been proceeding the
whole time with its progress output silently queued, making a genuinely
slow (but eventually completing) Windows run indistinguishable in the
log from a true hang. Without this fix, nobody watching a real CI run
can tell "still working, just slow" from "stuck" until the timeout
fires either way.

=head1 WHEN TO USE

Run this file whenever C<share/private-cli/pax>'s startup sequence
changes.

=head1 HOW TO USE

    prove -lv t/217-pax-cli-stdout-autoflush.t

=head1 WHAT USES IT

C<share/private-cli/pax> is not exercised for its stdout-buffering
behavior by any other test file in this suite.

=head1 EXAMPLES

Example 1:

    prove -lv t/217-pax-cli-stdout-autoflush.t

Confirm the fix is present.

=cut
