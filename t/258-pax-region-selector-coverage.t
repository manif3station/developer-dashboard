#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::RegionSelector;

my $empty = Developer::Dashboard::Pax::RegionSelector->new;
is_deeply( $empty->{manifest}, undef, 'constructor retains an omitted manifest as undefined' );
is_deeply( $empty->select, { selected => [], rejected => [] }, 'missing manifest yields no selected or rejected regions' );

my $manifest = {
    source_entrypoint => '/workspace/app/main.pl',
    runtime => { baseline_match => 1 },
    optree_units => {
        subs => [
            {},
            { name => 'main::BEGIN', closure_descriptor => { file => '/workspace/app/main.pl' } },
            { name => 'main::UNITCHECK', closure_descriptor => { file => '/workspace/app/main.pl' } },
            { name => 'main::CHECK', closure_descriptor => { file => '/workspace/app/main.pl' } },
            { name => 'main::INIT', closure_descriptor => { file => '/workspace/app/main.pl' } },
            { name => 'main::_private', closure_descriptor => { file => '/workspace/app/main.pl' }, available => 1 },
            { name => 'main::encode_json', closure_descriptor => { file => '/workspace/app/main.pl' }, available => 1 },
            { name => 'main::decode_json', closure_descriptor => { file => '/workspace/app/main.pl' }, available => 1 },
            { name => 'main::svref_2object', closure_descriptor => { file => '/workspace/app/main.pl' }, available => 1 },
            { name => 'main::unavailable', closure_descriptor => { file => '/workspace/app/main.pl' }, reason => 'optree was not captured' },
            { name => 'main::unknown-unavailable', closure_descriptor => { file => '/workspace/app/main.pl' } },
            { name => 'Developer::Dashboard::Pax::Fixture::worker', closure_descriptor => { file => '-' }, available => 1, optree_ops => ['enter_region'] },
            { name => 'Developer::Dashboard::Pax::Fixture::start::BEGIN', closure_descriptor => { file => '-' }, available => 1 },
            { name => 'Other::External::native', closure_descriptor => { file => '/usr/share/perl5/External.pm' }, native_shape => { kind => 'i64_binary_leaf' }, available => 1 },
            { name => 'App::from_entrypoint', closure_descriptor => { file => '/workspace/app/main.pl' }, available => 1 },
            { name => 'App::from_relative', closure_descriptor => { file => 'lib/App/Local.pm' }, available => 1 },
            { name => 'App::no_file', available => 1 },
            { name => 'App::dash_file', closure_descriptor => { file => '-' }, available => 1 },
            { name => 'App::wrong_extension', closure_descriptor => { file => '/workspace/app/data.txt' }, available => 1 },
            { name => 'App::other_absolute', closure_descriptor => { file => '/opt/vendor/App.pm' }, available => 1 },
            { name => 'App::system_usr', closure_descriptor => { file => '/usr/lib/perl5/Other.pm' }, available => 1 },
            { name => 'App::system_root', closure_descriptor => { file => '/System/Library/Other.pm' }, available => 1 },
            { name => 'App::system_windows', closure_descriptor => { file => 'C:/Strawberry/perl/site/lib/Other.pm' }, available => 1 },
        ],
    },
};
my $selected = Developer::Dashboard::Pax::RegionSelector->new(manifest => $manifest)->select;
is_deeply(
    [ map { $_->{name} } @{ $selected->{selected} } ],
    [
        'Developer::Dashboard::Pax::Fixture::worker',
        'Developer::Dashboard::Pax::Fixture::start::BEGIN',
        'Other::External::native',
        'App::from_entrypoint',
        'App::from_relative',
    ],
    'selector accepts application, fixture, native-shaped, entrypoint, and relative-file regions only',
);
is_deeply(
    [ map { $_->{id} } @{ $selected->{selected} } ],
    [qw(region-0001 region-0002 region-0003 region-0004 region-0005)],
    'selected region IDs are sequential and ignore rejected entries',
);
is( $selected->{selected}[0]{kind}, 'candidate_leaf_function', 'ordinary application subroutine is a leaf candidate' );
is( $selected->{selected}[1]{kind}, 'compile_phase_hook', 'fixture compile-phase subroutine is classified as a hook' );
is( $selected->{selected}[1]{support_level}, 'guarded', 'baseline-matched region uses guarded support' );
is( $selected->{selected}[1]{reason}, 'compile_phase_hook can enter HIR with runtime guards', 'support reason includes classified kind' );
is_deeply( $selected->{selected}[0]{source}{optree_ops}, ['enter_region'], 'selected region preserves its optree operation list' );
is_deeply( $selected->{selected}[2]{required_epochs}, [qw(package_symbols method_resolution loaded_modules)], 'selected regions carry required runtime epochs' );
is( $selected->{selected}[4]{source}{entrypoint}, '/workspace/app/main.pl', 'selected source metadata retains entrypoint' );
is( $selected->{selected}[4]{lowering_status}, 'ready', 'guarded support remains ready for later lowering' );

