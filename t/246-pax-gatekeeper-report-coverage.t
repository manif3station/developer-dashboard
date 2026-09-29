#!/usr/bin/env perl

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Gatekeeper;

my $root = abs_path('.');
ok( defined $root && -d $root, 'repository root resolves before validation' );

my $gatekeeper = Developer::Dashboard::Pax::Gatekeeper->new( root => $root );
my $report = $gatekeeper->sow01_report;
is( $report->{sow}, 'SOW-01', 'SOW report identifies its governing statement of work' );
ok( ref($report->{checks}) eq 'ARRAY' && @{ $report->{checks} } >= 20, 'SOW report returns the complete check list' );
is( $report->{passed} + $report->{blocked}, scalar @{ $report->{checks} }, 'report totals account for every check' );
is( $report->{status}, $report->{blocked} ? 'not_passed' : 'passed', 'overall report status reflects the check totals' );
my %ids;
for my $check ( @{ $report->{checks} } ) {
    ok( ref($check) eq 'HASH', 'each validation result is a hash record' );
    ok( defined $check->{id} && $check->{id} ne '', 'each validation result has an identifier' );
    ok( defined $check->{description} && $check->{description} ne '', 'each validation result explains its purpose' );
    ok( $check->{status} eq 'passed' || $check->{status} eq 'blocked', 'each validation result has a recognized status' );
    ok( defined $check->{evidence}, 'each validation result reports its evidence' );
    ok( !$ids{ $check->{id} }++, 'validation identifiers are unique' );
}

my $temp_root = tempdir( CLEANUP => 1 );
my $fixture = File::Spec->catfile( $temp_root, 'present.txt' );
open my $fh, '>', $fixture or die "Unable to write $fixture: $!";
print {$fh} "present\n";
close $fh or die "Unable to close $fixture: $!";
my $fixture_gatekeeper = Developer::Dashboard::Pax::Gatekeeper->new( root => $temp_root );
is( $fixture_gatekeeper->_check_file( 'present', 'present.txt', 'fixture present' )->{status}, 'passed', '_check_file passes for an existing file' );
is( $fixture_gatekeeper->_check_file( 'missing', 'missing.txt', 'fixture missing' )->{status}, 'blocked', '_check_file blocks for a missing file' );
is( $fixture_gatekeeper->_check_test_file( 'present_test', 'present.txt', 'fixture test' )->{status}, 'passed', '_check_test_file preserves the file-check contract' );
is( $fixture_gatekeeper->_check_no_path( 'absent', 'absent.txt', 'fixture absent' )->{status}, 'passed', '_check_no_path passes when the path is absent' );
is( $fixture_gatekeeper->_check_no_path( 'present', 'present.txt', 'fixture present' )->{status}, 'blocked', '_check_no_path blocks when the path exists' );
is( Developer::Dashboard::Pax::Gatekeeper::_slurp($fixture), "present\n", '_slurp returns file content' );
is( Developer::Dashboard::Pax::Gatekeeper::_slurp( File::Spec->catfile( $temp_root, 'missing.txt' ) ), '', '_slurp represents an unreadable path as empty content' );

