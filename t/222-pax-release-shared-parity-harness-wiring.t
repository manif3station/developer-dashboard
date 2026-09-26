#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use YAML::XS qw(LoadFile);

plan skip_all => 'checkout-only workflow validation; release tarballs exclude .github'
    if !-f '.github/workflows/pax-release.yml';

# DD-1016 (child of DDE-006): every platform's smoke-verify step must call
# the SHARED script/pax-functional-parity-check harness instead of each
# duplicating its own ad hoc single-command (version-only) comparison.

my $path = '.github/workflows/pax-release.yml';
my $workflow = LoadFile($path);

my $job = ( values %{ $workflow->{jobs} } )[0];
my @steps = @{ $job->{steps} };
my %step_by_name = map { $_->{name} => $_ } @steps;

for my $case (
    [ 'Smoke-verify the compiled dashboard binary (Linux only)', 'pax-output/d2' ],
    [ 'Smoke-verify the compiled dashboard binary (macOS only)', 'pax-output/d2' ],
) {
    my ( $step_name, $binary ) = @$case;
    my $step = $step_by_name{$step_name};
    ok( $step, "'$step_name' step exists" );
    like( $step->{run}, qr/\bscript\/pax-functional-parity-check\b/, "'$step_name' calls the shared harness" )
        or diag("$step_name run block was:\n$step->{run}");
    like( $step->{run}, qr/--compiled\s+\Q$binary\E/, "'$step_name' points --compiled at the real build output" );
    like( $step->{run}, qr/--source-script\s+bin\/dashboard/, "'$step_name' points --source-script at bin/dashboard" );
}

# Windows amd64 uses pwsh syntax, so its invocation differs syntactically
# but must still call the same shared harness.
{
    my $step = $step_by_name{'Smoke-verify the compiled dashboard binary (Windows amd64 only)'};
    ok( $step, "'Smoke-verify the compiled dashboard binary (Windows amd64 only)' step exists" );
    like( $step->{run}, qr/\bscript\/pax-functional-parity-check\b/, 'the Windows amd64 smoke-verify step calls the shared harness' )
        or diag("run block was:\n$step->{run}");
    like( $step->{run}, qr/--compiled\s+pax-output\/d2\.exe/, 'the Windows step points --compiled at d2.exe' );
    like( $step->{run}, qr/--source-script\s+bin\/dashboard/, 'the Windows step points --source-script at bin/dashboard' );
}

# The old, per-platform-duplicated single-command comparisons must be
# gone now that the shared harness replaces them - not left dangling
# alongside the new call.
for my $step_name (
    'Smoke-verify the compiled dashboard binary (Linux only)',
    'Smoke-verify the compiled dashboard binary (macOS only)',
    'Smoke-verify the compiled dashboard binary (Windows amd64 only)',
) {
    my $step = $step_by_name{$step_name};
    unlike( $step->{run}, qr/compiled_version/, "'$step_name' no longer duplicates its own version-only comparison" );
}

done_testing();

__END__

=pod

=head1 NAME

222-pax-release-shared-parity-harness-wiring.t - proves DD-1016 wired the shared harness into pax-release.yml

=head1 PURPOSE

Guards that C<.github/workflows/pax-release.yml>'s three platform
smoke-verify steps (Linux, macOS, Windows amd64) each call the shared
C<script/pax-functional-parity-check> harness (DD-1016), rather than
each duplicating its own ad hoc single-command comparison as they did
before this ticket.

=head1 WHY IT EXISTS

Three independent, hand-duplicated version-only comparisons could never
catch a real functional divergence in anything other than the version
string, and any fix to the comparison logic would have to be applied in
three places at once (and likely drift). This test proves all three
platforms now delegate to one shared, more thorough harness instead.

=head1 WHEN TO USE

Run this file whenever C<.github/workflows/pax-release.yml>'s
smoke-verify steps change, or whenever a new platform target's build step
is added and needs the same shared-harness wiring.

=head1 HOW TO USE

    prove -lv t/222-pax-release-shared-parity-harness-wiring.t

=head1 WHAT USES IT

Only this test parses C<.github/workflows/pax-release.yml>'s
smoke-verify steps for this specific wiring; t/211/t/213/t/218 guard
other parts of the same workflow file.

=head1 EXAMPLES

Example 1:

    prove -lv t/222-pax-release-shared-parity-harness-wiring.t

Confirm all three platform smoke-verify steps call the shared harness.

=cut
