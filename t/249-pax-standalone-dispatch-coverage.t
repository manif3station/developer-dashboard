#!/usr/bin/env perl

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneDispatch;

{
    package Local::PaxDispatchImageStore;
    sub new { return bless { image => $_[1] }, $_[0] }
    sub load { return $_[0]{image} }
}

{
    package Local::PaxDispatchNativeRunner;
    sub new { return bless { result => $_[1] }, $_[0] }
    sub run_i64_binary { return $_[0]{result} }
}

{
    package Local::PaxDispatchReadHandle;
    sub TIEHANDLE { return bless { eof => $_[1] }, $_[0] }
    sub READLINE { return }
    sub EOF { return $_[0]{eof} }
}

my $root = tempdir( CLEANUP => 1 );
my $lib = abs_path('lib');
my $image = _image();

my $default = Developer::Dashboard::Pax::StandaloneDispatch->new;
isa_ok( $default->{image_store}, 'Developer::Dashboard::Pax::StandaloneImage', 'default constructor creates an image store' );
isa_ok( $default->{native_runner}, 'Developer::Dashboard::Pax::NativeRunner', 'default constructor creates a native runner' );

my $native = Developer::Dashboard::Pax::StandaloneDispatch->new(
    image_store => Local::PaxDispatchImageStore->new($image),
    native_runner => Local::PaxDispatchNativeRunner->new({ status => 'ok', value => 42 }),
);
my $default_runner = Developer::Dashboard::Pax::StandaloneDispatch->new(
    image_store => Local::PaxDispatchImageStore->new($image),
);
isa_ok( $default_runner->{native_runner}, 'Developer::Dashboard::Pax::NativeRunner', 'supplying only an image store retains the default runner' );
my $default_store = Developer::Dashboard::Pax::StandaloneDispatch->new(
    native_runner => Local::PaxDispatchNativeRunner->new({ status => 'ok' }),
);
isa_ok( $default_store->{image_store}, 'Developer::Dashboard::Pax::StandaloneImage', 'supplying only a runner retains the default image store' );
is( Developer::Dashboard::Pax::StandaloneDispatch->new( image_store => '' )->{image_store}, '', 'defined false image-store values are preserved rather than replaced by defaults' );
is( Developer::Dashboard::Pax::StandaloneDispatch->new( native_runner => 0 )->{native_runner}, 0, 'defined false runner values are preserved rather than replaced by defaults' );
my $native_result;
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneDispatch::_extract_image = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region = sub { die 'native path should not use Perl fallback' };
    $native_result = $native->run_i64( image => $image, region_name => 'add', left => 19, right => 23 );
}
is( $native_result->{status}, 'native', 'validated packaged native region returns native status' );
is( $native_result->{execution_model}, 'standalone_packaged_native', 'native result identifies packaged execution' );
is( $native_result->{result}{value}, 42, 'native runner result is retained' );

my $missing_region = $native->run_i64( image => $image, region_name => 'absent' );
is( $missing_region->{status}, 'fallback', 'unknown region returns a fallback result' );
is( $missing_region->{execution_model}, 'standalone_region_missing', 'unknown region identifies the missing-region execution model' );
like( $missing_region->{reason}, qr/region not found: absent/, 'unknown region names the requested region' );

my $store_loaded = Developer::Dashboard::Pax::StandaloneDispatch->new(
    image_store => Local::PaxDispatchImageStore->new($image),
    native_runner => Local::PaxDispatchNativeRunner->new({ status => 'ok' }),
);
my $load_error = eval { $store_loaded->run_i64( region_name => 'absent' ); 1 } ? '' : $@;
like( $load_error, qr/name required/, 'image-store lookup requires a name' );
my $false_image_error = eval { $store_loaded->run_i64( image => 0, region_name => 'add' ); 1 } ? '' : $@;
like( $false_image_error, qr/HASH ref/, 'a defined false image is selected literally instead of falling back to image-store loading' );
my $region_error = eval { $native->run_i64( image => $image ); 1 } ? '' : $@;
like( $region_error, qr/region_name required/, 'region dispatch requires a region name' );
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneDispatch::_extract_image = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits = sub { return };
    my $loaded = $store_loaded->run_i64( name => 'fixture-image', region_name => 'add' );
    is( $loaded->{status}, 'native', 'image-store image is loaded by its requested name' );
}

