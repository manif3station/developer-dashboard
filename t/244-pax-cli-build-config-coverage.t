use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use lib 'lib';
use Developer::Dashboard::Pax::CLI;

# write_fixture($path, $content)
# Writes a complete temporary paxfile or entrypoint fixture.
# Input: destination path and fixture content.
# Output: the destination path after the file is closed successfully.
sub write_fixture {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content or die "Unable to write $path: $!";
    close $fh or die "Unable to close $path: $!";
    return $path;
}

my $work = tempdir( CLEANUP => 1 );
my $paxfile = write_fixture(
    File::Spec->catfile( $work, 'project.yml' ),
    join "\n",
    'name: from-file',
    'entrypoint: app/main.pl',
    'output: build/application',
    'runtime_mode: fast',
    'app_name: demo-app',
    'app_namespace: Demo::App',
    'app_entrypoint_env: DEMO_ENTRY',
    'app_entrypoint_fallback: main.pl',
    'app_command: start',
    'libs:',
    '  - lib',
    'source_roots:',
    '  - src',
    'assets:',
    '  - assets/site.css',
    'asset_dirs:',
    '  - public',
    'cpanfiles:',
    '  - cpanfile',
    '',
);

my $error = '';
{
    local *STDERR;
    open STDERR, '>', \$error or die "Unable to capture stderr: $!";
    my $invalid = Developer::Dashboard::Pax::CLI->_standalone_build_config('--no-paxfile');
    is( $invalid, 2, '_standalone_build_config requires an entrypoint when paxfile loading is disabled' );
}
like( $error, qr/standalone-build requires a Perl entrypoint/, '_standalone_build_config explains the missing entrypoint' );

$error = '';
{
    local *STDERR;
    open STDERR, '>', \$error or die "Unable to capture stderr: $!";
    is( Developer::Dashboard::Pax::CLI->_standalone_build_config('--no-paxfile', 'main.pl', '-e', 'print 1'), 2, '_standalone_build_config rejects simultaneous entrypoint and inline eval' );
}
like( $error, qr/cannot accept both an entrypoint and -e/, '_standalone_build_config identifies the conflicting inputs' );

my @missing_values = (
    [ '-I', '-I' ], [ '-M', '-M' ], [ '-e', '-e' ], [ '--name', '--name' ],
    [ '--paxfile', '--paxfile' ], [ '--lib', '--lib' ], [ '--source-root', '--source-root' ],
    [ '--asset', '--asset' ], [ '--asset-dir', '--asset-dir' ], [ '--cpanfile', '--cpanfile' ],
    [ '--output', '--output' ], [ '-o', '--output' ], [ '--runtime-mode', '--runtime-mode' ],
    [ '--app-name', '--app-name' ], [ '--app-namespace', '--app-namespace' ],
    [ '--app-entrypoint-env', '--app-entrypoint-env' ],
    [ '--app-entrypoint-fallback', '--app-entrypoint-fallback' ], [ '--app-command', '--app-command' ],
);
for my $case (@missing_values) {
    my ( $argument, $diagnostic ) = @$case;
    $error = '';
    {
        local *STDERR;
        open STDERR, '>', \$error or die "Unable to capture stderr: $!";
        is(
            Developer::Dashboard::Pax::CLI->_standalone_build_config( '--no-paxfile', $argument ),
            2,
            "_standalone_build_config rejects a missing value for $argument",
        );
    }
    like( $error, qr/\Q$diagnostic\E requires a value/, "_standalone_build_config diagnoses the missing $argument value" );
}

$error = '';
{
    local *STDERR;
    open STDERR, '>', \$error or die "Unable to capture stderr: $!";
    is( Developer::Dashboard::Pax::CLI->_standalone_build_config( '--no-paxfile', 'main.pl', 'extra.pl' ), 2, '_standalone_build_config rejects extra positional arguments' );
}
like( $error, qr/unexpected argument: extra\.pl/, '_standalone_build_config names the extra argument' );

my $inline = Developer::Dashboard::Pax::CLI->_standalone_build_config(
    '--no-paxfile', '--name', 'inline-app', '-I', 'local/lib', '-Ivendor/lib',
    '-M', 'JSON::XS', '-Mutf8=encode,decode', '-e', 'print 1;', '-e', 'print 2;',
    '--lib', 'lib', '--source-root', 'src', '--asset', 'logo.svg', '--asset-dir', 'public',
    '--cpanfile', 'cpanfile', '-o', 'out/app', '--runtime-mode', 'core',
    '--app-name', 'inline-name', '--app-namespace', 'Inline::App',
    '--app-entrypoint-env', 'INLINE_ENTRY', '--app-entrypoint-fallback', 'fallback.pl',
    '--app-command', 'serve', '--compact',
);
is( ref($inline), 'HASH', 'inline-eval configuration is returned as a config hash' );
is( $inline->{name}, 'inline-app', 'CLI name override is retained' );
is( $inline->{entrypoint}, undef, 'inline eval does not invent a file entrypoint' );
is( $inline->{inline_eval}, "print 1;\nprint 2;", 'repeated -e fragments are joined in order' );
is_deeply( $inline->{perl_libs}, [ 'local/lib', 'vendor/lib' ], 'separate and attached -I values are collected' );
is_deeply( $inline->{perl_modules}, [ 'JSON::XS', 'utf8=encode,decode' ], 'separate -M and attached -M values are collected' );
is_deeply( $inline->{override_fields}, [ qw(app_command app_entrypoint_env app_entrypoint_fallback app_name app_namespace asset_dirs assets cpanfiles inline_eval inline_eval libs name output perl_libs perl_libs perl_modules perl_modules runtime_mode source_roots) ], 'override field names are sorted while preserving repeated overrides' );
is( $inline->{pretty}, 0, '--compact disables pretty output' );
is( $inline->{no_paxfile}, 1, '--no-paxfile is reflected in the parsed config' );
is( $inline->{paxfile_applied}, 0, '--no-paxfile records that no defaults were applied' );
is( $inline->{app_entrypoint_env}, 'INLINE_ENTRY', 'application entrypoint environment override is retained' );

