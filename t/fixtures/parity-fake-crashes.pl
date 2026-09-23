#!/usr/bin/env perl

use strict;
use warnings;

my ( $cmd, @rest ) = @ARGV;

if ( $cmd eq 'version' ) {
    print "4.83\n";
    exit 0;
}

if ( $cmd eq '--help' ) {
    print STDERR "simulated crash: cannot load help text\n";
    exit 1;
}

if ( $cmd eq 'jq' ) {
    print "1\n";
    exit 0;
}

print STDERR "unknown command: $cmd\n";
exit 1;

1;

__END__

=pod

=head1 NAME

t/fixtures/parity-fake-crashes.pl - fixture: a fake CLI that crashes on one check with a real stderr message

=head1 PURPOSE

Stands in for the "compiled binary" side of
C<script/pax-functional-parity-check> to prove the harness surfaces a
real crash's stderr and exit code on a FAIL line, rather than only
showing a blank actual value - the exact gap that made a real CI
failure (blank output on two checks) hard to diagnose from the log
alone (DD-1032/DD-1016's git-workflow-gate).

=head1 WHY IT EXISTS

A harness that reports "actual: " (blank) on a genuine process crash
gives the reader no way to tell "the compiled binary printed nothing"
apart from "the compiled binary died before printing anything, and
here is why". This fixture proves the harness now distinguishes them.

=head1 WHEN TO USE

Used only by t/221-pax-functional-parity-harness.t.

=head1 HOW TO USE

    perl t/fixtures/parity-fake-crashes.pl --help

=head1 WHAT USES IT

t/221-pax-functional-parity-harness.t.

=head1 EXAMPLES

Example 1:

    perl t/fixtures/parity-fake-crashes.pl --help

Exits 1 with a real stderr message, prints nothing to stdout.

=cut