my $project_dir = File::Spec->catdir( $temp_root, 'project' );
make_path($project_dir);
open my $backlog_fh, '>', File::Spec->catfile( $project_dir, 'BACKLOG.md' ) or die "Unable to write fixture backlog: $!";
print {$backlog_fh} "| SOW-01 |\nplaceholder\n";
close $backlog_fh or die "Unable to close fixture backlog: $!";
my $sparse_gatekeeper = Developer::Dashboard::Pax::Gatekeeper->new( root => $temp_root );
for my $method (
    qw(
      _check_real_backend_integration
      _check_real_hot_region_jit_aot
      _check_real_cpan_xs_coverage
      _check_backlog_approved_sows
      _check_docker_pin
      _check_cli_surface
      _check_whole_program_app_image
      _check_benchmark_matrix_command
      _check_validation_matrix
      _check_core_suite
      _check_cpan_matrix
      _check_semantic_snapshot_capture
      _check_optree_derived_hir_lowering
      _check_broad_cpan_xs_matrix
      _check_deopt_frame_fields
      _check_current_docs_no_gap_language
    )
  )
{
    my $check = $sparse_gatekeeper->$method();
    ok( ref($check) eq 'HASH' && $check->{status} eq 'blocked', "$method reports its missing or invalid fixture evidence" );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Backend::Tier1CraneliftEquivalent::metadata = sub { return; };
    local *Developer::Dashboard::Pax::Backend::Tier2LLVM::metadata = sub { return; };
    is( $sparse_gatekeeper->_check_tiered_backend_architecture->{status}, 'blocked', 'tiered backend check reports absent backend metadata' );
}

my $tier2_path = File::Spec->catfile( $temp_root, 'lib', 'Developer', 'Dashboard', 'Pax', 'Backend', 'Tier2LLVM.pm' );
make_path( File::Spec->catdir( $temp_root, 'lib', 'Developer', 'Dashboard', 'Pax', 'Backend' ) );
open my $tier2_fh, '>', $tier2_path or die "Unable to write fixture Tier2 module: $!";
print {$tier2_fh} "LLVM\n";
close $tier2_fh or die "Unable to close fixture Tier2 module: $!";
ok( $sparse_gatekeeper->_check_real_backend_integration->{status} eq 'blocked', 'backend integration reports an incomplete LLVM source contract' );

my $valid_backlog = File::Spec->catfile( $project_dir, 'BACKLOG.md' );
open my $valid_backlog_fh, '>', $valid_backlog or die "Unable to update fixture backlog: $!";
print {$valid_backlog_fh} "| SOW-01 |\n| SOW-02 |\n";
close $valid_backlog_fh or die "Unable to close fixture backlog: $!";
is( $sparse_gatekeeper->_check_backlog_approved_sows->{status}, 'passed', 'backlog check accepts exactly the two approved SOW entries' );
open my $extra_backlog_fh, '>>', $valid_backlog or die "Unable to append fixture backlog: $!";
print {$extra_backlog_fh} "| SOW-03 |\n";
close $extra_backlog_fh or die "Unable to close fixture backlog: $!";
is( $sparse_gatekeeper->_check_backlog_approved_sows->{status}, 'blocked', 'backlog check rejects an unapproved SOW entry' );

my $pax_root = File::Spec->catdir( $temp_root, 'lib', 'Developer', 'Dashboard', 'Pax' );
make_path($pax_root);
my $cli_path = File::Spec->catfile( $pax_root, 'CLI.pm' );
open my $cli_fh, '>', $cli_path or die "Unable to write fixture PAX CLI: $!";
print {$cli_fh} "if (\$command eq 'build') if (\$command eq 'run') --asset --paxfile\n";
close $cli_fh or die "Unable to close fixture PAX CLI: $!";
my $app_image_path = File::Spec->catfile( $pax_root, 'AppImage.pm' );
open my $app_image_fh, '>', $app_image_path or die "Unable to write fixture app image source: $!";
print {$app_image_fh} "pax_assets\n";
close $app_image_fh or die "Unable to close fixture app image source: $!";
ok( $sparse_gatekeeper->_check_whole_program_app_image->{status} eq 'blocked', 'app-image check detects incomplete asset and paxfile CLI options' );

