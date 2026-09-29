use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Spec;
use Test::More;
use lib 'lib';
use Developer::Dashboard::Pax::CLI;

# write_script($directory, $name, $source)
# Creates one temporary executable fixture used by interpreter-mode tests.
# Input: temporary directory path, filename, and complete Perl source text.
# Output: absolute path to the written fixture.
sub write_script {
    my ( $directory, $name, $source ) = @_;
    my $path = File::Spec->catfile( $directory, $name );
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $source or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    return $path;
}

my $work = tempdir( CLEANUP => 1 );
my $help = '';
{
    local *STDOUT;
    open STDOUT, '>', \$help or die "Unable to capture stdout: $!";
    is( Developer::Dashboard::Pax::CLI->run('help'), 0, 'run returns success for help' );
}
like( $help, qr/^usage:\n  pax build /, 'help prints the public PAX usage text' );

my $unknown_output = '';
my $unknown_error = '';
{
    local *STDOUT;
    local *STDERR;
    open STDOUT, '>', \$unknown_output or die "Unable to capture stdout: $!";
    open STDERR, '>', \$unknown_error or die "Unable to capture stderr: $!";
    is( Developer::Dashboard::Pax::CLI->run('no-such-command'), 2, 'run returns the command usage error status for an unknown command' );
}
like( $unknown_error, qr/^unknown command: no-such-command\n/, 'unknown command is reported on stderr' );
like( $unknown_error, qr/^usage:\n  pax build /m, 'unknown command includes the usage text on stderr' );

ok( !Developer::Dashboard::Pax::CLI->_looks_like_interpreter_script(undef), '_looks_like_interpreter_script rejects an undefined candidate' );
ok( !Developer::Dashboard::Pax::CLI->_looks_like_interpreter_script(''), '_looks_like_interpreter_script rejects an empty candidate' );
ok( !Developer::Dashboard::Pax::CLI->_looks_like_interpreter_script('--help'), '_looks_like_interpreter_script rejects option tokens' );
ok( !Developer::Dashboard::Pax::CLI->_looks_like_interpreter_script( File::Spec->catfile( $work, 'missing.pl' ) ), '_looks_like_interpreter_script rejects a missing path' );

my $success_script = write_script( $work, 'success.pl', 'print join q{|}, $0, @ARGV; 1;' . "\n" );
my $script_output = '';
{
    local *STDOUT;
    open STDOUT, '>', \$script_output or die "Unable to capture stdout: $!";
    ok( Developer::Dashboard::Pax::CLI->_looks_like_interpreter_script($success_script), '_looks_like_interpreter_script accepts an existing script' );
    is( Developer::Dashboard::Pax::CLI->run( $success_script, 'alpha', 'beta' ), 0, 'run executes an existing script in interpreter mode' );
}
like( $script_output, qr/\Q$success_script|alpha|beta\E/, 'interpreter mode preserves the script path and argument vector' );

my $bad_script = write_script( $work, 'bad.pl', 'this is not valid Perl syntax' . "\n" );
my $failure_output = '';
my $failure_error = '';
{
    local *STDOUT;
    local *STDERR;
    open STDOUT, '>', \$failure_output or die "Unable to capture stdout: $!";
    open STDERR, '>', \$failure_error or die "Unable to capture stderr: $!";
    is( Developer::Dashboard::Pax::CLI->run($bad_script), 255, 'run returns 255 when interpreter mode cannot compile a script' );
}
like( $failure_error, qr/pax interpreter failed for \Q$bad_script\E:/, 'interpreter compilation failure is reported to stderr with the script path' );

my $dispatch_json = '';
{
    no warnings qw(redefine once);
    local *Developer::Dashboard::Pax::RuntimeDispatcher::new = sub { return bless {}, 'Local::PaxRuntimeDispatcher' };
    local *Local::PaxRuntimeDispatcher::dispatch_i64 = sub {
        my ( $self, %args ) = @_;
        return { status => 'native', input => \%args };
    };
    local *STDOUT;
    open STDOUT, '>', \$dispatch_json or die "Unable to capture stdout: $!";
    is(
        Developer::Dashboard::Pax::CLI->_run_dispatch( '--left', '4', '--right', '9', '--region', 'hot', '--compact', 't/fixtures/simple.pl' ),
        0,
        '_run_dispatch parses numeric operands, region, compact output, and entrypoint',
    );
}
like( $dispatch_json, qr/"execution_model":"native"/, '_run_dispatch labels native results correctly' );
like( $dispatch_json, qr/"left":"?4"?/, '_run_dispatch forwards the left operand to the runtime dispatcher' );

my $dispatch_error = '';
{
    local *STDERR;
    open STDERR, '>', \$dispatch_error or die "Unable to capture stderr: $!";
    is( Developer::Dashboard::Pax::CLI->_run_dispatch('--left'), 2, '_run_dispatch reports a missing option value' );
}
like( $dispatch_error, qr/--left requires a value/, '_missing prints the required-option diagnostic' );
$dispatch_error = '';
{
    local *STDERR;
    open STDERR, '>', \$dispatch_error or die "Unable to capture stderr: $!";
    is( Developer::Dashboard::Pax::CLI->_run_dispatch(), 2, '_run_dispatch requires an entrypoint' );
}
like( $dispatch_error, qr/run requires a Perl entrypoint/, '_run_dispatch explains its entrypoint requirement' );
$dispatch_error = '';
{
    local *STDERR;
    open STDERR, '>', \$dispatch_error or die "Unable to capture stderr: $!";
    is( Developer::Dashboard::Pax::CLI->_run_dispatch( 'one.pl', 'extra.pl' ), 2, '_run_dispatch rejects extra positional arguments' );
}
like( $dispatch_error, qr/unexpected argument: extra\.pl/, '_run_dispatch identifies an unexpected argument' );

