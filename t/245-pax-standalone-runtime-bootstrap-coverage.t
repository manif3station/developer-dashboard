#!/usr/bin/env perl

use strict;
use warnings;

use Capture::Tiny qw(capture);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::XS ();
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneRuntime ();

my $root = tempdir( CLEANUP => 1 );
my $code_root = File::Spec->catdir( $root, 'code' );
my $entry_dir = File::Spec->catdir( $code_root, 'bin' );
make_path($entry_dir);

my $logical_entrypoint = 'bin/fixture.script.json';
my $entrypoint = File::Spec->catfile( $entry_dir, 'fixture.script.json' );
my $source_path = File::Spec->catfile( $root, 'source.pl' );
open my $source_fh, '>', $source_path or die "Unable to write $source_path: $!";
print {$source_fh} "print 'source fallback';\n1;\n";
close $source_fh or die "Unable to close $source_path: $!";

open my $fixture_entry_fh, '>', $entrypoint or die "Unable to write $entrypoint: $!";
print {$fixture_entry_fh} JSON::XS->new->canonical->encode( { script_source => "print 'unit source';\n1;\n" } );
close $fixture_entry_fh or die "Unable to close $entrypoint: $!";

my $manifest_path = File::Spec->catfile( $root, 'manifest.json' );
my $manifest = {
    app => {
        namespace => 'Fixture::Dashboard',
        compat    => { legacy_namespace => 'Fixture::Legacy' },
    },
    entrypoint => { logical_path => $logical_entrypoint, source_path => $source_path },
    native_dispatch => [ { region_name => 'Fixture::add', executable_logical_path => 'native/add' } ],
    code_units => [
        {
            logical_path   => $logical_entrypoint,
            unit_kind      => 'entrypoint',
            package        => 'Fixture::Main',
            script_source  => "print 'unit source';\n1;\n",
            source_path    => $source_path,
            require_path   => 'Fixture/Main.pm',
        },
        {
            logical_path => 'Fixture/Compiled.pcu.json',
            package      => 'Fixture::Compiled',
            require_path => 'Fixture/Compiled.pm',
            packaging    => 'compiled_pcu_v1',
        },
    ],
};
open my $manifest_fh, '>', $manifest_path or die "Unable to write $manifest_path: $!";
print {$manifest_fh} JSON::XS->new->canonical->encode($manifest);
close $manifest_fh or die "Unable to close $manifest_path: $!";

my $compiled_record_path = File::Spec->catfile( $code_root, 'Fixture', 'Compiled.pcu.json' );
make_path( dirname($compiled_record_path) );
open my $compiled_fh, '>', $compiled_record_path or die "Unable to write $compiled_record_path: $!";
print {$compiled_fh} JSON::XS->new->canonical->encode(
    {
        package => 'Fixture::Compiled',
        subs    => [ { name => 'answer', op => 'return_literal', value => 42 } ],
    }
);
close $compiled_fh or die "Unable to close $compiled_record_path: $!";

local $ENV{PAX_STANDALONE_MANIFEST_PATH} = $manifest_path;
local $ENV{PAX_STANDALONE_TMPDIR} = $root;
local $ENV{PAX_STANDALONE_TRACE};

my $state = Developer::Dashboard::Pax::StandaloneRuntime::_state();
is( $state->{root}, $root, '_state loads the private extraction root from the runtime environment' );
is( $state->{app_namespace}, 'Fixture::Dashboard', '_state normalizes the application namespace' );
is( $state->{legacy_namespace}, 'Fixture::Legacy', '_state keeps the configured legacy namespace' );
ok( $state->{compiled_packages}{'Fixture::Main'}, '_state records packages declared by code units' );
ok( $state->{compiled_units}{'Fixture/Compiled.pm'}, '_state indexes compiled require paths' );
is( $state->{by_region}{'Fixture::add'}{executable_logical_path}, 'native/add', '_state indexes native dispatch regions' );
ok( Developer::Dashboard::Pax::StandaloneRuntime::_load_compiled_require('Fixture/Compiled.pm'), 'compiled require loads an indexed code-unit record' );
{
    no strict 'refs';
    is( &{'Fixture::Compiled::answer'}(), 42, 'compiled require installs and executes the declared return-literal subroutine' );
}
ok( Developer::Dashboard::Pax::StandaloneRuntime::_load_compiled_require('Fixture/Compiled.pm'), 'compiled require returns success for an already-loaded unit' );
ok( !Developer::Dashboard::Pax::StandaloneRuntime::_load_compiled_require('Unknown/Module.pm'), 'compiled require declines paths absent from the manifest' );

