#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::RuntimeDispatcher;

{
    package Local::PaxRuntimeDispatchFixture;
    our $MANIFEST = { runtime => { baseline_match => 'fixture-baseline' }, runtime_epochs => {} };
    our $SSA = [];
    our $GUARD_STATUS = 'native_allowed';
    our $ARTIFACT = { entry_kind => 'native_i64_leaf', executable_path => '/fake/native', reason => 'compiled fixture' };
    our $NATIVE_RESULT = { status => 'ok', value => 5 };
    our $PROFILE_REPORT = { regions => [] };
    our @PROFILE_EVENTS;

    package Local::PaxDispatchCapture;
    sub capture { return {} }
    package Local::PaxDispatchManifest;
    sub to_hash { return $Local::PaxRuntimeDispatchFixture::MANIFEST }
    package Local::PaxDispatchSelector;
    sub select { return { selected => [] } }
    package Local::PaxDispatchHIR;
    sub lower_all { return [] }
    package Local::PaxDispatchSSA;
    sub build_all { return $Local::PaxRuntimeDispatchFixture::SSA }
    package Local::PaxDispatchGuard;
    sub validate_or_deopt {
        return { status => $Local::PaxRuntimeDispatchFixture::GUARD_STATUS,
                 fallback => { reason => 'missing_epoch' } };
    }
    package Local::PaxDispatchProfileStore;
    sub report { return $Local::PaxRuntimeDispatchFixture::PROFILE_REPORT }
    sub record_dispatch { push @Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS, $_[1]; return }
    package Local::PaxDispatchInlineCache;
    sub lookup { return { status => 'miss' } }
    sub update { my %args = @_[ 1 .. $#_ ]; return { status => 'updated', method => $args{method} } }
    sub report { return { max_polymorphic => 4 } }
    package Local::PaxDispatchJIT;
    sub decision { return { status => 'observe' } }
    package Local::PaxDispatchOSR;
    sub evaluate { return { status => 'observe', osr_event => 'observe' } }
    sub retirement { my %args = @_[ 1 .. $#_ ]; return { status => 'retired', osr_event => 'retire', reason => $args{reason}, safepoint => $args{safepoint} } }
    package Local::PaxDispatchAOT;
    sub plan { return { status => 'planned' } }
    package Local::PaxDispatchTier1;
    sub compile { return $Local::PaxRuntimeDispatchFixture::ARTIFACT }
    package Local::PaxDispatchNativeRunner;
    sub run_i64_binary { return $Local::PaxRuntimeDispatchFixture::NATIVE_RESULT }
}

my $defaults = Developer::Dashboard::Pax::RuntimeDispatcher->new;
is( $defaults->{mode}, 'live', 'constructor defaults to live mode' );
isa_ok( $defaults->{profile_store}, 'Developer::Dashboard::Pax::ProfileStore', 'constructor creates a profile store' );
isa_ok( $defaults->{inline_cache}, 'Developer::Dashboard::Pax::InlineCache', 'constructor creates an inline cache' );
isa_ok( $defaults->{hot_region_jit}, 'Developer::Dashboard::Pax::HotRegionJIT', 'constructor creates hot-region policy' );
isa_ok( $defaults->{osr}, 'Developer::Dashboard::Pax::OSR', 'constructor creates an OSR policy' );
isa_ok( $defaults->{aot}, 'Developer::Dashboard::Pax::ProfileGuidedAOT', 'constructor creates an AOT policy' );

my $custom = Developer::Dashboard::Pax::RuntimeDispatcher->new(
    mode => 'hermetic',
    threshold => 7,
    profile_store => bless({}, 'Local::PaxDispatchProfileStore'),
    inline_cache => bless({}, 'Local::PaxDispatchInlineCache'),
    hot_region_jit => bless({}, 'Local::PaxDispatchJIT'),
    osr => bless({}, 'Local::PaxDispatchOSR'),
    aot => bless({}, 'Local::PaxDispatchAOT'),
);
is( $custom->{mode}, 'hermetic', 'constructor preserves an explicit mode' );
isa_ok( $custom->{aot}, 'Local::PaxDispatchAOT', 'constructor retains caller-provided collaborators' );

my $threshold_defaults = Developer::Dashboard::Pax::RuntimeDispatcher->new(threshold => 9);
isa_ok( $threshold_defaults->{profile_store}, 'Developer::Dashboard::Pax::ProfileStore', 'threshold option still builds the default profile store' );

my $falsey_collaborators = Developer::Dashboard::Pax::RuntimeDispatcher->new(
    profile_store => 0,
    inline_cache => 0,
    hot_region_jit => 0,
    osr => 0,
    aot => 0,
);
is_deeply(
    [ @{$falsey_collaborators}{qw(profile_store inline_cache hot_region_jit osr aot)} ],
    [ (0) x 5 ],
    'defined falsey collaborators are retained rather than replaced by defaults',
);

my $missing_region = _dispatch(
    region_name => 'absent',
    ssa => [{ region_name => 'add', region_id => 'r1' }],
);
is( $missing_region->{status}, 'fallback', 'requested region without a candidate returns fallback' );
like( $missing_region->{reason}, qr/requested region not found: absent/, 'missing-candidate fallback reports requested region' );
is( $missing_region->{baseline_match}, 'fixture-baseline', 'missing-candidate response includes baseline result' );
is( scalar @Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS, 1, 'missing candidate is recorded in profile history' );
is( $Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS[0]{status}, 'fallback', 'missing candidate profile event is marked fallback' );

@Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS = ();
my $empty = _dispatch(ssa => []);
is( $empty->{status}, 'fallback', 'empty SSA candidate set returns a fallback event' );
is( $empty->{reason}, 'no native i64 dispatch candidate succeeded', 'empty candidate event explains the fallback' );
is_deeply( $empty->{attempts}, [], 'empty candidate event has no attempts' );
is( scalar @Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS, 0, 'empty candidate set does not record a region dispatch' );

@Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS = ();
my $deopt = _dispatch(
    region_name => 'add',
    ssa => [{ region_id => 'r-deopt', region_name => 'main::add', deopt => { safepoint => 'sp-deopt' } }],
    guard_status => 'deopt',
);
is( $deopt->{status}, 'fallback', 'failed guard eventually returns fallback when no candidate succeeds' );
is( $deopt->{attempts}[0]{status}, 'deopt', 'failed guard records a deoptimization attempt' );
is( $deopt->{attempts}[0]{osr}{status}, 'retired', 'failed guard retires its promoted OSR state' );
is( $deopt->{attempts}[0]{osr}{safepoint}, 'sp-deopt', 'guard retirement retains the SSA safepoint' );
is( $Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS[0]{status}, 'deopt', 'guard failure records a deopt profile event' );

@Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS = ();
my $artifact_fallback = _dispatch(
    region_name => 'add',
    ssa => [{ region_id => 'r-fallback', region_name => 'add' }],
    artifact => { entry_kind => 'native_probe_trampoline', executable_path => undef, reason => 'no matching native shape' },
);
is( $artifact_fallback->{status}, 'fallback', 'non-native artifact falls back to interpreter execution' );
is( $artifact_fallback->{attempts}[0]{status}, 'fallback', 'artifact failure is captured in attempts' );
is( $artifact_fallback->{attempts}[0]{reason}, 'no matching native shape', 'artifact fallback explains why native execution was skipped' );
is( $artifact_fallback->{attempts}[0]{inline_cache}{update}{status}, 'updated', 'artifact fallback updates the inline cache' );
is( $Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS[0]{status}, 'fallback', 'artifact fallback is recorded in profile history' );

my $invalid_kind = _dispatch(
    region_name => 'add',
    ssa => [{ region_id => 'r-invalid-kind', region_name => 'add' }],
    artifact => { entry_kind => 'native_other', executable_path => '/fake/native', reason => 'unexpected kind' },
);
is( $invalid_kind->{attempts}[0]{status}, 'fallback', 'unexpected native entry kind skips native execution' );

my $missing_executable = _dispatch(
    region_name => 'add',
    ssa => [{ region_id => 'r-missing-executable', region_name => 'add' }],
    artifact => { entry_kind => 'native_i64_leaf', executable_path => undef, reason => 'missing executable' },
);
is( $missing_executable->{attempts}[0]{status}, 'fallback', 'recognized native artifact without an executable falls back' );
is( $missing_executable->{attempts}[0]{reason}, 'missing executable', 'missing executable fallback preserves its reason' );

my $missing_entry_kind = _dispatch(
    region_name => 'add',
    ssa => [{ region_id => 'r-missing-kind', region_name => 'add' }],
    artifact => { executable_path => undef, reason => 'artifact kind absent' },
);
is( $missing_entry_kind->{attempts}[0]{status}, 'fallback', 'artifact without an entry kind falls back safely' );
is( $missing_entry_kind->{attempts}[0]{reason}, 'artifact kind absent', 'missing-kind fallback retains artifact context' );

my $filtered_candidates = _dispatch(
    region_name => 'add',
    ssa => [
        { region_id => 'r-unnamed' },
        { region_id => 'r-other', region_name => 'subtract' },
        { region_id => 'r-add', region_name => 'add' },
    ],
    cache_site => 'explicit-cache-site',
);
is( $filtered_candidates->{status}, 'native', 'a nonmatching named candidate is skipped before the matching candidate' );
is( $filtered_candidates->{region_id}, 'r-add', 'filtered dispatch returns the matching region' );

my $profiled_region = _dispatch(
    ssa => [{ region_id => 'r-profiled', region_name => 'add' }],
    profile => { regions => [{ region => 'add', dispatches => 12 }] },
);
is( $profiled_region->{status}, 'native', 'named region with profile data dispatches natively' );
is( $profiled_region->{region_id}, 'r-profiled', 'profile lookup does not alter selected region identity' );

@Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS = ();
my $success = _dispatch(
    region_name => 'add',
    ssa => [{ region_id => 'r-native', region_name => 'add' }],
    native_result => { status => 'ok', value => 5 },
    left => 2,
    right => 3,
);
is( $success->{status}, 'native', 'successful native runner returns native dispatch' );
is( $success->{result}{value}, 5, 'native result is retained in the event' );
is_deeply( $success->{args}, [ 2, 3 ], 'native event records numeric arguments' );
is( $success->{aot_plan}{status}, 'planned', 'native event includes the updated AOT plan' );
is( $Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS[0]{status}, 'native', 'native execution is recorded in profile history' );

my $failed_native = _dispatch(
    ssa => [{ region_id => 'r-failed-native' }],
    native_result => { status => 'error', stderr => 'fixture native failure' },
);
is( $failed_native->{status}, 'fallback', 'failed native execution returns fallback status' );
is( $failed_native->{requested_region}, undef, 'unfiltered dispatch leaves requested region undefined' );
is( $failed_native->{inline_cache}{lookup}{status}, 'miss', 'native result event includes the cache lookup' );
is( $failed_native->{inline_cache}{update}{status}, 'updated', 'native result event includes the cache update' );

is_deeply( Developer::Dashboard::Pax::RuntimeDispatcher::_profile_by_region({}), {}, 'profile mapping defaults to an empty region list' );
is_deeply(
    Developer::Dashboard::Pax::RuntimeDispatcher::_profile_by_region({ regions => [{ region => 'add', dispatches => 3 }] }),
    { add => { region => 'add', dispatches => 3 } },
    'profile mapping indexes all reported regions by name',
);
is_deeply( $custom->profile_report->{regions}, [], 'profile report delegates to its configured store' );
is( $custom->inline_cache_report->{max_polymorphic}, 4, 'inline-cache report delegates to its configured cache' );

done_testing();

sub _dispatch {
    my (%args) = @_;
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::new = sub { return bless {}, 'Local::PaxDispatchCapture' };
    local *Developer::Dashboard::Pax::Manifest::new = sub { return bless {}, 'Local::PaxDispatchManifest' };
    local *Developer::Dashboard::Pax::RegionSelector::new = sub { return bless {}, 'Local::PaxDispatchSelector' };
    local *Developer::Dashboard::Pax::HIR::new = sub { return bless {}, 'Local::PaxDispatchHIR' };
    local *Developer::Dashboard::Pax::GuardedSSA::new = sub { return bless {}, 'Local::PaxDispatchSSA' };
    local *Developer::Dashboard::Pax::GuardManager::new = sub { return bless {}, 'Local::PaxDispatchGuard' };
    local *Developer::Dashboard::Pax::ProfileStore::new = sub { return bless {}, 'Local::PaxDispatchProfileStore' };
    local *Developer::Dashboard::Pax::InlineCache::new = sub { return bless {}, 'Local::PaxDispatchInlineCache' };
    local *Developer::Dashboard::Pax::HotRegionJIT::new = sub { return bless {}, 'Local::PaxDispatchJIT' };
    local *Developer::Dashboard::Pax::OSR::new = sub { return bless {}, 'Local::PaxDispatchOSR' };
    local *Developer::Dashboard::Pax::ProfileGuidedAOT::new = sub { return bless {}, 'Local::PaxDispatchAOT' };
    local *Developer::Dashboard::Pax::Tier1::new = sub { return bless {}, 'Local::PaxDispatchTier1' };
    local *Developer::Dashboard::Pax::NativeRunner::new = sub { return bless {}, 'Local::PaxDispatchNativeRunner' };
    local *Local::PaxDispatchManifest::to_hash = sub { return $Local::PaxRuntimeDispatchFixture::MANIFEST };
    local *Local::PaxDispatchSelector::select = sub { return { selected => $Local::PaxRuntimeDispatchFixture::SSA } };
    local *Local::PaxDispatchHIR::lower_all = sub { return $Local::PaxRuntimeDispatchFixture::SSA };
    local *Local::PaxDispatchSSA::build_all = sub { return $Local::PaxRuntimeDispatchFixture::SSA };
    local *Local::PaxDispatchGuard::validate_or_deopt = sub {
        return { status => $Local::PaxRuntimeDispatchFixture::GUARD_STATUS,
                 fallback => { reason => 'missing_epoch' } };
    };
    local *Local::PaxDispatchProfileStore::record_dispatch = sub { push @Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS, $_[1]; return };
    local *Local::PaxDispatchInlineCache::lookup = sub { return { status => 'miss' } };
    local *Local::PaxDispatchInlineCache::update = sub { my %args = @_[ 1 .. $#_ ]; return { status => 'updated', method => $args{method} } };
    local *Local::PaxDispatchJIT::decision = sub { return { status => 'observe' } };
    local *Local::PaxDispatchOSR::evaluate = sub { return { status => 'observe', osr_event => 'observe' } };
    local *Local::PaxDispatchOSR::retirement = sub { my %args = @_[ 1 .. $#_ ]; return { status => 'retired', osr_event => 'retire', reason => $args{reason}, safepoint => $args{safepoint} } };
    local *Local::PaxDispatchAOT::plan = sub { return { status => 'planned' } };
    local *Local::PaxDispatchTier1::compile = sub { return $Local::PaxRuntimeDispatchFixture::ARTIFACT };
    local *Local::PaxDispatchNativeRunner::run_i64_binary = sub { return $Local::PaxRuntimeDispatchFixture::NATIVE_RESULT };

    $Local::PaxRuntimeDispatchFixture::SSA = $args{ssa} // [];
    $Local::PaxRuntimeDispatchFixture::GUARD_STATUS = $args{guard_status} // 'native_allowed';
    $Local::PaxRuntimeDispatchFixture::ARTIFACT = $args{artifact} // { entry_kind => 'native_i64_leaf', executable_path => '/fake/native', reason => 'compiled fixture' };
    $Local::PaxRuntimeDispatchFixture::NATIVE_RESULT = $args{native_result} // { status => 'ok', value => 5 };
    $Local::PaxRuntimeDispatchFixture::PROFILE_REPORT = $args{profile} // { regions => [] };
    @Local::PaxRuntimeDispatchFixture::PROFILE_EVENTS = ();
    my $dispatcher = bless {
        mode => $args{mode} // 'live',
        profile_store => bless({}, 'Local::PaxDispatchProfileStore'),
        inline_cache => bless({}, 'Local::PaxDispatchInlineCache'),
        hot_region_jit => bless({}, 'Local::PaxDispatchJIT'),
        osr => bless({}, 'Local::PaxDispatchOSR'),
        aot => bless({}, 'Local::PaxDispatchAOT'),
    }, 'Developer::Dashboard::Pax::RuntimeDispatcher';
    return $dispatcher->dispatch_i64(
        entrypoint => $args{entrypoint} // 'fixture.pl',
        (defined $args{region_name} ? (region_name => $args{region_name}) : ()),
    left => $args{left},
    right => $args{right},
    (defined $args{cache_site} ? (cache_site => $args{cache_site}) : ()),
);
}

__END__

=head1 NAME

t/251-pax-runtime-dispatcher-coverage.t - tests runtime dispatch outcomes

=head1 PURPOSE

This test isolates the runtime dispatcher from external capture and native
toolchains while exercising missing candidates, guard deoptimization,
interpreter fallback, successful native dispatch, failed native execution,
profile recording, and cache reporting.

=head1 WHY IT EXISTS

The dispatcher coordinates capture, region selection, guards, JIT/OSR policy,
artifact compilation, native execution, profiling, and AOT planning. The tests
verify that each outcome retains the corresponding attempts and decision data.

=head1 WHEN TO USE

Run this test when changing C<Developer::Dashboard::Pax::RuntimeDispatcher>
or any of its dispatch-result contracts.

=head1 HOW TO USE

Run inside the development container:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/251-pax-runtime-dispatcher-coverage.t

=head1 WHAT USES IT

PAX runtime callers use C<dispatch_i64> to choose guarded native execution or
fallback, while profile and cache CLI commands consume its reports.

=head1 EXAMPLES

Example 1: run the test alone in Docker to validate all dispatch result shapes.

Example 2: include it in C<script/coverage-gate> to measure the dispatch
coordinator's statements, branches, conditions, and subroutines.

=cut