subtest 'legacy pipeline command helpers retain their argument and output contracts' => sub {
    my $capture_status = 'ok';
    my $manifest = {
        schema_version      => 1,
        source_entrypoint   => 'fixture.pl',
        capture             => { status => 'ok' },
        runtime             => { perl_version => '5.40.1', perl_family_target => '5.40', baseline_match => 1 },
        compatibility       => { level => 'supported', reason => 'fixture policy' },
        module_graph         => { modules => [ 'Fixture::Module' ] },
        compile_phase_events => [ { phase => 'BEGIN' } ],
    };
    no warnings qw(redefine once);
    local *Developer::Dashboard::Pax::Capture::new = sub { return bless {}, 'Developer::Dashboard::Pax::Capture' };
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => $capture_status } };
    local *Developer::Dashboard::Pax::Manifest::new = sub { return bless {}, 'Developer::Dashboard::Pax::Manifest' };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub { return $manifest };
    local *Developer::Dashboard::Pax::RegionSelector::new = sub { return bless {}, 'Developer::Dashboard::Pax::RegionSelector' };
    local *Developer::Dashboard::Pax::RegionSelector::select = sub { return { selected => [ { name => 'hot-region' } ] } };
    local *Developer::Dashboard::Pax::HIR::new = sub { return bless {}, 'Developer::Dashboard::Pax::HIR' };
    local *Developer::Dashboard::Pax::HIR::lower_all = sub { return [ { name => 'lowered-unit' } ] };
    local *Developer::Dashboard::Pax::GuardedSSA::new = sub { return bless {}, 'Developer::Dashboard::Pax::GuardedSSA' };
    local *Developer::Dashboard::Pax::GuardedSSA::build_all = sub { return [ { name => 'ssa-unit' } ] };
    local *Developer::Dashboard::Pax::Tier1::new = sub { return bless {}, 'Developer::Dashboard::Pax::Tier1' };
    local *Developer::Dashboard::Pax::Tier1::compile = sub { return { name => 'artifact' } };

    my $pipeline_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$pipeline_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_capture( '--mode', 'strict', '--compact', 'fixture.pl' ), 0, '_capture accepts mode and compact options for a successful entrypoint' );
    }
    like( $pipeline_output, qr/"source_entrypoint":"fixture.pl"/, '_capture serializes the returned manifest' );

    $pipeline_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$pipeline_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_inspect( '--mode', 'strict', 'fixture.pl' ), 0, '_inspect accepts an explicit capture mode' );
    }
    like( $pipeline_output, qr/^compatibility_level: supported$/m, '_inspect prints compatibility details' );
    like( $pipeline_output, qr/^selected_regions: 1$/m, '_inspect prints the selected region count' );

    $pipeline_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$pipeline_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_hir( '--compact', 'fixture.pl' ), 0, '_hir lowers selected regions and returns the successful capture status' );
    }
    like( $pipeline_output, qr/"manifest_schema_version":1/, '_hir serializes source metadata and HIR units' );

    $pipeline_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$pipeline_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_compile( '--mode', 'strict', '--compact', 'fixture.pl' ), 0, '_compile lowers and compiles each SSA unit' );
    }
    like( $pipeline_output, qr/"name":"artifact"/, '_compile serializes compiled artifacts' );

    my $parse_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$parse_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_capture('--mode'), 2, '_capture reports a missing mode value' );
    }
    like( $parse_error, qr/--mode requires a value/, '_capture identifies its missing mode value' );
    $parse_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$parse_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_capture(), 2, '_capture requires an entrypoint' );
    }
    like( $parse_error, qr/capture requires a Perl entrypoint/, '_capture explains its entrypoint requirement' );
    $parse_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$parse_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_inspect('fixture.pl', 'extra.pl'), 2, '_inspect rejects an extra positional argument' );
    }
    like( $parse_error, qr/unexpected argument: extra\.pl/, '_inspect identifies an unexpected argument' );
    $parse_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$parse_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_hir('--mode'), 2, '_hir reports a missing mode value' );
    }
    like( $parse_error, qr/--mode requires a value/, '_hir identifies its missing mode value' );
    $parse_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$parse_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_compile('fixture.pl', 'extra.pl'), 2, '_compile rejects an extra positional argument' );
    }
    like( $parse_error, qr/unexpected argument: extra\.pl/, '_compile identifies an unexpected argument' );

    $capture_status = 'failed';
    $pipeline_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$pipeline_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_capture('fixture.pl'), 1, '_capture returns failure when the capture status is not ok' );
    }
    $pipeline_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$pipeline_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_hir('fixture.pl'), 1, '_hir returns failure when the capture status is not ok' );
    }
    $pipeline_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$pipeline_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_compile('fixture.pl'), 1, '_compile returns failure when the capture status is not ok' );
    }
};