ok( !Developer::Dashboard::Pax::StandaloneRuntime::_entrypoint_looks_valid(undef), 'entrypoint validation rejects undef' );
ok( !Developer::Dashboard::Pax::StandaloneRuntime::_entrypoint_looks_valid('-h'), 'entrypoint validation rejects option-shaped paths' );
ok( !Developer::Dashboard::Pax::StandaloneRuntime::_entrypoint_looks_valid(" \t"), 'entrypoint validation rejects whitespace-only paths' );
ok( Developer::Dashboard::Pax::StandaloneRuntime::_entrypoint_looks_valid('bin/app.pl'), 'entrypoint validation accepts a non-empty path' );

ok( Developer::Dashboard::Pax::StandaloneRuntime::_system_command_missing(undef, undef), 'missing-command detection handles an absent exit status' );
ok( Developer::Dashboard::Pax::StandaloneRuntime::_system_command_missing('', -1), 'missing-command detection handles launch failure status' );
ok( Developer::Dashboard::Pax::StandaloneRuntime::_system_command_missing('', 127), 'missing-command detection handles shell status 127' );
ok( Developer::Dashboard::Pax::StandaloneRuntime::_system_command_missing('No such file or directory', 1), 'missing-command detection recognizes exec diagnostics' );
ok( !Developer::Dashboard::Pax::StandaloneRuntime::_system_command_missing('ordinary command error', 1), 'missing-command detection leaves ordinary command errors distinct' );
my ( $captured_out, $captured_err, $captured_exit ) = Developer::Dashboard::Pax::StandaloneRuntime::_capture_system_command( $^X, '-e', 'print "child output"' );
is( $captured_out, 'child output', 'system capture returns child stdout' );
is( $captured_err, '', 'system capture returns child stderr separately' );
is( $captured_exit, 0, 'system capture returns the child exit status' );

is(
    Developer::Dashboard::Pax::StandaloneRuntime::_resolve_entrypoint_from_manifest('missing'),
    $entrypoint,
    'manifest resolution falls back to the existing logical entrypoint file',
);
is( Developer::Dashboard::Pax::StandaloneRuntime::_virtual_source_logical_path({ logical_path => 'bin/main.script.json' }), 'bin/main.pl', 'script records map to virtual Perl source paths' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_virtual_source_logical_path({ logical_path => 'bin/main.dispatch.json' }), 'bin/main.pl', 'dispatch records map to virtual Perl source paths' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_virtual_source_logical_path({ logical_path => 'bin/main.cli-router.json' }), File::Spec->catfile( 'virtual', 'entrypoint.pl' ), 'unrecognized entrypoint record suffixes use the virtual fallback path' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_virtual_source_logical_path({ require_path => 'Fixture/Thing.pm', logical_path => 'Fixture/Thing.pcu.json' }), 'Fixture/Thing.pm', 'compiled module paths map to their source module paths' );

my $virtual_path = Developer::Dashboard::Pax::StandaloneRuntime::_ensure_virtual_source_file({ logical_path => $logical_entrypoint });
ok( -f $virtual_path, '_ensure_virtual_source_file creates a source placeholder when absent' );
like( do { open my $fh, '<', $virtual_path or die $!; local $/; <$fh> }, qr/PAX compiled unit placeholder/, 'virtual source placeholders identify their compiled unit' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_ensure_virtual_source_file({ logical_path => $logical_entrypoint }), $virtual_path, 'existing virtual source files are reused' );

my ($unit) = grep { $_->{logical_path} eq $logical_entrypoint } @{ $state->{manifest}{code_units} };
is( Developer::Dashboard::Pax::StandaloneRuntime::_find_code_unit_for_entrypoint($entrypoint), $unit, 'entrypoint lookup matches the packaged logical path' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_script_source_from_code_units($entrypoint), "print 'unit source';\n1;\n", 'script source resolves from the indexed code unit record' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_source_path_to_script_source($entrypoint), "print 'source fallback';\n1;\n", 'script source can be read from its recorded source file' );
$unit->{residual_payload} = "print 'residual source';\n1;\n";
is( Developer::Dashboard::Pax::StandaloneRuntime::_script_source_from_residual_payload($entrypoint), $unit->{residual_payload}, 'residual script payload is a final source fallback' );