is_deeply(
    [ map { [ $_->{name}, $_->{code}, $_->{detail} ] } @{ $selected->{rejected} } ],
    [
        [ 'main::unavailable', 'optree_unavailable', 'optree was not captured' ],
        [ 'main::unknown-unavailable', 'optree_unavailable', '' ],
    ],
    'application subs with unavailable optrees are explicitly rejected with details',
);

my $mismatched = Developer::Dashboard::Pax::RegionSelector->new(
    manifest => {
        source_entrypoint => '/workspace/other/main.pl',
        runtime => { baseline_match => 0 },
        optree_units => { subs => [
            { name => 'App::baseline_mismatch', closure_descriptor => { file => '/workspace/app/main.pl' }, available => 1 },
            { name => 'main::baseline_mismatch', closure_descriptor => { file => '/workspace/app/main.pl' }, available => 1 },
        ] },
    },
)->select;
is( scalar @{ $mismatched->{selected} }, 1, 'mismatched runtime still allows ordinary main namespace code' );
is( $mismatched->{selected}[0]{support_level}, 'guarded', 'baseline mismatch remains guarded rather than rejected' );
is( $mismatched->{selected}[0]{reason}, 'runtime baseline mismatch requires guarded portable native packaging', 'baseline mismatch explains its extra guard requirement' );

my $without_entrypoint = Developer::Dashboard::Pax::RegionSelector->new(
    manifest => {
        optree_units => { subs => [
            { name => 'App::unowned_absolute', closure_descriptor => { file => '/workspace/unrelated/App.pm' }, available => 1 },
        ] },
    },
)->select;
is_deeply( $without_entrypoint, { selected => [], rejected => [] }, 'absolute application-looking paths without an entrypoint are not claimed' );

done_testing();

__END__

=head1 NAME

t/258-pax-region-selector-coverage.t - tests application-region selection

=head1 PURPOSE

Exercises the region selector's acceptance and rejection rules, compile-phase
classification, native-shape exception, runtime-baseline support reasons,
sequential ids, and optree-unavailable diagnostics.

=head1 WHY IT EXISTS

Only application-owned closures should proceed to HIR, while generated helper
subs and external library code must be excluded unless the captured record
explicitly carries a supported native shape. This test pins those boundaries.

=head1 WHEN TO USE

Run when changing closure ownership checks, excluded symbols or paths,
compile-phase classification, or selected/rejected region metadata.

=head1 HOW TO USE

Run inside the development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/258-pax-region-selector-coverage.t

=head1 WHAT USES IT

C<PAX::CLI>, standalone analysis, and C<RuntimeDispatcher> select captured
regions through this module before lowering or execution planning.

=head1 EXAMPLES

Example 1: pass an application entrypoint and verify its own closures are
selected while system-library closures are rejected.

Example 2: pass an unavailable optree record and inspect its rejection code and
captured diagnostic detail.

=cut
