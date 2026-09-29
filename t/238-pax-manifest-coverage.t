#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Manifest;

my $empty = Developer::Dashboard::Pax::Manifest->new();
my $empty_manifest = $empty->to_hash;
is( $empty_manifest->{schema_version}, 1, 'manifest declares schema version one' );
is( $empty_manifest->{runtime}{perl_family_target}, '5.42.x', 'manifest declares its target Perl family' );
is( $empty_manifest->{runtime}{baseline_match}, JSON::XS::false(), 'missing runtime data does not match the Perl baseline' );
is_deeply( $empty_manifest->{runtime}{config}, {}, 'missing runtime configuration defaults to an empty hash' );
is_deeply( $empty_manifest->{module_graph}{modules}, [], 'missing loaded-module data defaults to an empty list' );
is_deeply( $empty_manifest->{package_state}{packages}, {}, 'missing package-shape data defaults to an empty hash' );
is_deeply( $empty_manifest->{optree_units}{subs}, [], 'missing subroutine optrees default to an empty list' );
is_deeply( $empty_manifest->{method_resolution}, {}, 'missing method-resolution data defaults to an empty hash' );
is_deeply( $empty_manifest->{regex_metadata}, [], 'missing regex data defaults to an empty list' );
is_deeply( $empty_manifest->{compile_phase_events}, [], 'missing compile-phase data defaults to an empty list' );
is( $empty_manifest->{runtime_epochs}{loaded_modules}, 0, 'empty module data produces zero initial loaded-module epochs' );
is_deeply( $empty_manifest->{diagnostics}, [], 'missing diagnostics default to an empty list' );
is( $empty_manifest->{compatibility}{level}, 'D', 'missing capture status is reported as a failed reference capture' );

my $baseline = Developer::Dashboard::Pax::Manifest->new(
    capture => {
        source_entrypoint => 'app.pl',
        status => 'ok',
        mode => 'live',
        runtime => {
            perl_version => '5.42.0',
            config_version => '5.42.0',
            archname => 'x86_64-linux-thread-multi',
            executable => '/usr/bin/perl',
            config => { zeta => 'last', alpha => 'first', optional => undef },
        },
        capture => {
            loaded_files => ['lib/App.pm'],
            package_shapes => { 'App' => { symbol_count => 1 } },
            sub_optrees => [
                { name => 'App::run', pad_layout => ['$self'], closure_descriptor => { file => 'lib/App.pm' } },
                { pad_layout => [] },
            ],
            method_resolution => { 'App::run' => 'App::run' },
            regex_metadata => [{ pattern => 'abc' }],
            compile_phase_events => [{ phase => 'CHECK' }],
        },
        source_features => {},
        diagnostics => [{ level => 'info', message => 'captured' }],
    },
);
my $manifest = $baseline->to_hash;
is( $manifest->{source_entrypoint}, 'app.pl', 'manifest retains source entrypoint' );
is( $manifest->{runtime}{baseline_match}, JSON::XS::true(), '5.42 runtime config matches the baseline' );
is( $manifest->{runtime}{perl_version}, '5.42.0', 'manifest retains runtime Perl version' );
is( $manifest->{runtime}{archname}, 'x86_64-linux-thread-multi', 'manifest retains runtime architecture' );
is( $manifest->{runtime}{executable}, '/usr/bin/perl', 'manifest retains runtime executable' );
is( $manifest->{runtime}{config}{alpha}, 'first', 'manifest retains runtime configuration values' );
is( $manifest->{capture}{status}, 'ok', 'manifest retains capture status' );
is( $manifest->{capture}{mode}, 'live', 'manifest retains capture mode' );
is_deeply( $manifest->{module_graph}{modules}, ['lib/App.pm'], 'manifest retains loaded module paths' );
is_deeply( $manifest->{package_state}{packages}, { App => { symbol_count => 1 } }, 'manifest retains package shapes' );
is_deeply( $manifest->{lexical_pads}{subs}, { 'App::run' => ['$self'] }, 'manifest maps lexical pads for named subroutines' );
is_deeply( $manifest->{closure_descriptors}{subs}, { 'App::run' => { file => 'lib/App.pm' } }, 'manifest maps closure descriptors for named subroutines' );
is_deeply( $manifest->{method_resolution}, { 'App::run' => 'App::run' }, 'manifest retains method resolution data' );
is_deeply( $manifest->{regex_metadata}, [{ pattern => 'abc' }], 'manifest retains regex metadata' );
is_deeply( $manifest->{compile_phase_events}, [{ phase => 'CHECK' }], 'manifest retains compile-phase events' );
is( $manifest->{runtime_epochs}{loaded_modules}, 1, 'manifest counts initially loaded modules' );
is_deeply( $manifest->{diagnostics}, [{ level => 'info', message => 'captured' }], 'manifest retains capture diagnostics' );
is( $manifest->{compatibility}{level}, 'A', 'baseline capture without barriers receives compatibility level A' );