subtest 'standalone command routing and inspection helpers' => sub {
    my $runner_output_path = File::Spec->catfile( $work, 'standalone-runner-output.txt' );
    my $runner = write_script(
        $work,
        'standalone-runner.pl',
        "#!$^X\nopen my \$fh, '>', \$ENV{PAX_TEST_RUNNER_OUTPUT} or die \$!;\nprint {\$fh} join q{|}, \@ARGV;\nclose \$fh or die \$!;\n1;\n",
    );
    chmod 0755, $runner or die "Unable to make $runner executable: $!";

    no warnings qw(redefine once);
    local *Developer::Dashboard::Pax::CLI::_build_standalone = sub { return 37 };
    is( Developer::Dashboard::Pax::CLI->run( 'build', '--compact', 'fixture.pl' ), 37, 'run routes build arguments to the standalone builder and preserves its result' );

    local *Developer::Dashboard::Pax::CLI::_standalone_build_config = sub { return { fixture => 1 } };
    local *Developer::Dashboard::Pax::CLI::_standalone_build_from_config = sub {
        return { result => { status => 'built', standalone => { output_path => $runner } } };
    };
    local $ENV{PAX_TEST_RUNNER_OUTPUT} = $runner_output_path;
    is( Developer::Dashboard::Pax::CLI->run( 'run', '--', 'alpha', 'beta' ), 0, 'run builds then executes the standalone output with trailing arguments' );
    open my $runner_result, '<', $runner_output_path or die "Unable to read $runner_output_path: $!";
    my $run_output = do { local $/; <$runner_result> };
    close $runner_result or die "Unable to close $runner_output_path: $!";
    like( $run_output, qr/^alpha\|beta/, 'run forwards arguments after -- to the built executable' );

    local *Developer::Dashboard::Pax::CLI::_standalone_build_config = sub { return 2 };
    is( Developer::Dashboard::Pax::CLI->run('run'), 2, 'run returns a standalone configuration error unchanged' );
    local *Developer::Dashboard::Pax::CLI::_standalone_build_config = sub { return {} };
    local *Developer::Dashboard::Pax::CLI::_standalone_build_from_config = sub {
        return { result => { status => 'failed' } };
    };
    is( Developer::Dashboard::Pax::CLI->run('run'), 1, 'run stops with failure when standalone build did not complete' );

    local *Developer::Dashboard::Pax::StandaloneImage::new = sub { return bless {}, 'Developer::Dashboard::Pax::StandaloneImage' };
    my $image = {
        name => 'fixture-image',
        output_path => $runner,
        runtime => { mode => 'core' },
        dependencies => [
            { class => 'missing', module => 'Missing::Module', provider => 'cpan' },
            { class => 'bundled', module => 'Bundled::Module', provider => 'payload' },
        ],
        native_artifacts => [
            { status => 'fallback', entry_kind => 'native_i64_entry', region_name => 'entry', reason => 'not emitted' },
            { status => 'fallback', entry_kind => 'native_i64_leaf', region_name => 'leaf', reason => 'leaf fallback' },
            { status => 'native_artifact', entry_kind => 'native_i64_loop', region_name => 'loop', reason => '' },
        ],
        code_units => [
            { packaging => 'source_payload_fallback', logical_path => 'lib/Fallback.pm', unit_kind => 'module', fallback_reason => 'unsupported form', fallback_detail => 'fixture detail' },
            { packaging => 'compiled', logical_path => 'lib/Compiled.pm', unit_kind => 'module' },
        ],
    };
    local *Developer::Dashboard::Pax::StandaloneImage::load = sub { return $image };

    my $inspect_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$inspect_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_inspect( '--name', 'fixture-image', '--compact' ), 0, '_standalone_inspect loads and serializes a named image' );
    }
    like( $inspect_output, qr/"name":"fixture-image"/, '_standalone_inspect includes image metadata' );

    my $report_output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$report_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_why_not( '--name', 'fixture-image', '--compact' ), 0, '_standalone_why_not analyzes missing modules and fallback artifacts' );
    }
    like( $report_output, qr/"standalone_ready":false/, '_standalone_why_not marks an image with missing dependencies as not ready' );
    like( $report_output, qr/"module":"Missing::Module"/, '_standalone_why_not reports the missing module provider' );
    like( $report_output, qr/"region_name":"entry"/, '_standalone_why_not includes non-native regions but excludes native leaves' );
    like( $report_output, qr/"logical_path":"lib\/Fallback.pm"/, '_standalone_why_not includes source payload fallback units' );

    is( Developer::Dashboard::Pax::CLI->_standalone_extract( '--name', 'fixture-image', '--output', 'payload.tar' ), 0, '_standalone_extract invokes the executable with its extraction protocol' );
    open $runner_result, '<', $runner_output_path or die "Unable to read $runner_output_path: $!";
    my $extract_output = do { local $/; <$runner_result> };
    close $runner_result or die "Unable to close $runner_output_path: $!";
    like( $extract_output, qr/^--pax-standalone-extract\|payload\.tar/, '_standalone_extract passes its requested archive path' );

    is( Developer::Dashboard::Pax::CLI->_standalone_run( '--name', 'fixture-image', '--', 'child-arg' ), 0, '_standalone_run executes a named image with post-separator arguments' );
    open $runner_result, '<', $runner_output_path or die "Unable to read $runner_output_path: $!";
    my $standalone_run_output = do { local $/; <$runner_result> };
    close $runner_result or die "Unable to close $runner_output_path: $!";
    like( $standalone_run_output, qr/^child-arg/, '_standalone_run forwards command arguments' );

    my $command_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$command_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_run(), 2, '_standalone_run requires an image name' );
    }
    like( $command_error, qr/standalone-run requires --name/, '_standalone_run explains its required name' );
    $command_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$command_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_inspect('--name'), 2, '_standalone_inspect reports a missing image name value' );
    }
    like( $command_error, qr/--name requires a value/, '_standalone_inspect uses the shared missing-value diagnostic' );
    $command_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$command_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_inspect(), 2, '_standalone_inspect requires an image name' );
    }
    like( $command_error, qr/standalone-inspect requires --name/, '_standalone_inspect explains its required name' );
    $command_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$command_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_extract( '--name', 'fixture-image' ), 2, '_standalone_extract requires an output path' );
    }
    like( $command_error, qr/standalone-extract requires --output/, '_standalone_extract explains its required output path' );
    $command_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$command_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_why_not(), 2, '_standalone_why_not requires an image name' );
    }
    like( $command_error, qr/standalone-why-not requires --name/, '_standalone_why_not explains its required name' );

    my $clean_report = '';
    local *Developer::Dashboard::Pax::StandaloneImage::load = sub {
        return { name => 'clean-image', runtime => {}, dependencies => [], native_artifacts => [], code_units => [] };
    };
    {
        local *STDOUT;
        open STDOUT, '>', \$clean_report or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_why_not( '--name', 'clean-image', '--compact' ), 0, '_standalone_why_not accepts an image with omitted analysis fields' );
    }
    like( $clean_report, qr/"standalone_ready":true/, '_standalone_why_not marks an image with no missing modules as ready' );
    like( $clean_report, qr/"source_fallback_units":\[\]/, '_standalone_why_not defaults absent fallback collections to empty arrays' );

    my $native_output = '';
    {
        local *Developer::Dashboard::Pax::StandaloneDispatch::new = sub { return bless {}, 'Local::PaxStandaloneDispatch' };
        local *Local::PaxStandaloneDispatch::run_i64 = sub { return { status => 'native', result => { status => 'ok' } } };
        local *STDOUT;
        open STDOUT, '>', \$native_output or die "Unable to capture stdout: $!";
        is(
            Developer::Dashboard::Pax::CLI->_standalone_native_run( '--name', 'fixture-image', '--region', 'sum', '--left', '2', '--right', '3', '--invalidate', 'guard-a', '--invalidate', 'guard-b', '--compact' ),
            0,
            '_standalone_native_run forwards operands and repeated invalidation requests',
        );
    }
    like( $native_output, qr/"status":"native"/, '_standalone_native_run serializes a successful result' );

    my $native_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$native_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_native_run( '--name', 'fixture-image' ), 2, '_standalone_native_run requires a region name' );
    }
    like( $native_error, qr/standalone-native-run requires --region/, '_standalone_native_run explains its required region' );
    $native_error = '';
    {
        local *STDERR;
        open STDERR, '>', \$native_error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_native_run( '--name', 'fixture-image', '--region' ), 2, '_standalone_native_run reports a missing region value' );
    }
    like( $native_error, qr/--region requires a value/, '_standalone_native_run uses the shared missing-value diagnostic' );

    my $failed_native_output = '';
    {
        local *Developer::Dashboard::Pax::StandaloneDispatch::new = sub { return bless {}, 'Local::PaxStandaloneDispatch' };
        local *Local::PaxStandaloneDispatch::run_i64 = sub { return { status => 'fallback', result => { status => 'error' } } };
        local *STDOUT;
        open STDOUT, '>', \$failed_native_output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_native_run( '--name', 'fixture-image', '--region', 'missing', '--compact' ), 1, '_standalone_native_run returns failure for a non-native error result' );
    }
    like( $failed_native_output, qr/"status":"fallback"/, '_standalone_native_run still serializes fallback diagnostics' );
};