my $deopt_image = _image(
    runtime_epochs => { 'build-epoch' => 1 },
    native_dispatch => [{
        region_id => 'region-7',
        region_name => 'add',
        guards => [{ id => 'guard-1', invalidation_key => 'build-epoch' }],
        deopt => { safepoint => 'after-add' },
    }],
);
my $deopt_dispatch = Developer::Dashboard::Pax::StandaloneDispatch->new(
    native_runner => Local::PaxDispatchNativeRunner->new({ status => 'ok' }),
);
my $deopt_result;
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneDispatch::_extract_image = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region = sub {
        return { status => 'ok', value => 42, reason => 'fixture-interpreter-result' };
    };
    $deopt_result = $deopt_dispatch->run_i64( image => $deopt_image, region_name => 'add', left => 19, right => 23, invalidate => ['build-epoch'] );
}
is( $deopt_result->{status}, 'deopt', 'failed epoch guard selects deoptimization status' );
is( $deopt_result->{deopt}{continuation}, 'after-add', 'deoptimization keeps the continuation point' );
is( $deopt_result->{result}{value}, 42, 'deoptimized region includes interpreter fallback result' );

my $native_failure_dispatch = Developer::Dashboard::Pax::StandaloneDispatch->new(
    native_runner => Local::PaxDispatchNativeRunner->new({ status => 'error', reason => 'native-failed' }),
);
my $fallback_result;
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneDispatch::_extract_image = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region = sub {
        return { status => 'ok', value => 42, reason => 'native_execution_failed' };
    };
    $fallback_result = $native_failure_dispatch->run_i64( image => $image, region_name => 'add', left => 19, right => 23 );
}
is( $fallback_result->{status}, 'fallback', 'native runner failure selects the bundled Perl fallback' );
is( $fallback_result->{execution_model}, 'standalone_bundled_perl_fallback', 'fallback result identifies bundled Perl execution' );
is( $fallback_result->{deopt}{reason}, 'native_execution_failed', 'fallback reason is passed into deoptimization reconstruction' );

my $fallback_without_native = Developer::Dashboard::Pax::StandaloneDispatch->new(
    native_runner => Local::PaxDispatchNativeRunner->new({}),
);
my $no_native_result;
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneDispatch::_extract_image = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region = sub { return {} };
    $no_native_result = $fallback_without_native->run_i64(
        image => _image( runtime_epochs => undef, native_dispatch => [{ region_id => 'bare', region_name => 'add' }] ),
        region_name => 'add',
    );
}
is( $no_native_result->{status}, 'fallback', 'region without a native artifact uses Perl fallback' );
is( $no_native_result->{deopt}{reason}, 'native_execution_failed', 'missing fallback reason uses the documented default reason' );

my $empty_native_result;
{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::StandaloneDispatch::_extract_image = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits = sub { return };
    local *Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region = sub { return {} };
    $empty_native_result = Developer::Dashboard::Pax::StandaloneDispatch->new(
        native_runner => Local::PaxDispatchNativeRunner->new({}),
    )->run_i64( image => $image, region_name => 'add' );
}
is( $empty_native_result->{status}, 'fallback', 'native result without status falls back to Perl execution' );

