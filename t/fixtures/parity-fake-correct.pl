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
    print "1\n";
    exit 0;
}

print STDERR "unknown command: $cmd\n";
exit 1;

1;

__END__

=pod

=head1 NAME

t/fixtures/parity-fake-correct.pl - fixture: a fake CLI that answers t/221's harness checks correctly

=head1 PURPOSE

Stands in for both the "source Perl" and "compiled binary" sides of
C<script/pax-functional-parity-check> in the AC-1 (all-match) case,
without paying the cost of a real C<pax build> in the test.

=head1 WHY IT EXISTS

t/183/t/184 and friends already prove real PAX builds work; this test
only needs to prove the HARNESS's own comparison logic is correct, so a
fast, hermetic stand-in is the right tool rather than re-verifying PAX
itself.

=head1 WHEN TO USE

Used only by t/221-pax-functional-parity-harness.t.

=head1 HOW TO USE

    perl t/fixtures/parity-fake-correct.pl version
    perl t/fixtures/parity-fake-correct.pl jq .a somefile.json
    perl t/fixtures/parity-fake-correct.pl --help

=head1 WHAT USES IT

t/221-pax-functional-parity-harness.t.

=head1 EXAMPLES

Example 1:

    perl t/fixtures/parity-fake-correct.pl version

Prints C<4.83>.

=cut