subtest 'analysis command wrappers forward parsed options and report statuses' => sub {
    no warnings qw(redefine once);
    my %received;
    local *Developer::Dashboard::Pax::Differential::new = sub { my ( $class, %args ) = @_; $received{diff_new} = \%args; return bless {}, 'Local::PaxDifferential' };
    local *Local::PaxDifferential::compare_capture = sub { $received{diff_entrypoint} = $_[1]; return { pass => 1 } };
    local *Developer::Dashboard::Pax::Benchmark::new = sub { my ( $class, %args ) = @_; $received{bench_new} = \%args; return bless {}, 'Local::PaxBenchmark' };
    local *Local::PaxBenchmark::run_runtime_benchmark = sub { $received{bench_entrypoint} = $_[1]; return { status => 'measured' } };
    local *Developer::Dashboard::Pax::BenchmarkMatrix::new = sub { my ( $class, %args ) = @_; $received{matrix_new} = \%args; return bless {}, 'Local::PaxBenchmarkMatrix' };
    local *Local::PaxBenchmarkMatrix::run = sub { return { passed => 1, records => [] } };
    local *Developer::Dashboard::Pax::Corpus::new = sub { my ( $class, %args ) = @_; $received{corpus_new} = \%args; return bless {}, 'Local::PaxCorpus' };
    local *Local::PaxCorpus::run = sub { return { passed => 1 } };
    local *Developer::Dashboard::Pax::CoreSuite::new = sub { my ( $class, %args ) = @_; $received{core_new} = \%args; return bless {}, 'Local::PaxCoreSuite' };
    local *Local::PaxCoreSuite::run = sub { return { passed => 0, failures => ['fixture'] } };
    local *Developer::Dashboard::Pax::CPANMatrix::new = sub { my ( $class, %args ) = @_; $received{cpan_new} = \%args; return bless {}, 'Local::PaxCPANMatrix' };
    local *Local::PaxCPANMatrix::run = sub { return { passed => 1 } };
    local *Developer::Dashboard::Pax::Gatekeeper::new = sub { my ( $class, %args ) = @_; $received{gatekeeper_new} = \%args; return bless {}, 'Local::PaxGatekeeper' };
    local *Local::PaxGatekeeper::sow01_report = sub { return { status => 'passed' } };
    local *Developer::Dashboard::Pax::RuntimeDispatcher::new = sub { return bless {}, 'Local::PaxRuntimeDispatcher' };
    local *Local::PaxRuntimeDispatcher::dispatch_i64 = sub { my ( $self, %args ) = @_; $received{dispatch_args} = \%args; return { status => 'native' } };
    local *Developer::Dashboard::Pax::CLI::_pax_bin = sub { return '/tmp/pax-test-bin' };

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_diff( '--compact', 'diff.pl' ), 0, '_diff returns success when the differential report passes' );
    }
    is( $received{diff_new}{pax_bin}, '/tmp/pax-test-bin', '_diff resolves and forwards the PAX executable path' );
    is( $received{diff_entrypoint}, 'diff.pl', '_diff forwards its entrypoint' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_bench( '--iterations', '5', '--compact', 'bench.pl' ), 0, '_bench forwards iteration count and entrypoint' );
    }
    is( $received{bench_new}{iterations}, 5, '_bench passes the requested iteration count' );
    is( $received{bench_entrypoint}, 'bench.pl', '_bench passes the requested entrypoint' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_bench_matrix( '--iterations', '3', 'matrix.yml' ), 0, '_bench_matrix returns success for a passing matrix' );
    }
    is( $received{matrix_new}{manifest_path}, 'matrix.yml', '_bench_matrix forwards its manifest' );
    is( $received{matrix_new}{iterations}, 3, '_bench_matrix forwards its iteration count' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_corpus('corpus.yml'), 0, '_corpus returns success for a passing corpus report' );
    }
    is( $received{corpus_new}{manifest_path}, 'corpus.yml', '_corpus forwards the manifest path' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_core_suite('--compact', 'core.yml'), 1, '_core_suite returns failure when the core suite report fails' );
    }
    is( $received{core_new}{manifest_path}, 'core.yml', '_core_suite forwards the manifest path' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_cpan_matrix('cpan.yml'), 0, '_cpan_matrix returns success for a passing matrix' );
    }
    is( $received{cpan_new}{manifest_path}, 'cpan.yml', '_cpan_matrix forwards the manifest path' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_gatekeeper('--compact'), 0, '_gatekeeper returns success for a passing report' );
    }
    is( $received{gatekeeper_new}{root}, '.', '_gatekeeper scopes its report to the current repository' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_dispatch( '--left', '8', '--right', '13', '--region', 'hot', '--compact', 'dispatch.pl' ), 0, '_dispatch returns success for a native runtime result' );
    }
    is( $received{dispatch_args}{left}, 8, '_dispatch forwards the left operand' );
    is( $received{dispatch_args}{right}, 13, '_dispatch forwards the right operand' );
    is( $received{dispatch_args}{region_name}, 'hot', '_dispatch forwards the region name' );
};