my $dynamic = Developer::Dashboard::Pax::Manifest->new(
    capture => {
        status => 'ok',
        runtime => { config_version => '5.42.12', config => {} },
        capture => {},
        source_features => { tie => 1, local_dynamic => 1 },
    },
)->to_hash;
is( $dynamic->{compatibility}{level}, 'B', 'baseline capture with dynamic barriers receives compatibility level B' );
is( scalar @{ $dynamic->{compatibility}{barriers} }, 2, 'compatibility result retains each active feature barrier' );

my $non_baseline = Developer::Dashboard::Pax::Manifest->new(
    capture => {
        status => 'ok',
        runtime => { config_version => '5.40.1' },
        capture => {},
    },
)->to_hash;
is( $non_baseline->{compatibility}{level}, 'C', 'capturable non-baseline runtime receives compatibility level C' );

my $stamp_a = Developer::Dashboard::Pax::Manifest::_abi_stamp({
    config => { beta => 2, alpha => 1, missing => undef },
    config_version => '5.42.0',
    archname => 'test-arch',
});
my $stamp_b = Developer::Dashboard::Pax::Manifest::_abi_stamp({
    config => { missing => undef, alpha => 1, beta => 2 },
    config_version => '5.42.0',
    archname => 'test-arch',
});
like( $stamp_a, qr/\A[0-9a-f]{64}\z/, 'ABI stamp is a SHA-256 digest' );
is( $stamp_a, $stamp_b, 'ABI stamp is stable regardless of configuration hash insertion order' );
isnt( Developer::Dashboard::Pax::Manifest::_abi_stamp({}), $stamp_a, 'ABI stamp changes when runtime identity is absent' );

is_deeply(
    Developer::Dashboard::Pax::Manifest::_initial_epochs({ capture => { loaded_files => ['A.pm', 'B.pm'] } }),
    {
        package_symbols => 0,
        method_resolution => 0,
        loaded_modules => 2,
        locale_mode => 0,
        unicode_mode => 0,
        regex_assumptions => 0,
        overload_tables => 0,
        eval_created_code => 0,
        interpreter_hooks => 0,
    },
    'initial epoch counters include the loaded-module count and zero all other epochs',
);

done_testing();

__END__

=head1 NAME

t/238-pax-manifest-coverage.t - capture manifest contract coverage

=head1 PURPOSE

Verify the PAX manifest serializer's baseline detection, metadata maps, ABI
stamp, runtime epochs, and compatibility result for missing and populated
capture records.

=head1 WHY IT EXISTS

The manifest is the shared data contract between source capture, compilation,
packaging, and runtime selection. A field can be absent in real capture output,
and configuration hash ordering must not alter the ABI digest. This test
exercises those result paths directly so the serializer contract is observable
without running a complete native build.

=head1 WHEN TO USE

Run when changing C<Developer::Dashboard::Pax::Manifest>, its manifest fields,
baseline detection, ABI identity, or compatibility metadata.

=head1 HOW TO USE

From the repository root, run the test in the development Docker service:

  d2 docker compose --project-name problem20 \
    -f .developer-dashboard/config/docker/d2/compose.yml \
    -f .developer-dashboard/config/docker/d2/development.compose.yml \
    exec -T dev prove -lv t/238-pax-manifest-coverage.t

The test supplies small capture hashes and reads the manifest structure returned
by C<to_hash>; it does not write runtime files or launch a native compiler.

=head1 WHAT USES IT

The PAX compiler and standalone packaging pipeline serialize capture results
through this manifest contract. Focused and full-suite runs protect both direct
field behavior and compatibility integration.

=head1 EXAMPLES

Example 1 - a missing capture remains explicit:

  my $manifest = Developer::Dashboard::Pax::Manifest->new()->to_hash;
  # The baseline is false and compatibility reports reference-capture failure.

Example 2 - a captured baseline gets a deterministic ABI identity:

  my $manifest = Developer::Dashboard::Pax::Manifest->new(capture => $capture)->to_hash;
  # runtime.pax_abi_stamp is a SHA-256 digest of sorted config and runtime identity.

=cut