my $from_cli_no_defaults = Developer::Dashboard::Pax::CLI->_standalone_build_config( '--no-paxfile', 'cli/main.pl', '--name', 'cli-name' );
is( $from_cli_no_defaults->{entrypoint}, 'cli/main.pl', 'a CLI entrypoint is retained when paxfile defaults are disabled' );
is( $from_cli_no_defaults->{name}, 'cli-name', 'a CLI name is retained when paxfile defaults are disabled' );
is( $from_cli_no_defaults->{paxfile_applied}, 0, 'paxfile defaults are not implicitly applied when a CLI entrypoint omits --paxfile' );

my $from_cli_with_defaults = Developer::Dashboard::Pax::CLI->_standalone_build_config( '--paxfile', $paxfile, 'cli/main.pl', '--name', 'cli-name' );
is( $from_cli_with_defaults->{entrypoint}, 'cli/main.pl', 'an explicit CLI entrypoint overrides the paxfile entrypoint' );
is( $from_cli_with_defaults->{name}, 'cli-name', 'an explicit CLI name overrides the paxfile name' );
is( $from_cli_with_defaults->{paxfile_applied}, 1, 'explicit --paxfile applies defaults for a CLI entrypoint' );
is_deeply( $from_cli_with_defaults->{libs}, ['lib'], 'paxfile list defaults populate library directories' );
is( $from_cli_with_defaults->{app_namespace}, 'Demo::App', 'paxfile scalar defaults populate application metadata' );

my $inline_with_defaults = Developer::Dashboard::Pax::CLI->_standalone_build_config( '--paxfile', $paxfile, '-e', 'print 3;' );
is( $inline_with_defaults->{inline_eval}, 'print 3;', 'inline source is preserved when paxfile is explicitly selected' );
is( $inline_with_defaults->{name}, 'from-file', 'explicit paxfile defaults apply to inline eval' );
is( $inline_with_defaults->{entrypoint}, undef, 'inline eval does not inherit a file entrypoint' );
is( $inline_with_defaults->{paxfile_applied}, 1, 'explicit paxfile application is recorded for inline eval' );

my $original_cwd = getcwd();
chdir $work or die "Unable to enter $work: $!";
my $default_path = write_fixture( 'paxfile.yml', "entrypoint: default.pl\nname: default-app\n" );
my $from_default_file = Developer::Dashboard::Pax::CLI->_standalone_build_config();
is( $from_default_file->{entrypoint}, 'default.pl', 'no-argument config reads the default paxfile entrypoint' );
is( $from_default_file->{name}, 'default-app', 'no-argument config reads default paxfile metadata' );
is( $from_default_file->{paxfile_applied}, 1, 'no-argument config records that the default paxfile was applied' );
chdir $original_cwd or die "Unable to return to $original_cwd: $!";

done_testing;

__END__

=head1 NAME

244-pax-cli-build-config-coverage.t - focused tests for standalone PAX build argument normalization

=head1 PURPOSE

This test covers the PAX CLI's standalone build parser, including paxfile
defaults, inline source, repeated list options, aliases, and invalid arguments.

=head1 WHY IT EXISTS

The standalone build parser combines many command-line options with optional
paxfile defaults. Direct tests make precedence and validation explicit without
invoking the expensive compiler or creating a binary.

=head1 WHEN TO USE

Use this test when changing C<pax build> options, paxfile default precedence,
inline C<-e> handling, or the build configuration passed to the packaging layer.

=head1 HOW TO USE

Run C<prove -lv t/244-pax-cli-build-config-coverage.t> inside the development
Docker service for fast parser feedback; follow with the repository coverage gate.

=head1 WHAT USES IT

The PAX CLI uses this parser for standalone build and run commands. The test is
also run by the full repository test and coverage gates.

=head1 EXAMPLES

Example 1: exercise parser behavior:

  prove -lv t/244-pax-cli-build-config-coverage.t

Example 2: collect focused coverage:

  HARNESS_PERL_SWITCHES='-MDevel::Cover=-db,/tmp/pax-cli-config-cover' prove -lv t/244-pax-cli-build-config-coverage.t

Example 3: check every production module after a change:

  script/coverage-gate

=cut