subtest 'standalone build planning and materialization lifecycle' => sub {
    no warnings qw(redefine once);
    my $progress_calls = 0;
    my $progress_args;
    my $progress_finished = 0;
    local *Developer::Dashboard::Pax::StandaloneImage::build_progress_tasks = sub { return [ { id => 'compile' } ] };
    local *Developer::Dashboard::Pax::CLI::Progress::new = sub {
        my ( $class, %args ) = @_;
        $progress_calls++;
        $progress_args = \%args;
        return bless {}, 'Local::PaxProgress';
    };
    local *Local::PaxProgress::callback = sub { return 'progress-callback' };
    local *Local::PaxProgress::finish = sub { $progress_finished++; return 1 };

    {
        local $ENV{PAX_PROGRESS} = '0';
        is( Developer::Dashboard::Pax::CLI->_standalone_build_progress(), undef, '_standalone_build_progress respects explicit progress disablement' );
    }
    {
        local $ENV{PAX_PROGRESS} = '1';
        my $progress = Developer::Dashboard::Pax::CLI->_standalone_build_progress();
        isa_ok( $progress, 'Local::PaxProgress', '_standalone_build_progress constructs the progress renderer when enabled' );
        is( $progress_args->{title}, 'pax build progress', '_standalone_build_progress supplies the build title' );
        is_deeply( $progress_args->{tasks}, [ { id => 'compile' } ], '_standalone_build_progress obtains the task list from StandaloneImage' );
        ok( !$progress_args->{dynamic}, '_standalone_build_progress disables dynamic redraw when stderr is not a terminal' );
    }
    is( $progress_calls, 1, '_standalone_build_progress constructs exactly one renderer when enabled' );

    my @plain_entry = Developer::Dashboard::Pax::CLI->_standalone_materialize_entrypoint({ entrypoint => 'main.pl' });
    is_deeply( \@plain_entry, [ 'main.pl', undef ], '_standalone_materialize_entrypoint leaves file entrypoints unchanged' );
    my $inline_source = Developer::Dashboard::Pax::CLI->_standalone_inline_entrypoint_source({
        perl_libs   => [ q{O'Reilly}, q{C:\tmp} ],
        perl_modules => [ 'JSON::XS=encode,decode', 'strict', 'Empty=' ],
        inline_eval => 'print "ready";',
    });
    like( $inline_source, qr/^#!\/usr\/bin\/env perl\nuse strict;\nuse warnings;/, '_standalone_inline_entrypoint_source emits a portable strict Perl header' );
    like( $inline_source, qr/use lib 'O\\'Reilly';/, '_perl_single_quote escapes embedded single quotes in library paths' );
    like( $inline_source, qr/use lib 'C:\\\\tmp';/, '_perl_single_quote escapes backslashes in library paths' );
    like( $inline_source, qr/BEGIN \{ require JSON::XS; JSON::XS->import\('encode', 'decode'\); \}/, '_parse_perl_module_switch emits module imports from a populated -M specification' );
    like( $inline_source, qr/BEGIN \{ require strict; strict->import\(\); \}/, '_parse_perl_module_switch emits a bare module import when no import list exists' );
    like( $inline_source, qr/BEGIN \{ require Empty; Empty->import\(\); \}/, '_parse_perl_module_switch treats an empty import suffix as no imports' );
    like( $inline_source, qr/print "ready";/, '_standalone_inline_entrypoint_source appends the requested inline code' );
    is( Developer::Dashboard::Pax::CLI::_perl_single_quote(undef), q{''}, '_perl_single_quote renders undefined input as an empty Perl string' );

    my ( $inline_path, $cleanup_path ) = Developer::Dashboard::Pax::CLI->_standalone_materialize_entrypoint({
        perl_libs => [], perl_modules => [], inline_eval => 'print 9;',
    });
    ok( -f $inline_path, '_standalone_materialize_entrypoint writes inline source to a temporary Perl file' );
    is( $cleanup_path, $inline_path, '_standalone_materialize_entrypoint returns the temporary file as its cleanup target' );
    unlink $inline_path or die "Unable to remove $inline_path: $!";

    my $cleanup = write_script( $work, 'standalone-build-cleanup.pl', '1;' . "\n" );
    my $build_args;
    local *Developer::Dashboard::Pax::CLI::_standalone_build_progress = sub { return bless {}, 'Local::PaxProgress' };
    local *Developer::Dashboard::Pax::CLI::_standalone_materialize_entrypoint = sub { return ( 'materialized.pl', $cleanup ) };
    local *Developer::Dashboard::Pax::StandaloneImage::new = sub { return bless {}, 'Local::PaxStandaloneBuilder' };
    local *Local::PaxStandaloneBuilder::build = sub { my ( $self, %args ) = @_; $build_args = \%args; return { status => 'built' } };
    my $build = Developer::Dashboard::Pax::CLI->_standalone_build_from_config({
        entrypoint => 'source.pl', perl_libs => ['perl-lib'], libs => ['app-lib'],
        source_roots => ['src'], assets => ['asset'], asset_dirs => ['public'],
        cpanfiles => ['cpanfile'], output => 'out/bin', runtime_mode => 'core',
        app_name => 'demo', app_namespace => 'Demo', app_entrypoint_env => 'APP_ENTRY',
        app_entrypoint_fallback => 'main.pl', app_command => 'start',
        paxfile_applied => 1, override_fields => ['name'], pretty => 0,
    });
    is( $build->{result}{status}, 'built', '_standalone_build_from_config returns the build result' );
    is( $build->{pretty}, 0, '_standalone_build_from_config preserves the output formatting preference' );
    is_deeply( $build_args->{lib_dirs}, [ 'perl-lib', 'app-lib' ], '_standalone_build_from_config combines Perl and application libraries in order' );
    is( $build_args->{progress}, 'progress-callback', '_standalone_build_from_config forwards a progress callback' );
    ok( !-e $cleanup, '_standalone_build_from_config removes its temporary entrypoint after success' );
    ok( $progress_finished, '_standalone_build_from_config finishes the progress board' );

    $cleanup = write_script( $work, 'standalone-build-error-cleanup.pl', '1;' . "\n" );
    local *Local::PaxStandaloneBuilder::build = sub { die "fixture build failure\n" };
    my $build_error = eval {
        Developer::Dashboard::Pax::CLI->_standalone_build_from_config({ entrypoint => 'source.pl', perl_libs => [], libs => [] });
        '';
    };
    $build_error = $@ if $@;
    like( $build_error, qr/fixture build failure/, '_standalone_build_from_config rethrows build failures' );
    ok( !-e $cleanup, '_standalone_build_from_config removes its temporary entrypoint after failure' );

    my $build_stdout = '';
    {
        local *Developer::Dashboard::Pax::CLI::_standalone_build_config = sub { return { fixture => 1 } };
        local *Developer::Dashboard::Pax::CLI::_standalone_build_from_config = sub { return { result => { status => 'built' }, pretty => 0 } };
        local *STDOUT;
        open STDOUT, '>', \$build_stdout or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_build_standalone('fixture.pl'), 0, '_build_standalone returns success when the image is built' );
    }
    like( $build_stdout, qr/"status":"built"/, '_build_standalone serializes the image result' );
    {
        local *Developer::Dashboard::Pax::CLI::_standalone_build_config = sub { return 'configuration error' };
        is( Developer::Dashboard::Pax::CLI->_build_standalone(), 'configuration error', '_build_standalone returns configuration errors without building' );
    }
    {
        local *Developer::Dashboard::Pax::CLI::_standalone_build_config = sub { return {} };
        local *Developer::Dashboard::Pax::CLI::_standalone_build_from_config = sub { return { result => { status => 'failed' }, pretty => 1 } };
        local *STDOUT;
        open STDOUT, '>', \$build_stdout or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_standalone_build(), 1, '_standalone_build returns failure when the build does not succeed' );
    }
};

subtest 'application image command wrappers forward lifecycle arguments' => sub {
    no warnings qw(redefine once);
    my %received;
    local *Developer::Dashboard::Pax::Paxfile::load_optional = sub { return { name => 'from-paxfile', entrypoint => 'main.pl', libs => ['lib'], assets => ['site.css'], asset_dirs => ['public'] } };
    local *Developer::Dashboard::Pax::AppImage::new = sub { return bless {}, 'Local::PaxAppImage' };
    local *Local::PaxAppImage::build = sub { my ( $self, %args ) = @_; $received{image_build} = \%args; return { status => 'built', name => $args{name} } };
    local *Local::PaxAppImage::load = sub { my ( $self, %args ) = @_; $received{image_load} = \%args; return { name => $args{name}, socket_path => '/tmp/app.sock' } };
    local *Developer::Dashboard::Pax::AppServer::new = sub { my ( $class, %args ) = @_; $received{server_new} = \%args; return bless {}, 'Local::PaxAppServer' };
    local *Local::PaxAppServer::start = sub { my ( $self, %args ) = @_; $received{server_start} = \%args; return 17 };
    local *Developer::Dashboard::Pax::AppServer::run_client = sub { my ( $class, %args ) = @_; $received{client_run} = \%args; return 18 };
    local *Developer::Dashboard::Pax::AppServer::stop = sub { my ( $class, %args ) = @_; $received{server_stop} = \%args; return 19 };

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_app_build( '--no-paxfile', '--name', 'image', '--lib', 'custom-lib', '--asset', 'logo.svg', '--asset-dir', 'static', '--compact', 'entry.pl' ), 0, '_app_build builds an image using CLI overrides' );
    }
    is( $received{image_build}{name}, 'image', '_app_build forwards the requested image name' );
    is( $received{image_build}{entrypoint}, 'entry.pl', '_app_build forwards the requested entrypoint' );
    is_deeply( $received{image_build}{lib_dirs}, ['custom-lib'], '_app_build uses CLI library overrides' );
    is_deeply( $received{image_build}{assets}, ['logo.svg'], '_app_build forwards asset overrides' );
    is_deeply( $received{image_build}{asset_dirs}, ['static'], '_app_build forwards asset directory overrides' );

    my $error = '';
    {
        local *STDERR;
        open STDERR, '>', \$error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_app_build('--no-paxfile'), 2, '_app_build requires an entrypoint when paxfile loading is disabled' );
    }
    like( $error, qr/app-build requires a Perl entrypoint/, '_app_build explains its required entrypoint' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_app_start( '--name', 'image', '--daemonize', '--compact' ), 0, '_app_start reports a daemonized app start as JSON' );
    }
    is( $received{image_load}{name}, 'image', '_app_start loads the requested image' );
    is( $received{server_new}{image}{socket_path}, '/tmp/app.sock', '_app_start passes the image to the app server' );
    is( $received{server_start}{daemonize}, 1, '_app_start forwards the daemonize flag' );
    like( $output, qr/"status":"started"/, '_app_start emits the started status in daemon mode' );
    is( Developer::Dashboard::Pax::CLI->_app_start( '--name', 'image' ), 17, '_app_start returns the foreground server status' );

    $error = '';
    {
        local *STDERR;
        open STDERR, '>', \$error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_app_start(), 2, '_app_start requires an image name' );
    }
    like( $error, qr/app-start requires --name/, '_app_start explains its required name' );

    is( Developer::Dashboard::Pax::CLI->_app_run( '--name', 'image', '--', 'one', 'two' ), 18, '_app_run passes command arguments to the running app' );
    is( $received{client_run}{image}{name}, 'image', '_app_run loads the named app image' );
    is_deeply( $received{client_run}{argv}, [ 'one', 'two' ], '_app_run strips the separator and forwards remaining arguments' );
    $error = '';
    {
        local *STDERR;
        open STDERR, '>', \$error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_app_run('one'), 2, '_app_run rejects arguments without a leading --name' );
    }
    like( $error, qr/app-run requires --name/, '_app_run explains its required name' );

    is( Developer::Dashboard::Pax::CLI->_app_stop( '--name', 'image' ), 19, '_app_stop returns the server shutdown status' );
    is( $received{server_stop}{image}{name}, 'image', '_app_stop passes the loaded image to the server' );
    $error = '';
    {
        local *STDERR;
        open STDERR, '>', \$error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_app_stop('--unexpected'), 2, '_app_stop rejects unexpected arguments' );
    }
    like( $error, qr/unexpected argument: --unexpected/, '_app_stop identifies its unexpected argument' );
};

