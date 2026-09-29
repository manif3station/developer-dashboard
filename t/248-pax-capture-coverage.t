#!/usr/bin/env perl

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::Capture;

{
    package Local::PaxCaptureReadHandle;
    sub TIEHANDLE { return bless { eof => $_[1] }, $_[0] }
    sub READLINE { return }
    sub EOF { return $_[0]{eof} }
}

my $root = tempdir( CLEANUP => 1 );
my $capture = Developer::Dashboard::Pax::Capture->new;
is( $capture->{mode}, 'live', 'capture defaults to live mode' );
my $hermetic = Developer::Dashboard::Pax::Capture->new( mode => 'hermetic' );
is( $hermetic->{mode}, 'hermetic', 'capture retains an explicit mode' );

my $missing = $capture->capture( File::Spec->catfile( $root, 'absent.pl' ) );
is( $missing->{status}, 'error', 'missing entrypoint reports an error' );
is( $missing->{diagnostics}[0]{code}, 'entrypoint_not_found', 'missing entrypoint has a stable diagnostic code' );
is( $missing->{mode}, 'live', 'missing entrypoint response includes capture mode' );
is( $capture->capture('')->{diagnostics}[0]{code}, 'entrypoint_not_found', 'empty entrypoint reports the unresolved-path branch' );
is( $capture->capture($root)->{diagnostics}[0]{code}, 'entrypoint_not_found', 'directory entrypoint reports the non-file branch' );
is(
    $capture->capture( File::Spec->catfile( $root, 'missing-parent', 'absent.pl' ) )->{diagnostics}[0]{code},
    'entrypoint_not_found',
    'unresolvable parent path reports the undefined-absolute-path branch',
);

my $entrypoint = File::Spec->catfile( $root, 'features.pl' );
_write( $entrypoint, <<'PERL' );
use strict;
use warnings;
our $fixture_glob;
# *fixture_glob is a deliberate typeglob token for the static feature scan.
# use overload is a deliberate source feature marker; the probe remains isolated
# from actual overload changes in package main.
# DynaLoader is a deliberate optional-loader feature marker.
sub binary_add { my ($left, $right) = @_; return $left + $right; }
sub binary_and { my ($left, $right) = @_; return $left & $right; }
sub sum_to_n { my ($limit) = @_; my $sum = 0; for (my $i = 1; $i <= $limit; $i++) { $sum += $i; } return $sum; }
sub masked_mix { my ($limit) = @_; my $acc = 0; for (my $i = 0; $i < $limit; $i++) { $acc += (($i * 13) ^ ($i >> 3)) & 0xFFFF; } return $acc; }
sub tied_value { tie my %values, 'Local::Tie'; }
sub autoloaded_value { our $AUTOLOAD; }
sub local_value { local $fixture_glob = 1; }
sub eval_value { eval '1'; }
sub regex_value { return qr/value/i; }
sub required_module { require File::Spec; }
print "captured\n";
1;
PERL

my $result = $hermetic->capture($entrypoint);
is( $result->{status}, 'ok', 'valid entrypoint is captured successfully' );
is( $result->{mode}, 'hermetic', 'successful result records requested mode' );
is( $result->{source_entrypoint}, abs_path($entrypoint), 'successful result reports canonical entrypoint path' );
is( $result->{source_features}{string_eval}, 1, 'source scan identifies string eval' );
is( $result->{source_features}{autoload}, 1, 'source scan identifies AUTOLOAD' );
is( $result->{source_features}{tie}, 1, 'source scan identifies tie' );
is( $result->{source_features}{overload}, 1, 'source scan identifies overload' );
is( $result->{source_features}{typeglob}, 1, 'source scan identifies a typeglob' );
is( $result->{source_features}{local_dynamic}, 1, 'source scan identifies localized dynamic variables' );
is( $result->{source_features}{xs_loader}, 1, 'source scan identifies optional XS loaders' );
ok(
    !scalar( grep { $_->{code} eq 'entrypoint_execution_failed' } @{ $result->{diagnostics} } ),
    'successful source completes without an execution-failure diagnostic',
);