my $paths = Developer::Dashboard::Pax::StandaloneDispatch::_runtime_paths( $image, $root );
is( $paths->{perl_exec}, 'perl', 'system runtime uses Perl from PATH' );
is( $paths->{perl5lib}, File::Spec->catdir( $root, 'code', 'lib' ), 'runtime paths include application library roots' );
is( $paths->{assets_root}, File::Spec->catdir( $root, 'assets' ), 'runtime paths include embedded assets root' );
my $bundled_paths = Developer::Dashboard::Pax::StandaloneDispatch::_runtime_paths(
    _image(
        runtime => { mode => 'bundled_perl', perl_binary_logical_path => 'perl/bin/perl', bundled_inc_roots => ['corelib', undef, ''] },
        lib_dirs => ['lib', undef, ''],
    ),
    $root,
);
is( $bundled_paths->{perl_exec}, File::Spec->catfile( $root, 'runtime', 'perl', 'bin', 'perl' ), 'bundled runtime honors its manifest binary path' );
is( $bundled_paths->{perl5lib}, join( ':', File::Spec->catdir( $root, 'code', 'lib' ), File::Spec->catdir( $root, 'runtime', 'corelib' ) ), 'empty library roots are filtered from the search path' );
my $default_binary_paths = Developer::Dashboard::Pax::StandaloneDispatch::_runtime_paths(
    _image( runtime => { mode => 'bundled_perl' }, lib_dirs => undef, ),
    $root,
);
is( $default_binary_paths->{perl_exec}, File::Spec->catfile( $root, 'runtime', 'bin', 'perl' ), 'bundled runtime defaults to bin/perl' );
is( $default_binary_paths->{perl5lib}, '', 'runtime search path is empty when no library roots exist' );
my $missing_mode_paths = Developer::Dashboard::Pax::StandaloneDispatch::_runtime_paths( _image( runtime => {}, lib_dirs => undef ), $root );
is( $missing_mode_paths->{perl_exec}, 'perl', 'runtime without a mode defaults to system Perl' );

is( Developer::Dashboard::Pax::StandaloneDispatch::_lookup_region( $image, 'add' )->{region_name}, 'add', 'region lookup accepts the unqualified name' );
is( Developer::Dashboard::Pax::StandaloneDispatch::_lookup_region( $image, 'missing' ), undef, 'region lookup returns undef when no name matches' );
my $qualified_image = _image( native_dispatch => [{ region_id => 'region-q', region_name => 'main::add' }] );
is( Developer::Dashboard::Pax::StandaloneDispatch::_lookup_region( $qualified_image, 'add' )->{region_name}, 'main::add', 'region lookup accepts its main-package qualified alias' );
is( Developer::Dashboard::Pax::StandaloneDispatch::_lookup_region( {}, 'missing' ), undef, 'region lookup handles an absent dispatch list' );
is( Developer::Dashboard::Pax::StandaloneDispatch::_lookup_region( { native_dispatch => [{}] }, 'missing' ), undef, 'region lookup skips a nameless record' );

my $extractor = File::Spec->catfile( $root, 'extractor.pl' );
_write_executable( $extractor, "print qq(extracted\\n); exit 0;\\n" );
Developer::Dashboard::Pax::StandaloneDispatch::_extract_image( { output_path => $extractor }, $root );
pass('standalone extractor accepts a successful executable');
my $bad_extractor = File::Spec->catfile( $root, 'bad-extractor.pl' );
_write_executable( $bad_extractor, "print STDERR qq(extract fixture failure\\n); exit 7;\\n" );
my $extract_error = eval { Developer::Dashboard::Pax::StandaloneDispatch::_extract_image( { output_path => $bad_extractor }, $root ); 1 } ? '' : $@;
like( $extract_error, qr/standalone extraction failed.*extract fixture failure/s, 'failed extraction reports the child diagnostic and path' );

