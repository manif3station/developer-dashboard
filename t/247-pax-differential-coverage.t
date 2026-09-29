#!/usr/bin/env perl

use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Spec;
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Differential;

my $root = tempdir( CLEANUP => 1 );
my $successful_entrypoint = File::Spec->catfile( $root, 'success.pl' );
_write( $successful_entrypoint, <<'PERL' );
print "stock-output\n";
warn "stock-warning\n";
1;
PERL

my $runner = Developer::Dashboard::Pax::Differential->new( pax_bin => '/unused/compatibility-argument' );
is( $runner->{pax_bin}, '/unused/compatibility-argument', 'new preserves the historical pax_bin argument for compatibility' );

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    my $comparison = $runner->compare_capture($successful_entrypoint);
    ok( $comparison->{pass}, 'compare_capture passes when stock Perl exits successfully and capture status is ok' );
    is( $comparison->{stock}{stdout}, "stock-output\n", 'stock execution returns stdout independently' );
    is( $comparison->{stock}{stderr}, "stock-warning\n", 'stock execution returns stderr independently' );
    is( $comparison->{pax}{exit}, 0, 'successful capture status maps to a zero PAX result' );
    is( $comparison->{comparison}{stock_stderr_present}, 1, 'comparison marks stock stderr as present' );
    is( $comparison->{comparison}{pax_stderr_present}, 0, 'comparison marks empty capture stderr as absent' );
    is( $comparison->{entrypoint}, $successful_entrypoint, 'comparison identifies the source entrypoint' );
}

my $failing_entrypoint = File::Spec->catfile( $root, 'failure.pl' );
_write( $failing_entrypoint, <<'PERL' );
print "before-failure\n";
exit 7;
PERL
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    my $comparison = Developer::Dashboard::Pax::Differential->new->compare_capture($failing_entrypoint);
    ok( !$comparison->{pass}, 'compare_capture fails when stock Perl exits nonzero even if capture reports ok' );
    is( $comparison->{stock}{exit}, 7, 'stock nonzero exit status is retained' );
    is( $comparison->{pax}{exit}, 0, 'the successful capture status remains distinct from the stock exit' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'failed' }; };
    my $comparison = Developer::Dashboard::Pax::Differential->new->compare_capture($successful_entrypoint);
    ok( !$comparison->{pass}, 'compare_capture fails closed for a non-ok capture status' );
    is( $comparison->{pax}{exit}, 1, 'a non-ok capture status maps to a nonzero PAX result' );
    is( $comparison->{pax}{stderr}, '', 'a status-only capture failure has empty stderr' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { die "fixture capture failure\n"; };
    my $comparison = Developer::Dashboard::Pax::Differential->new->compare_capture($successful_entrypoint);
    ok( !$comparison->{pass}, 'compare_capture reports a thrown capture exception as a failed comparison' );
    is( $comparison->{pax}{exit}, 1, 'a capture exception maps to a nonzero PAX result' );
    like( $comparison->{pax}{stderr}, qr/fixture capture failure/, 'capture exception text is retained in PAX stderr' );
    is( $comparison->{comparison}{pax_stderr_present}, 1, 'comparison marks capture exception stderr as present' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return; };
    my $comparison = Developer::Dashboard::Pax::Differential->new->compare_capture($successful_entrypoint);
    ok( !$comparison->{pass}, 'compare_capture rejects a missing capture result' );
    is( $comparison->{pax}{exit}, 1, 'a missing capture result maps to nonzero status' );
}

my $silent_entrypoint = File::Spec->catfile( $root, 'silent.pl' );
_write( $silent_entrypoint, "1;\n" );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    my $comparison = Developer::Dashboard::Pax::Differential->new->compare_capture($silent_entrypoint);
    is( $comparison->{stock}{stdout}, '', 'stock execution maps EOF on empty stdout to an empty string' );
    is( $comparison->{stock}{stderr}, '', 'stock execution maps EOF on empty stderr to an empty string' );
    ok( $comparison->{pass}, 'empty but successful stock output still passes against a successful capture' );
}

done_testing();

sub _write {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    return;
}

__END__

=head1 NAME

t/247-pax-differential-coverage.t - tests stock-Perl and capture comparison outcomes

=head1 PURPOSE

This test exercises the differential comparison's success, nonzero stock exit,
capture-status rejection, capture exception, and absent-result behavior. Its tiny
temporary Perl programs keep stock execution real while capture outcomes are
controlled at the Capture API boundary.

=head1 WHY IT EXISTS

PAX must report stock execution and capture outcomes separately so a mismatch is
diagnosable. These cases verify exit codes, stdout/stderr separation, and the
pass decision without requiring a built PAX binary or depending on a host tool.

=head1 WHEN TO USE

Run this test when changing C<Developer::Dashboard::Pax::Differential> or the
capture result contract it consumes.

=head1 HOW TO USE

Run inside the repository's Docker development service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/247-pax-differential-coverage.t

=head1 WHAT USES IT

PAX validation uses C<compare_capture> to compare stock Perl execution with
capture status. This test calls that same public method and separately validates
the compatibility constructor argument.

=head1 EXAMPLES

Example 1: run the file alone in Docker to verify the differential result fields.

Example 2: include it in C<script/coverage-gate> to measure its contribution to
statement, branch, condition, and subroutine coverage.

=cut
