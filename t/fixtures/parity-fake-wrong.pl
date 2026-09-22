#!/usr/bin/env perl

use strict;
use warnings;

my ( $cmd, @rest ) = @ARGV;

if ( $cmd eq 'version' ) {
    print "4.83\n";
    exit 0;
}

if ( $cmd eq '--help' ) {
    print "Name:\n    dashboard - thin command switchboard for Developer Dashboard\n";
    exit 0;
}

if ( $cmd eq 'jq' ) {
    my ( $query, $file ) = @rest;
    print "999\n";
    exit 0;
}

print STDERR "unknown command: $cmd\n";
exit 1;

1;

__END__

=pod

=head1 NAME

t/fixtures/parity-fake-wrong.pl - fixture: a fake CLI that deliberately answers one check wrong

=head1 PURPOSE

Stands in for the "compiled binary" side of
C<script/pax-functional-parity-check> in the AC-2 (mismatch-detected)
case: matches C<version> and C<--help> exactly like
C<parity-fake-correct.pl>, but returns a deliberately wrong C<jq> answer
(C<999> instead of C<1>) so the test can assert the harness genuinely
catches a real functional-parity mismatch rather than passing everything
unconditionally.

=head1 WHY IT EXISTS

A harness that always reports PASS is worse than no harness - this
fixture proves C<script/pax-functional-parity-check> can fail, and fail
on the SPECIFIC check that diverges, not just fail generically.

=head1 WHEN TO USE

Used only by t/221-pax-functional-parity-harness.t.

=head1 HOW TO USE

    perl t/fixtures/parity-fake-wrong.pl jq .a somefile.json

=head1 WHAT USES IT

t/221-pax-functional-parity-harness.t.

=head1 EXAMPLES

Example 1:

    perl t/fixtures/parity-fake-wrong.pl jq .a somefile.json

Prints C<999> (deliberately wrong).

=cut