my $perl_success = File::Spec->catfile( $root, 'fake-perl-success' );
_write_executable( $perl_success, "print qq(42\\n); exit 0;\\n" );
my $old_perl5lib = $ENV{PERL5LIB};
my $run = Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region(
    paths => { perl_exec => $perl_success, perl5lib => $lib, assets_root => 'assets', manifest_path => 'manifest.json', extract_dir => $root, entrypoint => 'entry.pl' },
    region => { region_name => 'add' }, left => 19, right => 23,
);
is( $run->{status}, 'ok', 'successful Perl region reports ok status' );
is( $run->{value}, 42, 'numeric Perl result is converted to a number' );
is( $run->{reason}, 'perl_region_fallback', 'successful Perl region explains the fallback model' );
is( $ENV{PERL5LIB}, $old_perl5lib, 'temporary runtime library path is restored after execution' );

my $non_numeric_perl = File::Spec->catfile( $root, 'fake-perl-text' );
_write_executable( $non_numeric_perl, "print qq(not-a-number\\n); exit 0;\\n" );
my $text_run = Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region(
    paths => { perl_exec => $non_numeric_perl, assets_root => 'assets', manifest_path => 'manifest.json', extract_dir => $root, entrypoint => 'entry.pl' },
    region => { region_name => 'add' }, left => 1, right => 2,
);
is( $text_run->{status}, 'ok', 'successful nonnumeric Perl output remains a successful execution' );
is( $text_run->{value}, undef, 'nonnumeric Perl output has no integer result value' );

my $perl_failure = File::Spec->catfile( $root, 'fake-perl-failure' );
_write_executable( $perl_failure, "print STDERR qq(fallback fixture failure\\n); exit 9;\\n" );
my $failed_run = Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region(
    paths => { perl_exec => $perl_failure, assets_root => 'assets', manifest_path => 'manifest.json', extract_dir => $root, entrypoint => 'entry.pl' },
    region => { region_name => 'add' }, left => 1, right => 2,
);
is( $failed_run->{status}, 'error', 'nonzero Perl exit reports error status' );
is( $failed_run->{exit}, 9, 'nonzero Perl exit is retained' );
is( $failed_run->{reason}, 'perl_region_execution_failed', 'failed Perl execution has a distinct reason' );
like( $failed_run->{stderr}, qr/fallback fixture failure/, 'Perl fallback stderr is captured' );
my $empty_env_run = Developer::Dashboard::Pax::StandaloneDispatch::_run_perl_region(
    paths => { perl_exec => $non_numeric_perl, perl5lib => '', assets_root => 'assets', manifest_path => 'manifest.json', extract_dir => $root, entrypoint => 'entry.pl' },
    region => { region_name => 'add' }, left => 1, right => 2,
);
is( $empty_env_run->{status}, 'ok', 'empty runtime library path executes without changing the parent environment' );

{
    tie *PAX_DISPATCH_EOF, 'Local::PaxDispatchReadHandle', 1;
    is( Developer::Dashboard::Pax::StandaloneDispatch::_read_process_output( \*PAX_DISPATCH_EOF, 'stdout' ), '', 'undefined read at clean child EOF becomes empty content' );
    untie *PAX_DISPATCH_EOF;
}
{
    tie *PAX_DISPATCH_READ_ERROR, 'Local::PaxDispatchReadHandle', 0;
    my $read_error = eval { Developer::Dashboard::Pax::StandaloneDispatch::_read_process_output( \*PAX_DISPATCH_READ_ERROR, 'stderr' ); 1 } ? '' : $@;
    like( $read_error, qr/cannot read stderr from standalone child process/, 'failed child stream read is exposed instead of ignored' );
    untie *PAX_DISPATCH_READ_ERROR;
}

