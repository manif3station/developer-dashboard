#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Backend::Tier1CraneliftEquivalent;

my $default = Developer::Dashboard::Pax::Backend::Tier1CraneliftEquivalent->new;
my $default_metadata = $default->metadata;
is( $default_metadata->{tier}, 1, 'tier-one backend declares its tier' );
is( $default_metadata->{name}, 'cranelift-equivalent-low-latency-backend', 'backend defaults to its descriptive name' );
is( $default_metadata->{role}, 'quick_native_backend', 'backend reports its quick-native role' );
is( $default_metadata->{contract}, 'low_latency_guarded_ssa_native_emission', 'backend reports its guarded-SSA contract' );

my $named = Developer::Dashboard::Pax::Backend::Tier1CraneliftEquivalent->new(name => 'fixture-tier-one');
is( $named->metadata->{name}, 'fixture-tier-one', 'backend metadata retains a caller-provided name' );

done_testing();

__END__

=head1 NAME

t/259-pax-tier1-backend-contract.t - tests tier-one backend metadata

=head1 PURPOSE

Verifies the constructor default and explicit backend name, and the complete
metadata contract returned by
C<Developer::Dashboard::Pax::Backend::Tier1CraneliftEquivalent>.

=head1 WHY IT EXISTS

PAX describes backend capability through metadata that its gatekeeper and
dispatch planners inspect. The module is intentionally small, so direct tests
keep both its default and supplied-name paths explicit.

=head1 WHEN TO USE

Run when changing the tier-one backend's metadata or constructor inputs.

=head1 HOW TO USE

Run inside the development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/259-pax-tier1-backend-contract.t

=head1 WHAT USES IT

C<PAX::Gatekeeper> and backend planning stages read this contract to report
which tier-one implementation is available.

=head1 EXAMPLES

Example 1: construct the backend without arguments and inspect the default
contract metadata.

Example 2: supply an explicit name and verify that the metadata exposes it
without changing the tier or role.

=cut