my $report_dir = File::Spec->catdir( $temp_root, 'projects', 'sow-01-project-pax', 'epic-06-validation-benchmarking-delivery' );
make_path($report_dir);
open my $full_cli_fh, '>', $cli_path or die "Unable to update fixture PAX CLI: $!";
print {$full_cli_fh} "core-suite cpan-matrix\n";
close $full_cli_fh or die "Unable to close fixture PAX CLI: $!";
for my $report_name ( 'perl-core-suite-report.md', 'cpan-matrix-report.md' ) {
    open my $report_fh, '>', File::Spec->catfile( $report_dir, $report_name ) or die "Unable to write fixture report: $!";
    print {$report_fh} "recorded\n";
    close $report_fh or die "Unable to close fixture report: $!";
}
is( $sparse_gatekeeper->_check_core_suite->{status}, 'passed', 'core-suite check requires both CLI wiring and its report' );
is( $sparse_gatekeeper->_check_cpan_matrix->{status}, 'passed', 'CPAN-matrix check requires both CLI wiring and its report' );

my $matrix_dir = File::Spec->catdir( $temp_root, 't' );
make_path($matrix_dir);
my $matrix_path = File::Spec->catfile( $matrix_dir, 'cpan_matrix.json' );
open my $matrix_fh, '>', $matrix_path or die "Unable to write fixture CPAN matrix: $!";
print {$matrix_fh} ( '"distribution":{},' x 7 ) . '"installed-xs-backed-cpan"';
close $matrix_fh or die "Unable to close fixture CPAN matrix: $!";
is( $sparse_gatekeeper->_check_broad_cpan_xs_matrix->{status}, 'passed', 'broad matrix accepts seven distributions including an XS-backed entry' );
is( $sparse_gatekeeper->_check_real_cpan_xs_coverage->{status}, 'blocked', 'real XS check rejects a matrix missing compatibility-level metadata' );
open my $broad_without_xs_fh, '>', $matrix_path or die "Unable to update fixture CPAN matrix: $!";
print {$broad_without_xs_fh} ( '"distribution":{},' x 7 );
close $broad_without_xs_fh or die "Unable to close fixture CPAN matrix: $!";
is( $sparse_gatekeeper->_check_broad_cpan_xs_matrix->{status}, 'blocked', 'broad matrix rejects seven distributions without an XS-backed entry' );
open my $threshold_matrix_fh, '>', $matrix_path or die "Unable to update fixture CPAN matrix: $!";
print {$threshold_matrix_fh} ( '"distribution":{},' x 25 );
close $threshold_matrix_fh or die "Unable to close fixture CPAN matrix: $!";
is( $sparse_gatekeeper->_check_real_cpan_xs_coverage->{status}, 'blocked', 'real XS check independently enforces declared XS metadata and compatibility levels after the distribution threshold' );
open my $complete_matrix_fh, '>', $matrix_path or die "Unable to update fixture CPAN matrix: $!";
print {$complete_matrix_fh} ( '"distribution":{},' x 25 ) . 'declared-xs Level A';
close $complete_matrix_fh or die "Unable to close fixture CPAN matrix: $!";
is( $sparse_gatekeeper->_check_real_cpan_xs_coverage->{status}, 'passed', 'real XS check passes a broad matrix with explicit XS and compatibility-level metadata' );

my $docs = File::Spec->catdir( $temp_root, 'projects', 'sow-01-project-pax' );
make_path($docs);
open my $doc_fh, '>', File::Spec->catfile( $docs, 'SOW.md' ) or die "Unable to write fixture status document: $!";
print {$doc_fh} "implementation is a placeholder\n";
close $doc_fh or die "Unable to close fixture status document: $!";
is( $sparse_gatekeeper->_check_current_docs_no_gap_language->{status}, 'blocked', 'documentation check detects explicit placeholder language' );

my $empty_file = File::Spec->catfile( $temp_root, 'empty.txt' );
open my $empty_fh, '>', $empty_file or die "Unable to create empty fixture file: $!";
close $empty_fh or die "Unable to close empty fixture file: $!";
is( Developer::Dashboard::Pax::Gatekeeper::_slurp($empty_file), '', '_slurp returns an empty string for an empty file' );