subtest 'profile, why-not, trace, and pipeline analysis commands' => sub {
    no warnings qw(redefine once);
    my %received;
    my $capture_status = 'ok';
    my $manifest = {
        source_entrypoint => 'analysis.pl',
        runtime => { baseline_match => 1, runtime_epochs => [1] },
        compatibility => { barriers => [] },
        runtime_epochs => [1],
    };
    my $selected_regions = [ { name => 'hot', region_id => 'r1' }, { name => 'cold', region_id => 'r2' } ];
    my $units = [
        { region_name => 'hot', region_id => 'r1', status => 'native', guards => [], deopt => {} },
        { region_name => 'cold', region_id => 'r2', status => 'fallback', guards => [], deopt => {} },
    ];
    local *Developer::Dashboard::Pax::Capture::new = sub { return bless {}, 'Developer::Dashboard::Pax::Capture' };
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => $capture_status } };
    local *Developer::Dashboard::Pax::Manifest::new = sub { return bless {}, 'Developer::Dashboard::Pax::Manifest' };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub { return $manifest };
    local *Developer::Dashboard::Pax::RegionSelector::new = sub { return bless {}, 'Developer::Dashboard::Pax::RegionSelector' };
    local *Developer::Dashboard::Pax::RegionSelector::select = sub { return { selected => $selected_regions, rejected => [] } };
    local *Developer::Dashboard::Pax::HIR::new = sub { return bless {}, 'Developer::Dashboard::Pax::HIR' };
    local *Developer::Dashboard::Pax::HIR::lower_all = sub { return [ { name => 'hir-unit' } ] };
    local *Developer::Dashboard::Pax::GuardedSSA::new = sub { return bless {}, 'Developer::Dashboard::Pax::GuardedSSA' };
    local *Developer::Dashboard::Pax::GuardedSSA::build_all = sub { return $units };
    local *Developer::Dashboard::Pax::Tier1::new = sub { return bless {}, 'Local::PaxTier1' };
    local *Local::PaxTier1::compile = sub {
        my ( $self, $unit ) = @_;
        return $unit->{region_name} eq 'hot'
            ? { entry_kind => 'native_i64_leaf', status => 'native', reason => '' }
            : { entry_kind => 'source', status => 'fallback', reason => 'unsupported unit' };
    };
    local *Developer::Dashboard::Pax::ProfileStore::new = sub { my ( $class, %args ) = @_; $received{profile_args} = \%args; return bless {}, 'Local::PaxProfileStore' };
    local *Local::PaxProfileStore::report = sub { return { threshold => 7 } };
    local *Developer::Dashboard::Pax::InlineCache::new = sub { return bless {}, 'Local::PaxInlineCache' };
    local *Developer::Dashboard::Pax::RuntimeDispatcher::new = sub { my ( $class, %args ) = @_; $received{runtime_args} = \%args; return bless {}, 'Local::PaxRuntimeDispatcher' };
    local *Local::PaxRuntimeDispatcher::dispatch_i64 = sub { return { status => 'native', invocation => ++$received{dispatch_count} } };
    local *Local::PaxRuntimeDispatcher::inline_cache_report = sub { return { hits => 2 } };
    local *Developer::Dashboard::Pax::GuardManager::new = sub { my ( $class, %args ) = @_; $received{guard_epochs} = $args{epochs}; return bless {}, 'Local::PaxGuardManager' };
    local *Local::PaxGuardManager::validate_or_deopt = sub { my ( $self, $unit ) = @_; return { status => $unit->{status} eq 'fallback' ? 'deopt' : 'native' } };
    local *Local::PaxGuardManager::telemetry = sub { return { deopts => 1 } };

    my ( $capture, $pipe_manifest, $regions, $hir, $ssa ) = Developer::Dashboard::Pax::CLI::_pipeline('analysis.pl');
    is( $capture->{status}, 'ok', '_pipeline captures the requested entrypoint' );
    is( $pipe_manifest, $manifest, '_pipeline converts the capture to its manifest' );
    is_deeply( $regions->{selected}, $selected_regions, '_pipeline selects regions from the manifest' );
    is_deeply( $hir, [ { name => 'hir-unit' } ], '_pipeline lowers the selected regions' );
    is( $ssa, $units, '_pipeline builds guarded SSA units' );

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_why_not( '--region', 'hot', '--compact', 'analysis.pl' ), 0, '_why_not analyzes a requested region' );
    }
    like( $output, qr/"requested_region":"hot"/, '_why_not records the requested region' );
    like( $output, qr/"summary":"region is native-capable in the current SOW-01 implementation"/, '_why_not summarizes a native-capable region' );

    my $summary = Developer::Dashboard::Pax::CLI::_why_not_summary( { runtime => { baseline_match => 0 }, compatibility => { barriers => [] } }, [], [] );
    is( $summary, 'runtime baseline mismatch blocks native acceleration', '_why_not_summary prioritizes a runtime baseline mismatch' );
    $summary = Developer::Dashboard::Pax::CLI::_why_not_summary( { runtime => { baseline_match => 1 }, compatibility => { barriers => ['barrier'] } }, [], [] );
    is( $summary, 'compatibility barriers require guarded or fallback execution', '_why_not_summary reports compatibility barriers' );
    $summary = Developer::Dashboard::Pax::CLI::_why_not_summary( { runtime => { baseline_match => 1 }, compatibility => { barriers => [] } }, [], [] );
    is( $summary, 'requested region was not selected', '_why_not_summary reports an empty selected-region list' );
    $summary = Developer::Dashboard::Pax::CLI::_why_not_summary( { runtime => { baseline_match => 1 }, compatibility => { barriers => [] } }, ['hot'], [ { entry_kind => 'source', reason => 'not native' } ] );
    is( $summary, 'not native', '_why_not_summary returns the first fallback artifact reason' );
    $summary = Developer::Dashboard::Pax::CLI::_why_not_summary( { runtime => { baseline_match => 1 }, compatibility => { barriers => [] } }, ['hot'], [ { entry_kind => 'native_i64_leaf' }, { entry_kind => 'native_i64_loop' } ] );
    is( $summary, 'region is native-capable in the current SOW-01 implementation', '_why_not_summary recognizes native leaf and loop artifacts' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_trace_guards( '--region', 'cold', '--compact', 'analysis.pl' ), 0, '_trace_guards records a selected fallback unit' );
    }
    like( $output, qr/"status":"deopt"/, '_trace_guards reports deopt for an SSA fallback unit' );
    is_deeply( $received{guard_epochs}, [1], '_trace_guards initializes guards from manifest runtime epochs' );

    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_profile( '--iterations', '2', '--threshold', '7', '--compact', 'analysis.pl' ), 0, '_profile dispatches the requested number of profiling iterations' );
    }
    is( $received{profile_args}{threshold}, 7, '_profile configures the profile-store threshold' );
    is( $received{runtime_args}{threshold}, 7, '_profile forwards the threshold to the runtime dispatcher' );
    is( $received{dispatch_count}, 2, '_profile collects one event for each requested iteration' );
    like( $output, qr/"hits":2/, '_profile includes inline-cache data in its report' );
};