open my $entry_fh, '>', $entrypoint or die "Unable to write $entrypoint: $!";
print {$entry_fh} JSON::XS->new->canonical->encode( { script_source => "print 'runtime script';\n1;\n" } );
close $entry_fh or die "Unable to close $entrypoint: $!";
my ( $script_stdout, $script_stderr, $script_result ) = capture {
    Developer::Dashboard::Pax::StandaloneRuntime->run(
        entrypoint => $entrypoint,
        argv       => [],
    );
};
is( $script_stdout, 'runtime script', 'run bootstraps runtime hooks and executes a packaged script record' );
is( $script_stderr, '', 'script execution leaves stderr clear on success' );
is( $script_result, 1, 'run returns the script source result' );
my ( $fallback_stdout, undef, $fallback_result ) = capture {
    Developer::Dashboard::Pax::StandaloneRuntime->run(
        entrypoint => '-invalid-entrypoint',
        argv       => [],
    );
};
is( $fallback_stdout, 'runtime script', 'run resolves an invalid explicit entrypoint from the manifest' );
is( $fallback_result, 1, 'manifest-resolved entrypoint returns its script result' );
{
    local $state->{manifest}{entrypoint} = {};
    local $state->{manifest}{code_units} = [];
    local @ARGV = ();
    my $ok = eval {
        Developer::Dashboard::Pax::StandaloneRuntime->run( entrypoint => undef, argv => [] );
        1;
    };
    ok( !$ok, 'run rejects a missing entrypoint when the manifest has no fallback' );
    like( $@, qr/entrypoint required/, 'missing-entrypoint failure explains the required input' );
}

local $ENV{PAX_STANDALONE_EXECUTABLE} = File::Spec->catfile( $root, "binary's path" );
is( Developer::Dashboard::Pax::StandaloneRuntime::_standalone_executable_path(), File::Spec->catfile( $root, "binary's path" ), 'standalone executable resolution preserves a missing absolute executable path' );
like(
    Developer::Dashboard::Pax::StandaloneRuntime::_standalone_internal_cli_wrapper_content('query'),
    qr/exec '\/tmp\/[^\n]*binary'"'"'s path' --pax-standalone-helper 'query'/,
    'standalone helper wrapper shell-quotes executable and helper names',
);
my ( undef, $trace_stderr ) = capture {
    local $ENV{PAX_STANDALONE_TRACE} = 1;
    Developer::Dashboard::Pax::StandaloneRuntime::_trace('fixture trace');
};
like( $trace_stderr, qr/\[pax-standalone\] fixture trace\n/, 'runtime trace writes an explicit diagnostic when tracing is enabled' );

my $template_path = File::Spec->catfile( $root, 'asset.tt' );
open my $template_fh, '>', $template_path or die "Unable to write $template_path: $!";
print {$template_fh} 'Hello [% name %]; missing=[% missing %]';
close $template_fh or die "Unable to close $template_path: $!";
is( Developer::Dashboard::Pax::StandaloneRuntime::_render_simple_template_asset( $template_path, { name => 'world' } ), 'Hello world; missing=', 'simple embedded templates render present and absent variables' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_render_simple_template_asset( '', {} ), undef, 'simple template renderer ignores an empty path' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_render_simple_template_asset( File::Spec->catfile( $root, 'absent.tt' ), {} ), undef, 'simple template renderer ignores a missing asset' );

my $hit_log = File::Spec->catfile( $root, 'native-hits.log' );
local $ENV{PAX_STANDALONE_NATIVE_HIT_LOG} = $hit_log;
Developer::Dashboard::Pax::StandaloneRuntime::_log_native_hit('Fixture::add');
open my $hit_fh, '<', $hit_log or die "Unable to read $hit_log: $!";
is( <$hit_fh>, "Fixture::add\n", 'native hit logging appends the selected region' );
close $hit_fh;

is( Developer::Dashboard::Pax::StandaloneRuntime::_app_env_prefix(), 'FIXTURE_DASHBOARD', 'environment prefix uses the application namespace when no compatibility namespace is configured' );
{
    local $state->{manifest}{app}{command} = 'fixture';
    local $state->{app_env_prefix} = undef;
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_command_name(), 'fixture', 'application command falls back to its manifest command' );
    local $ENV{FIXTURE_DASHBOARD_COMMAND} = 'environment-command';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_command_name(), 'environment-command', 'application command honors its normalized environment override' );
    local $ENV{FIXTURE_SUBCOMMAND} = 'sub-environment-command';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command( sub_env => 'FIXTURE_SUBCOMMAND' ), 'sub-environment-command', 'entry command honors an explicit subcommand environment override' );
    local $ENV{FIXTURE_ENTRY} = 'entry-environment-command';
    local $state->{manifest}{app}{entrypoint_env} = 'FIXTURE_ENTRY';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command(), 'entry-environment-command', 'entry command honors the manifest entrypoint environment override' );
    local $state->{manifest}{app}{entrypoint_fallback} = 'entry-fallback';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command(), 'entry-environment-command', 'entrypoint environment takes precedence over fallback command' );
    local $ENV{FIXTURE_ENTRY} = '';
    local $ENV{FIXTURE_DASHBOARD_COMMAND} = '';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command(), 'entry-fallback', 'entry command falls back to the configured entrypoint command' );
}