my %native_shapes = map { ($_->{name} // '') => $_->{native_shape} }
    @{ $result->{capture}{sub_optrees} // [] };
is( $native_shapes{'main::binary_add'}{op}, 'add', 'capture recognizes an i64 addition leaf' );
is( $native_shapes{'main::binary_and'}{op}, 'bitwise_and', 'capture recognizes an i64 bitwise leaf' );
is( $native_shapes{'main::sum_to_n'}{op}, 'sum_to_n', 'capture recognizes the sum loop shape' );
is( $native_shapes{'main::masked_mix'}{op}, 'masked_mix_accumulate', 'capture recognizes the masked mix loop shape' );
my ( $empty_out, $empty_err, $empty_exit ) = Developer::Dashboard::Pax::Capture::_run_perl_probe( 'exit 0;', $entrypoint, 'probe-empty' );
is( $empty_out, '', 'probe reader normalizes an empty stdout stream' );
is( $empty_err, '', 'probe reader normalizes an empty stderr stream' );
is( $empty_exit, 0, 'probe reader returns the child exit status' );
{
    tie *PAX_CAPTURE_EOF, 'Local::PaxCaptureReadHandle', 1;
    is( Developer::Dashboard::Pax::Capture::_read_probe_stream( \*PAX_CAPTURE_EOF, 'stdout' ), '', 'an undefined read at clean EOF is normalized to empty content' );
    untie *PAX_CAPTURE_EOF;
}
{
    tie *PAX_CAPTURE_READ_ERROR, 'Local::PaxCaptureReadHandle', 0;
    my $read_error = eval { Developer::Dashboard::Pax::Capture::_read_probe_stream( \*PAX_CAPTURE_READ_ERROR, 'stderr' ); 1 } ? '' : $@;
    like( $read_error, qr/cannot read stderr from reference Perl probe/, 'an undefined read before EOF is reported as an error' );
    untie *PAX_CAPTURE_READ_ERROR;
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::_run_perl_probe = sub { return ( '{}', '', 0 ) };
    my $sparse = $capture->capture($entrypoint);
    is_deeply( $sparse->{diagnostics}, [], 'hash probe output without diagnostics defaults to an empty list' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::Pax::Capture::_run_perl_probe = sub { return ( '[]', '', 0 ) };
    my $non_hash = $capture->capture($entrypoint);
    is( $non_hash->{status}, 'ok', 'non-hash probe output is normalized before status fields are added' );
    is_deeply( $non_hash->{diagnostics}, [], 'non-hash probe output receives an empty diagnostics list' );
}

my $warning_entrypoint = File::Spec->catfile( $root, 'warning.pl' );
_write( $warning_entrypoint, "warn qq(fixture warning\\n); 1;\\n" );
my $warning = $capture->capture($warning_entrypoint);
is( $warning->{status}, 'ok', 'warnings do not make a successful entrypoint fail' );
is( $warning->{diagnostics}[0]{code}, 'perl_stderr', 'successful stderr is reported as a warning diagnostic' );
is( $warning->{diagnostics}[0]{level}, 'warning', 'successful stderr diagnostic has warning level' );

my $failure_entrypoint = File::Spec->catfile( $root, 'failure.pl' );
_write( $failure_entrypoint, "die qq(fixture failure\\n);\\n" );
my $failure = $capture->capture($failure_entrypoint);
is( $failure->{status}, 'error', 'runtime exception makes capture fail' );
ok( scalar( grep { $_->{code} eq 'capture_failed' } @{ $failure->{diagnostics} } ), 'nonzero probe exit has a capture-failed diagnostic' );
ok( scalar( grep { $_->{code} eq 'entrypoint_execution_failed' } @{ $failure->{diagnostics} } ), 'runtime exception is retained in probe diagnostics' );

my $invalid_json = Developer::Dashboard::Pax::Capture::_decode_probe_output('{broken');
is( $invalid_json->{diagnostics}[0]{code}, 'probe_json_decode_failed', 'malformed probe JSON returns a decode diagnostic' );
is( $invalid_json->{raw_probe_output}, '{broken', 'malformed probe output is retained for diagnosis' );
my $empty_source = File::Spec->catfile( $root, 'empty.pl' );
_write( $empty_source, '' );
is( Developer::Dashboard::Pax::Capture::_scan_source_features($empty_source)->{string_eval}, 0, 'empty readable source follows the no-feature path' );
is( Developer::Dashboard::Pax::Capture::_scan_source_features($root)->{string_eval}, 0, 'directory read returning EOF is normalized as empty source' );
is_deeply(
    Developer::Dashboard::Pax::Capture::_scan_source_features( File::Spec->catfile( $root, 'missing.pl' ) ),
    {},
    'source scan treats an unreadable source as having no detected features',
);

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

t/248-pax-capture-coverage.t - verifies capture behavior and source analysis

=head1 PURPOSE

This test exercises the PAX Capture API with real temporary Perl entrypoints.
It checks missing files, successful structural capture, source feature flags,
recognized arithmetic shapes, stderr warnings, runtime failures, and malformed
probe JSON.

=head1 WHY IT EXISTS

Capture is the reference-execution boundary used by PAX validation and analysis.
Its result and diagnostics must distinguish a missing source, successful
execution with warnings, failed execution, and invalid probe output.

=head1 WHEN TO USE

Run this test when changing C<Developer::Dashboard::Pax::Capture>, its probe
protocol, source-feature scanning, or recognized native-shape contracts.

=head1 HOW TO USE

Run inside the development container:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/248-pax-capture-coverage.t

=head1 WHAT USES IT

The PAX differential runner, compatibility analysis, benchmark matrix, and
build pipeline use C<Developer::Dashboard::Pax::Capture> to inspect programs
under reference Perl.

=head1 EXAMPLES

Example 1: pass a valid source file to C<capture> and inspect the returned
runtime structure and source feature map.

Example 2: pass a missing path and check the C<entrypoint_not_found> diagnostic.

Example 3: run a program that warns or dies and inspect the distinct stderr and
execution-failure diagnostics.

=cut