subtest 'artifact build, native execution, and executable path resolution' => sub {
    no warnings qw(redefine once);
    my %received;
    my $capture_status = 'ok';
    my $artifact = { entry_kind => 'native_i64_leaf', executable_path => '/tmp/native-fixture', region_id => 'region-1' };
    my $native_result = { status => 'ok', result => 42 };
    local *Developer::Dashboard::Pax::Capture::new = sub { my ( $class, %args ) = @_; $received{capture_mode} = $args{mode}; return bless {}, 'Developer::Dashboard::Pax::Capture' };
    local *Developer::Dashboard::Pax::Capture::capture = sub { return { status => $capture_status } };
    local *Developer::Dashboard::Pax::Manifest::new = sub { return bless {}, 'Developer::Dashboard::Pax::Manifest' };
    local *Developer::Dashboard::Pax::Manifest::to_hash = sub { return { source_entrypoint => 'native.pl' } };
    local *Developer::Dashboard::Pax::RegionSelector::new = sub { return bless {}, 'Developer::Dashboard::Pax::RegionSelector' };
    local *Developer::Dashboard::Pax::RegionSelector::select = sub { return { selected => [ { name => 'native-region' } ] } };
    local *Developer::Dashboard::Pax::HIR::new = sub { return bless {}, 'Developer::Dashboard::Pax::HIR' };
    local *Developer::Dashboard::Pax::HIR::lower_all = sub { return [ { name => 'hir-unit' } ] };
    local *Developer::Dashboard::Pax::GuardedSSA::new = sub { return bless {}, 'Developer::Dashboard::Pax::GuardedSSA' };
    local *Developer::Dashboard::Pax::GuardedSSA::build_all = sub { return [ { name => 'ssa-unit' } ] };
    local *Developer::Dashboard::Pax::Tier1::new = sub { return bless {}, 'Local::PaxTier1' };
    local *Local::PaxTier1::compile = sub { return $artifact };
    local *Developer::Dashboard::Pax::ArtifactCache::new = sub { my ( $class, %args ) = @_; $received{cache_root} = $args{root}; return bless {}, 'Local::PaxArtifactCache' };
    local *Local::PaxArtifactCache::write_artifact = sub { my ( $self, %args ) = @_; $received{written_artifact} = \%args; return { path => '/tmp/cache/artifact.json' } };
    local *Developer::Dashboard::Pax::Mode::policy = sub { return { mode => $_[1] } };
    local *Developer::Dashboard::Pax::NativeRunner::new = sub { return bless {}, 'Local::PaxNativeRunner' };
    local *Local::PaxNativeRunner::run_i64_binary = sub { my ( $self, %args ) = @_; $received{native_args} = \%args; return $native_result };

    my $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_build_artifacts( '--mode', 'strict', '--operation-mode', 'prod', '--cache-root', 'cache', '--compact', 'artifact.pl' ), 0, '_build_artifacts runs the capture-to-cache pipeline successfully' );
    }
    is( $received{capture_mode}, 'strict', '_build_artifacts forwards the capture mode' );
    is( $received{cache_root}, 'cache', '_build_artifacts forwards the cache root' );
    is( $received{written_artifact}{manifest}{source_entrypoint}, 'native.pl', '_build_artifacts writes each compiled artifact with its manifest' );
    like( $output, qr/"operation_mode":"prod"/, '_build_artifacts reports the requested operation mode' );
    like( $output, qr/"operation_policy":\{"mode":"prod"\}/, '_build_artifacts includes the operation policy' );

    my $error = '';
    for my $case (
        [ '--mode', '--mode requires a value' ],
        [ '--operation-mode', '--operation-mode requires a value' ],
        [ '--cache-root', '--cache-root requires a value' ],
    ) {
        $error = '';
        {
            local *STDERR;
            open STDERR, '>', \$error or die "Unable to capture stderr: $!";
            is( Developer::Dashboard::Pax::CLI->_build_artifacts( $case->[0] ), 2, "_build_artifacts rejects missing $case->[0]" );
        }
        like( $error, qr/\Q$case->[1]\E/, "_build_artifacts diagnoses missing $case->[0]" );
    }
    $error = '';
    {
        local *STDERR;
        open STDERR, '>', \$error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_build_artifacts('--compact'), 2, '_build_artifacts requires an entrypoint' );
    }
    like( $error, qr/build requires a Perl entrypoint/, '_build_artifacts explains its entrypoint requirement' );
    $capture_status = 'failed';
    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_build_artifacts('failed.pl'), 1, '_build_artifacts returns failure when capture fails' );
    }

    $artifact = { entry_kind => 'source', status => 'fallback', reason => 'no native unit' };
    $capture_status = 'ok';
    $error = '';
    {
        local *STDERR;
        open STDERR, '>', \$error or die "Unable to capture stderr: $!";
        is( Developer::Dashboard::Pax::CLI->_run_native(), 2, '_run_native requires a Perl entrypoint' );
    }
    like( $error, qr/run-native requires a Perl entrypoint/, '_run_native explains its entrypoint requirement' );
    $artifact = { entry_kind => 'source', status => 'fallback', reason => 'no native unit' };
    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_run_native( '--left', '8', '--right', '11', '--region', 'native-region', '--compact', 'native.pl' ), 1, '_run_native returns fallback when no executable native artifact exists' );
    }
    like( $output, qr/"reason":"no callable native i64 artifact emitted"/, '_run_native explains why it fell back' );

    $artifact = { entry_kind => 'native_i64_leaf', executable_path => '/tmp/native-fixture', region_id => 'region-1' };
    $native_result = { status => 'ok', result => 42 };
    $output = '';
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_run_native( '--left', '8', '--right', '11', '--region', 'native-region', '--compact', 'native.pl' ), 0, '_run_native executes a callable native artifact' );
    }
    is( $received{native_args}{left}, 8, '_run_native forwards the numeric left operand' );
    is( $received{native_args}{right}, 11, '_run_native forwards the numeric right operand' );
    is( $received{native_args}{region_name}, 'native-region', '_run_native forwards the requested region' );
    is( $received{native_args}{path}, '/tmp/native-fixture', '_run_native executes the emitted artifact path' );
    like( $output, qr/"args":\[8,11\]/, '_run_native serializes numeric operands in the result' );
    $native_result = { status => 'error', error => 'native failure' };
    {
        local *STDOUT;
        open STDOUT, '>', \$output or die "Unable to capture stdout: $!";
        is( Developer::Dashboard::Pax::CLI->_run_native('native.pl'), 1, '_run_native returns failure when the native process reports an error' );
    }

    my $source_path = File::Spec->rel2abs($success_script);
    {
        local $0 = $source_path;
        is( Developer::Dashboard::Pax::CLI::_pax_bin(), $source_path, '_pax_bin resolves the current PAX executable path' );
    }
    {
        no warnings 'redefine';
        local *Cwd::abs_path = sub { return undef };
        local $0 = 'relative-pax';
        is( Developer::Dashboard::Pax::CLI::_pax_bin(), 'relative-pax', '_pax_bin falls back to the current executable path when canonical resolution fails' );
    }
};