my $mode_paths = _image(
    runtime => { mode => 'bundled_perl', perl_binary_logical_path => 'runtime/perl' },
    native_dispatch => [
        { executable_logical_path => 'native/one' },
        { executable_logical_path => '' },
        {},
    ],
);
my $mode_root = File::Spec->catdir( $root, 'extract' );
make_path( File::Spec->catdir( $mode_root, 'runtime' ) );
make_path( File::Spec->catdir( $mode_root, 'native' ) );
my $runtime_perl = File::Spec->catfile( $mode_root, 'runtime', 'runtime', 'perl' );
my $native_exec = File::Spec->catfile( $mode_root, 'native', 'one' );
make_path( dirname($runtime_perl) );
_write_executable( $runtime_perl, "exit 0;\\n" );
_write_executable( $native_exec, "exit 0;\\n" );
my $restore_paths = { extract_dir => $mode_root, perl_exec => $runtime_perl };
Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits( $mode_paths, $restore_paths );
pass('executable permission restoration completed for bundled runtime and native files');
is( ( stat($runtime_perl) )[2] & 0777, 0700, 'bundled Perl executable receives private execute permissions' );
is( ( stat($native_exec) )[2] & 0777, 0700, 'native region executable receives private execute permissions' );
Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits(
    _image( runtime => { mode => 'system_perl' }, native_dispatch => [{ executable_logical_path => 'native/not-created' }] ),
    { extract_dir => $mode_root, perl_exec => $runtime_perl },
);
pass('system runtime and absent native executable paths are left unchanged');
Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits(
    _image( runtime => { mode => 'bundled_perl' }, native_dispatch => [] ),
    { extract_dir => $mode_root, perl_exec => File::Spec->catfile( $mode_root, 'runtime', 'missing' ) },
);
pass('missing bundled Perl executable is not chmodded');
Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits( _image( native_dispatch => [] ), { extract_dir => $mode_root, perl_exec => 'not-created' } );
pass('missing dispatch records and bundled runtime paths are handled without chmod');
Developer::Dashboard::Pax::StandaloneDispatch::_restore_executable_bits(
    { runtime => {}, native_dispatch => undef },
    { extract_dir => $mode_root, perl_exec => 'not-created' },
);
pass('missing runtime mode and native-dispatch manifest entries default safely');

done_testing();

sub _image {
    my (%overrides) = @_;
    my $image = {
        output_path => '/not-invoked/standalone-image',
        standalone_dir => '/standalone',
        entrypoint => { logical_path => 'bin/app.pl' },
        runtime => { mode => 'system_perl' },
        runtime_epochs => {},
        lib_dirs => ['lib'],
        native_dispatch => [{
            region_id => 'region-1',
            region_name => 'add',
            guards => [],
            deopt => { safepoint => 'after-add' },
            executable_logical_path => 'native/add',
        }],
    };
    for my $key ( keys %overrides ) {
        $image->{$key} = $overrides{$key};
    }
    return $image;
}

sub _write_executable {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} "#!/usr/bin/env perl\n", $body or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    chmod 0700, $path or die "Unable to chmod $path: $!";
    return;
}

__END__

=head1 NAME

t/249-pax-standalone-dispatch-coverage.t - tests standalone native and fallback dispatch

=head1 PURPOSE

This test exercises the standalone region dispatcher through native success,
missing-region fallback, guard deoptimization, native failure, extraction
errors, runtime path assembly, executable permission restoration, and real
child-process fallback output parsing.

=head1 WHY IT EXISTS

The standalone dispatcher decides whether a region can run as packaged native
code or must execute under the bundled Perl runtime. Both outcomes must preserve
guard, result, diagnostic, and path information for callers.

=head1 WHEN TO USE

Run this test when changing C<Developer::Dashboard::Pax::StandaloneDispatch>,
its image extraction contract, guard decision handling, or interpreter fallback.

=head1 HOW TO USE

Run inside the development container:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/249-pax-standalone-dispatch-coverage.t

=head1 WHAT USES IT

C<Developer::Dashboard::Pax::CLI> invokes C<run_i64> to dispatch packaged
standalone native regions with guard validation and a Perl fallback.

=head1 EXAMPLES

Example 1: run the test alone in Docker to inspect native and fallback behavior.

Example 2: include it in C<script/coverage-gate> to measure every dispatch
statement, branch, condition, and subroutine.

=cut