{
    my $passes = sub { return { status => 'passed' }; };
    no strict 'refs';
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Gatekeeper::_check_file = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_test_file = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_backlog_approved_sows = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_docker_pin = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_cli_surface = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_core_suite = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_cpan_matrix = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_validation_matrix = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_real_backend_integration = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_real_hot_region_jit_aot = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_real_cpan_xs_coverage = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_whole_program_app_image = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_benchmark_matrix_command = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_semantic_snapshot_capture = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_optree_derived_hir_lowering = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_tiered_backend_architecture = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_performance_observability_fields = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_current_docs_no_gap_language = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_broad_cpan_xs_matrix = $passes;
    local *Developer::Dashboard::Pax::Gatekeeper::_check_deopt_frame_fields = $passes;
    my $all_passed = $gatekeeper->sow01_report;
    is( $all_passed->{status}, 'passed', 'SOW aggregation passes when every check passes' );
    is( $all_passed->{blocked}, 0, 'SOW aggregation counts no blocked checks in the all-passed case' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::CoreSuite::run = sub { return { passed => 1 }; };
    local *Developer::Dashboard::Pax::Corpus::run = sub { return; };
    local *Developer::Dashboard::Pax::CPANMatrix::run = sub { return { passed => 0 }; };
    local *Developer::Dashboard::Pax::BenchmarkMatrix::run = sub { die "fixture matrix failure\n"; };
    is( $sparse_gatekeeper->_check_validation_matrix->{status}, 'blocked', 'validation aggregation distinguishes empty, failed, and throwing matrix results' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Backend::Tier1CraneliftEquivalent::metadata = sub { return { tier => 2, name => 'prototype backend' }; };
    local *Developer::Dashboard::Pax::Backend::Tier2LLVM::metadata = sub { return { tier => 1, status => 'disabled' }; };
    is( $sparse_gatekeeper->_check_tiered_backend_architecture->{status}, 'blocked', 'tiered backend check detects incorrect tier identifiers and prototype/disabled metadata' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub {
        return {
            capture => { status => 'ok' },
            compile_phase_events => [ 'BEGIN' ],
            lexical_pads => { subs => { fixture => 1 } },
            closure_descriptors => { subs => { fixture => 1 } },
            method_resolution => { fixture => 1 },
        };
    };
    my $manifest_dir = File::Spec->catdir( $temp_root, 'lib', 'Developer', 'Dashboard', 'Pax' );
    make_path($manifest_dir);
    for my $source_name ( 'Manifest.pm', 'Capture.pm' ) {
        open my $source_fh, '>', File::Spec->catfile( $manifest_dir, $source_name ) or die "Unable to write fixture source: $!";
        print {$source_fh} "lexical_pads closure_descriptors method_resolution regex_metadata compile_phase_events pad_layout closure_descriptor\n";
        close $source_fh or die "Unable to close fixture source: $!";
    }
    is( $sparse_gatekeeper->_check_semantic_snapshot_capture->{status}, 'passed', 'semantic snapshot check accepts complete captured metadata' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { die "fixture capture failure\n"; };
    is( $sparse_gatekeeper->_check_semantic_snapshot_capture->{status}, 'blocked', 'semantic snapshot check reports a capture exception as blocked' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub {
        return {
            capture => { status => 'ok' },
            compile_phase_events => [],
            lexical_pads => { subs => {} },
            closure_descriptors => { subs => {} },
            method_resolution => {},
        };
    };
    is( $sparse_gatekeeper->_check_semantic_snapshot_capture->{status}, 'blocked', 'semantic snapshot check rejects an empty but otherwise valid capture' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub { return { capture => { status => 'ok' } }; };
    local *Developer::Dashboard::Pax::RegionSelector::select = sub { return { selected => [] }; };
    local *Developer::Dashboard::Pax::HIR::lower_all = sub {
        return [ { source => { native_shape => { kind => 'i64_binary_leaf' }, optree_ops => ['const'] } } ];
    };
    my $hir_dir = File::Spec->catdir( $temp_root, 'lib', 'Developer', 'Dashboard', 'Pax' );
    make_path($hir_dir);
    open my $hir_fh, '>', File::Spec->catfile( $hir_dir, 'HIR.pm' ) or die "Unable to write fixture HIR source: $!";
    print {$hir_fh} 'source}{native_shape}';
    close $hir_fh or die "Unable to close fixture HIR source: $!";
    open my $selector_fh, '>', File::Spec->catfile( $hir_dir, 'RegionSelector.pm' ) or die "Unable to write fixture selector source: $!";
    print {$selector_fh} 'native_shape';
    close $selector_fh or die "Unable to close fixture selector source: $!";
    like( Developer::Dashboard::Pax::Gatekeeper::_slurp( File::Spec->catfile( $hir_dir, 'HIR.pm' ) ), qr/source\}\{native_shape\}/, 'fixture HIR exposes the manifest shape syntax the gate checks' );
    unlike( Developer::Dashboard::Pax::Gatekeeper::_slurp( File::Spec->catfile( $hir_dir, 'HIR.pm' ) ), qr/(?:open\s+my\s+\$fh|_slurp)/, 'fixture HIR does not read source files' );
    my $captured = Developer::Dashboard::Pax::Capture->new(mode => 'live')->capture('unused');
    my $manifest = Developer::Dashboard::Pax::Manifest->new(capture => $captured)->to_hash;
    my $regions = Developer::Dashboard::Pax::RegionSelector->new(manifest => $manifest)->select;
    my $units = Developer::Dashboard::Pax::HIR->new(manifest => $manifest, regions => $regions->{selected})->lower_all;
    ok( $units->[0]{source}{native_shape} && @{ $units->[0]{source}{optree_ops} }, 'fixture capture pipeline returns a native-shape HIR unit' );
    my $optree_pass = $sparse_gatekeeper->_check_optree_derived_hir_lowering;
    is( $optree_pass->{status}, 'passed', 'optree HIR check accepts manifest-native shapes without source reading' ) or diag explain $optree_pass;
    open my $no_shape_fh, '>', File::Spec->catfile( $hir_dir, 'HIR.pm' ) or die "Unable to update fixture HIR source: $!";
    print {$no_shape_fh} 'ordinary HIR source';
    close $no_shape_fh or die "Unable to close fixture HIR source: $!";
    is( $sparse_gatekeeper->_check_optree_derived_hir_lowering->{status}, 'blocked', 'optree HIR check rejects an implementation without manifest-native shape access' );
    open my $no_selector_fh, '>', File::Spec->catfile( $hir_dir, 'HIR.pm' ) or die "Unable to update fixture HIR source: $!";
    print {$no_selector_fh} 'source}{native_shape}';
    close $no_selector_fh or die "Unable to close fixture HIR source: $!";
    open my $no_selector_contract_fh, '>', File::Spec->catfile( $hir_dir, 'RegionSelector.pm' ) or die "Unable to update fixture selector source: $!";
    print {$no_selector_contract_fh} 'ordinary selector source';
    close $no_selector_contract_fh or die "Unable to close fixture selector source: $!";
    is( $sparse_gatekeeper->_check_optree_derived_hir_lowering->{status}, 'blocked', 'optree HIR check requires the region selector to preserve native-shape metadata' );
    open my $restore_selector_fh, '>', File::Spec->catfile( $hir_dir, 'RegionSelector.pm' ) or die "Unable to restore fixture selector source: $!";
    print {$restore_selector_fh} 'native_shape';
    close $restore_selector_fh or die "Unable to close fixture selector source: $!";
    {
        local *Developer::Dashboard::Pax::Capture::capture = sub { die "fixture capture failure\n"; };
        is( $sparse_gatekeeper->_check_optree_derived_hir_lowering->{status}, 'blocked', 'optree HIR check reports a failed capture-and-lowering pipeline as blocked' );
    }
    open my $source_read_fh, '>', File::Spec->catfile( $hir_dir, 'HIR.pm' ) or die "Unable to update fixture HIR source: $!";
    print {$source_read_fh} 'source}{native_shape} _slurp';
    close $source_read_fh or die "Unable to close fixture HIR source: $!";
    is( $sparse_gatekeeper->_check_optree_derived_hir_lowering->{status}, 'blocked', 'optree HIR check rejects lowering that reads source files' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Benchmark::run_runtime_benchmark = sub { return { memory_impact => {} }; };
    local *Developer::Dashboard::Pax::ProfileStore::report = sub { return { regions => [] }; };
    is( $sparse_gatekeeper->_check_performance_observability_fields->{status}, 'blocked', 'observability check rejects missing memory deltas and OSR event summaries' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Benchmark::run_runtime_benchmark = sub { return { memory_impact => { delta_rss_kb => 0 } }; };
    local *Developer::Dashboard::Pax::ProfileStore::report = sub {
        return { regions => [ { osr_promotions => 1, osr_retirements => 1 } ] };
    };
    is( $sparse_gatekeeper->_check_performance_observability_fields->{status}, 'passed', 'observability check passes when benchmark memory and both OSR events are present' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Benchmark::run_runtime_benchmark = sub { return { memory_impact => [] }; };
    local *Developer::Dashboard::Pax::ProfileStore::report = sub {
        return { regions => [ { osr_promotions => 0, osr_retirements => 0 } ] };
    };
    is( $sparse_gatekeeper->_check_performance_observability_fields->{status}, 'blocked', 'observability check rejects malformed memory metadata and absent OSR events' );
}

is( Developer::Dashboard::Pax::Gatekeeper->new->{root}, '.', 'constructor defaults the repository root when no root is supplied' );

my $complete_root = File::Spec->catdir( $temp_root, 'complete-root' );
my $complete_pax  = File::Spec->catdir( $complete_root, 'lib', 'Developer', 'Dashboard', 'Pax' );
my $complete_backend = File::Spec->catdir( $complete_pax, 'Backend' );
my $complete_tests = File::Spec->catdir( $complete_root, 't', 'fixtures', 'app_assets' );
make_path( $complete_backend, $complete_tests );
for my $relative ( 'AppImage.pm', 'AppServer.pm', 'Paxfile.pm' ) {
    open my $source_fh, '>', File::Spec->catfile( $complete_pax, $relative ) or die "Unable to write complete fixture source: $!";
    print {$source_fh} "PAX source\n";
    close $source_fh or die "Unable to close complete fixture source: $!";
}
open my $complete_cli_fh, '>', File::Spec->catfile( $complete_pax, 'CLI.pm' ) or die "Unable to write complete fixture CLI: $!";
print {$complete_cli_fh} <<'CLI';
if ($command eq 'build')
if ($command eq 'run')
--asset --asset-dir --paxfile --no-paxfile
CLI
close $complete_cli_fh or die "Unable to close complete fixture CLI: $!";
open my $complete_image_fh, '>', File::Spec->catfile( $complete_pax, 'AppImage.pm' ) or die "Unable to update complete fixture app image: $!";
print {$complete_image_fh} "pax_assets PAX_EMBEDDED_ASSET_ROOT\n";
close $complete_image_fh or die "Unable to close complete fixture app image: $!";
for my $relative ( 'paxfile.yml', 't/app_image.t', 't/fixtures/app_assets/banner.txt' ) {
    my $path = File::Spec->catfile( $complete_root, split m{/}, $relative );
    make_path( File::Basename::dirname($path) );
    open my $complete_fh, '>', $path or die "Unable to write complete fixture '$relative': $!";
    print {$complete_fh} "present\n";
    close $complete_fh or die "Unable to close complete fixture '$relative': $!";
}
my $complete_gatekeeper = Developer::Dashboard::Pax::Gatekeeper->new( root => $complete_root );
is( $complete_gatekeeper->_check_whole_program_app_image->{status}, 'passed', 'whole-program image check passes with every required file and CLI capability' );
is( $complete_gatekeeper->_check_benchmark_matrix_command->{status}, 'blocked', 'benchmark check rejects CLI content without the matrix command' );
open my $benchmark_cli_fh, '>>', File::Spec->catfile( $complete_pax, 'CLI.pm' ) or die "Unable to append fixture CLI: $!";
print {$benchmark_cli_fh} "bench-matrix\n";
close $benchmark_cli_fh or die "Unable to close fixture benchmark CLI: $!";
is( $complete_gatekeeper->_check_benchmark_matrix_command->{status}, 'passed', 'benchmark check recognizes the matrix command' );

my $surface_path = File::Spec->catfile( $complete_pax, 'CLI.pm' );
open my $surface_fh, '>', $surface_path or die "Unable to reset fixture CLI: $!";
print {$surface_fh} "if (\$command eq 'build') if (\$command eq 'run') if (\$command eq 'capture')\n";
close $surface_fh or die "Unable to close fixture surface CLI: $!";
my $surface_result = $complete_gatekeeper->_check_cli_surface;
is( $surface_result->{status}, 'blocked', 'public CLI check detects extra command exposure' );
like( $surface_result->{evidence}, qr/^extra: capture$/, 'public CLI check identifies the extra command' );

my $backend_root = File::Spec->catdir( $temp_root, 'backend-root' );
my $backend_dir = File::Spec->catdir( $backend_root, 'lib', 'Developer', 'Dashboard', 'Pax', 'Backend' );
make_path($backend_dir);
open my $tier1_fixture_fh, '>', File::Spec->catfile( $backend_root, 'lib', 'Developer', 'Dashboard', 'Pax', 'Tier1.pm' ) or die "Unable to write Tier 1 fixture: $!";
print {$tier1_fixture_fh} "rustc Cranelift\n";
close $tier1_fixture_fh or die "Unable to close Tier 1 fixture: $!";
open my $tier2_fixture_fh, '>', File::Spec->catfile( $backend_dir, 'Tier2LLVM.pm' ) or die "Unable to write Tier 2 fixture: $!";
print {$tier2_fixture_fh} "LLVM module emitter\n";
close $tier2_fixture_fh or die "Unable to close Tier 2 fixture: $!";
my $backend_result = Developer::Dashboard::Pax::Gatekeeper->new( root => $backend_root )->_check_real_backend_integration;
is( $backend_result->{status}, 'blocked', 'backend integration rejects a rustc-based Tier 1 implementation even when LLVM is present' );
like( $backend_result->{evidence}, qr/real_cranelift_backend/, 'backend integration identifies the rustc-based implementation' );

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::CoreSuite::run = sub { return { passed => 1 }; };
    local *Developer::Dashboard::Pax::Corpus::run = sub { return { passed => 1 }; };
    local *Developer::Dashboard::Pax::CPANMatrix::run = sub { return { passed => 1 }; };
    local *Developer::Dashboard::Pax::BenchmarkMatrix::run = sub { return { passed => 1 }; };
    my $validation = $sparse_gatekeeper->_check_validation_matrix;
    is( $validation->{status}, 'passed', 'validation matrix reports success when every suite passes' );
    is( $validation->{evidence}, 'core-suite, corpus, cpan-matrix, bench-matrix', 'validation matrix lists all passing suites as evidence' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub {
        return {
            capture => {},
            compile_phase_events => undef,
            lexical_pads => { subs => undef },
            closure_descriptors => { subs => undef },
            method_resolution => undef,
        };
    };
    my $incomplete = $sparse_gatekeeper->_check_semantic_snapshot_capture;
    is( $incomplete->{status}, 'blocked', 'semantic snapshot reports missing optional metadata fields as blocked' );
    like( $incomplete->{evidence}, qr/compile_phase_events/, 'semantic snapshot records fields absent from an otherwise present snapshot' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub { return; };
    my $absent_snapshot = $sparse_gatekeeper->_check_semantic_snapshot_capture;
    is( $absent_snapshot->{status}, 'blocked', 'semantic snapshot reports an absent manifest snapshot as blocked' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => 'ok' }; };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub { return { capture => { status => 'ok' } }; };
    local *Developer::Dashboard::Pax::RegionSelector::select = sub { return { selected => [] }; };
    local *Developer::Dashboard::Pax::HIR::lower_all = sub {
        return [ { source => { native_shape => { kind => 'i64_binary_leaf' }, optree_ops => undef } } ];
    };
    my $optree = $sparse_gatekeeper->_check_optree_derived_hir_lowering;
    is( $optree->{status}, 'blocked', 'optree validation rejects a native shape without captured operations' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Backend::Tier1CraneliftEquivalent::metadata = sub { return {}; };
    local *Developer::Dashboard::Pax::Backend::Tier2LLVM::metadata = sub { return {}; };
    my $tiered = $sparse_gatekeeper->_check_tiered_backend_architecture;
    is( $tiered->{status}, 'blocked', 'tiered backend check handles metadata hashes with all optional fields absent' );
    is( $tiered->{evidence}, 'missing: tier1, tier2, tier2_enabled', 'tiered backend check reports fields that are actually invalid while defaulting absent names' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Benchmark::run_runtime_benchmark = sub { return; };
    local *Developer::Dashboard::Pax::ProfileStore::report = sub { return { regions => [ {} ] }; };
    my $observability = $sparse_gatekeeper->_check_performance_observability_fields;
    is( $observability->{status}, 'blocked', 'observability handles absent benchmark and region counters' );
    like( $observability->{evidence}, qr/benchmark_memory_impact.*benchmark_memory_delta.*osr_promotion_events.*osr_retirement_events/, 'observability lists every absent measurement' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Benchmark::run_runtime_benchmark = sub { return { memory_impact => { delta_rss_kb => 0 } }; };
    local *Developer::Dashboard::Pax::ProfileStore::report = sub { return { regions => [ {} ] }; };
    my $observability = $sparse_gatekeeper->_check_performance_observability_fields;
    like( $observability->{evidence}, qr/osr_promotion_events.*osr_retirement_events/, 'zeroed region counters independently report both OSR event gaps' );
}

done_testing();

__END__

=head1 NAME

t/246-pax-gatekeeper-report-coverage.t - verifies the complete PAX SOW report contract

=head1 PURPOSE

This test runs the real PAX SOW-01 report and checks its aggregate and per-check
result shape. It also exercises positive and negative filesystem evidence for the
small path-check helpers.

=head1 WHY IT EXISTS

Gatekeeper is the Perl API behind PAX's release and statement-of-work validation.
Its report combines static repository evidence with live validation pipelines, so
testing only one individual helper would not verify that the complete report is
assembled consistently.

=head1 WHEN TO USE

Run this test when changing SOW report checks, report status aggregation, evidence
records, or the shared file and path predicates.

=head1 HOW TO USE

Run inside the repository's isolated Docker development service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/246-pax-gatekeeper-report-coverage.t

The report executes its real validation matrix and may take longer than a unit-only
test. Filesystem edge cases use a temporary fixture directory that is removed when
the test exits.

=head1 WHAT USES IT

The report exercises C<Developer::Dashboard::Pax::Gatekeeper> and the PAX capture,
manifest, HIR, backend, matrix, profile, and app-image checks that it coordinates.

=head1 EXAMPLES

Example 1: run the focused test to verify the report shape and each validation
record's status/evidence contract.

Example 2: run C<script/coverage-gate> in Docker to include these real validation
paths in all four repository coverage metrics.

The fixtures also distinguish failed capture from incomplete metadata, exercise
both sides of the HIR source-contract check, and validate present, malformed, and
missing performance-observability fields. CPAN fixtures cover the seven- and
twenty-five-distribution thresholds, XS declarations, and compatibility levels.

=cut