done_testing;

__END__

=head1 NAME

243-pax-cli-entrypoint-coverage.t - PAX command entrypoint and interpreter-mode coverage

=head1 PURPOSE

This test verifies C<Developer::Dashboard::Pax::CLI> help, unknown-command,
script-detection, interpreter-mode dispatch, legacy pipeline wrapper, and
standalone command helper behavior.

=head1 WHY IT EXISTS

The main PAX build tests exercise generated binaries, not every branch in the
Perl CLI module that launches them. This test directly covers the source CLI's
public command switch, shebang-script execution contract, pipeline wrapper
arguments, standalone image inspection/reporting, and command forwarding.

=head1 WHEN TO USE

Use this test when changing top-level command selection, PAX usage output,
interpreter-script detection, pipeline wrapper arguments, standalone image
commands, argument forwarding, or script-load error handling.

=head1 HOW TO USE

Run C<prove -lv t/243-pax-cli-entrypoint-coverage.t> in the development Docker
service for a quick regression loop, then run the repository coverage gate.

=head1 WHAT USES IT

The installed C<pax> launcher loads this CLI module. Repository tests and the
four-metric coverage gate also run this focused regression.

=head1 EXAMPLES

Example 1: verify dispatch and standalone helper behavior:

  prove -lv t/243-pax-cli-entrypoint-coverage.t

Example 2: exercise its source coverage directly:

  HARNESS_PERL_SWITCHES='-MDevel::Cover=-db,/tmp/pax-cli-entrypoint-cover' prove -lv t/243-pax-cli-entrypoint-coverage.t

Example 3: verify repository-wide metrics after changes:

  script/coverage-gate

=cut