is( Developer::Dashboard::Pax::StandaloneRuntime::_standalone_internal_cli_class(), 'Fixture::Dashboard::InternalCLI', 'internal CLI class is derived from the app namespace' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_direct_standalone_helper_name_from_path('/usr/local/bin/doctor'), 'doctor', 'direct helper lookup uses the executable basename' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_direct_standalone_helper_name_from_path(''), undef, 'direct helper lookup rejects an empty path' );
ok( Developer::Dashboard::Pax::StandaloneRuntime::_standalone_helper_delegates_to_dashboard_core("_dashboard-core\nmy \$command = basename(\$0);\nexec { \$^X } \$^X, \$core, \$command, \@ARGV;"), 'dashboard helper delegation recognizes its explicit core-exec contract' );
ok( !Developer::Dashboard::Pax::StandaloneRuntime::_standalone_helper_delegates_to_dashboard_core('ordinary helper'), 'dashboard helper delegation rejects unrelated helper source' );

my $asset_path = File::Spec->catfile( $root, 'assets', 'private-cli', 'fixture-helper' );
make_path( dirname($asset_path) );
open my $asset_fh, '>', $asset_path or die "Unable to write $asset_path: $!";
print {$asset_fh} "print 'embedded helper';\n1;\n";
close $asset_fh or die "Unable to close $asset_path: $!";
local $state->{manifest}{assets} = [ { logical_path => 'private-cli/fixture-helper' } ];
is( Developer::Dashboard::Pax::StandaloneRuntime::_standalone_embedded_asset_path('fixture-helper'), $asset_path, 'embedded helper asset resolves by its basename' );
my ( $asset_content, $asset_source ) = Developer::Dashboard::Pax::StandaloneRuntime::_standalone_internal_cli_asset_content('fixture-helper');
is( $asset_content, "print 'embedded helper';\n1;\n", 'embedded helper content is read from the extracted asset' );
is( $asset_source, $asset_path, 'embedded helper content retains its source path' );

ok( Developer::Dashboard::Pax::StandaloneRuntime::_eligible_i64_args([ -2, 10 ]), 'native integer dispatch accepts two signed integer arguments' );
ok( !Developer::Dashboard::Pax::StandaloneRuntime::_eligible_i64_args([ 1 ]), 'native integer dispatch rejects an argument-count mismatch' );
ok( !Developer::Dashboard::Pax::StandaloneRuntime::_eligible_i64_args([ undef, 1 ]), 'native integer dispatch rejects undefined arguments' );
ok( !Developer::Dashboard::Pax::StandaloneRuntime::_eligible_i64_args([ 1, '1.5' ]), 'native integer dispatch rejects non-integer arguments' );

done_testing();

__END__

=head1 NAME

t/245-pax-standalone-runtime-bootstrap-coverage.t - exercises standalone runtime bootstrap and script loading

=head1 PURPOSE

This integration-oriented unit test covers the manifest-backed bootstrap helpers in
C<Developer::Dashboard::Pax::StandaloneRuntime>, including state construction,
entrypoint resolution, virtual source paths, script source selection, command
capture, template assets, native-hit logging, environment-derived command
selection, embedded private CLI assets, helper delegation, and native argument
eligibility.

=head1 WHY IT EXISTS

StandaloneRuntime is copied into each PAX executable and has behavior that is not
covered merely by testing the PAX builder. This test drives the real runtime
functions with an isolated temporary manifest and extracted-code tree so these
branches remain verifiable without depending on a previously built binary.

=head1 WHEN TO USE

Run this test when changing runtime environment setup, manifest parsing,
compiled package loading, entrypoint dispatch, script fallback ordering, virtual
source creation, environment command selection, embedded helper lookup, shell
wrapper generation, native dispatch eligibility, or runtime diagnostic helpers.

=head1 HOW TO USE

Run it through the repository's Docker development service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/245-pax-standalone-runtime-bootstrap-coverage.t

The fixture creates and removes its own temporary files; it requires no project
configuration or prebuilt PAX executable.

=head1 WHAT USES IT

The test invokes C<StandaloneRuntime> helpers directly using a minimal manifest
matching the extracted payload layout. Production standalone executables use the
same functions after extracting their payload and selecting an entrypoint.

=head1 EXAMPLES

Example 1: run the test by itself to verify the runtime helper contract.

Example 2: run C<prove -lr t> through the project Docker coverage gate to include
these calls in the repository-wide statement, branch, condition, and subroutine
reports.

=cut
