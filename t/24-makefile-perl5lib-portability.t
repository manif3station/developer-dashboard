#!/usr/bin/env perl

use strict;
use warnings;

use Capture::Tiny qw(capture);
use Config;
use Cwd qw(getcwd);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $repo_root = File::Spec->rel2abs( File::Spec->catdir( File::Spec->curdir ) );
my $source_makefile_pl = File::Spec->catfile( $repo_root, 'Makefile.PL' );
my $source_xs = File::Spec->catfile( $repo_root, 'HtmlEscape.xs' );
my $source_version = File::Spec->catfile( $repo_root, 'lib', 'Developer', 'Dashboard', 'Version.pm' );
my $fixture = tempdir( CLEANUP => 1 );
my $home = File::Spec->catdir( $fixture, 'absolute-home' );
my $local_perl5 = File::Spec->catdir( $home, 'perl5', 'lib', 'perl5' );
my $active_arch = File::Spec->catdir( $local_perl5, $Config{archname} );
my $active_version = File::Spec->catdir( $local_perl5, $Config{version} );

make_path(
    File::Spec->catdir( $fixture, 'lib', 'Developer' ),
    File::Spec->catdir( $fixture, 'lib', 'Developer', 'Dashboard' ),
    File::Spec->catdir( $fixture, 'share' ),
    $active_arch,
    $active_version,
);
copy( $source_makefile_pl, File::Spec->catfile( $fixture, 'Makefile.PL' ) )
  or die "Unable to copy Makefile.PL into fixture: $!";
copy( $source_xs, File::Spec->catfile( $fixture, 'HtmlEscape.xs' ) )
  or die "Unable to copy HtmlEscape.xs into fixture: $!";
copy( $source_version, File::Spec->catfile( $fixture, 'lib', 'Developer', 'Dashboard', 'Version.pm' ) )
  or die "Unable to copy the version module into fixture: $!";

_open_write(
    File::Spec->catfile( $fixture, 'lib', 'Developer', 'Dashboard.pm' ),
    "package Developer::Dashboard;\nour \$VERSION = '9.99';\n1;\n",
);
_open_write( File::Spec->catfile( $active_arch, 'DDPortableProbe.pm' ), "package DDPortableProbe;\n1;\n" );
_open_write( File::Spec->catfile( $active_version, 'DDVersionProbe.pm' ), "package DDVersionProbe;\n1;\n" );

# Feature: portable generated Perl launcher with local-lib support
# Scenario: an installation uses an absolute HOME local-lib
#   Given modules exist beneath the active Perl architecture and version roots
#   When Makefile.PL generates its Makefile
#   Then local-lib paths are added by the generated Perl launcher
#   And the active platform path separator is used at runtime
#   And the Makefile contains no make-specific environment export syntax.
# Locate the configure-time dependency in THIS process, where PERL5LIB is still
# intact, so the fixture below can be given it explicitly.
require File::ShareDir::Install;
my $configure_lib = $INC{'File/ShareDir/Install.pm'};
$configure_lib =~ s{[/\\]File[/\\]ShareDir[/\\]Install\.pm\z}{};

my $original_cwd = getcwd();
my ( $stdout, $stderr, $exit );
{
    local $ENV{HOME} = $home;
    local $ENV{PERL5LIB};
    chdir $fixture or die "Unable to chdir to fixture: $!";
    # PERL5LIB is cleared so nothing from the caller's environment can leak into
    # the generated PERL5LIB line - that is the whole claim of this file. But
    # Makefile.PL needs File::ShareDir::Install at CONFIGURE time, and clearing
    # PERL5LIB takes that away wherever it lives in a local-lib rather than
    # system-wide. It is system-wide on this developer machine and local-lib-only
    # on CI, so the test passed here by luck and died there (exit 2, no Makefile
    # written, DD-485). Pass the module's own directory through -I: it restores
    # exactly the one configure-time dependency without putting a search path
    # back into the environment the generated file is built from.
    ( $stdout, $stderr, $exit ) = capture { system( $^X, "-I$configure_lib", 'Makefile.PL' ) };
    chdir $original_cwd or die "Unable to restore cwd: $!";
}

is( $exit, 0, 'ATDD: Makefile.PL configures an absolute HOME local-lib fixture' );
unlike( $stderr, qr/Subroutine postamble redefined/, 'BDD: configuration does not redefine the imported postamble helper' );

my $generated = _slurp( File::Spec->catfile( $fixture, 'Makefile' ) );
my $runner = File::Spec->catfile( $fixture, '.dd-perl5lib-runner.pl' );
ok( -f $runner, 'ATDD: Makefile.PL writes a Perl launcher for local-lib commands' );
like( $generated, qr/^FULLPERL\s*=\s*\$\(PERL\)\s+\.dd-perl5lib-runner\.pl\s*$/m,
    'BDD: generated Makefile invokes the portable launcher through FULLPERL' );
unlike( $generated, qr/^PERL5LIB\s*:=/m,
    'BDD: generated Makefile avoids GNU-only PERL5LIB assignment syntax' );
unlike( $generated, qr/^export\s+PERL5LIB\s*$/m,
    'BDD: generated Makefile avoids GNU-only export syntax' );

my $runner_source = _slurp($runner);
like( $runner_source, qr/\Q$local_perl5\E/,
    'BDD: launcher preserves an absolute HOME local-lib base without a checkout prefix' );
like( $runner_source, qr/\Q$active_arch\E/,
    'BDD: launcher includes the active Config architecture directory' );
like( $runner_source, qr/\Q$active_version\E/,
    'BDD: launcher includes the active Config version directory' );
like( $runner_source, qr/\$Config\{path_sep\}/,
    'BDD: launcher joins paths with the active Config path separator' );

my ( $probe_stdout, $probe_stderr, $probe_exit );
{
    local $ENV{PERL5LIB} = '';
    ( $probe_stdout, $probe_stderr, $probe_exit ) = capture {
        system( $^X, $runner, '-MDDPortableProbe', '-MDDVersionProbe', '-e', 'print "portable\\n"' );
    };
}
is( $probe_exit, 0, 'ATDD: launcher makes both local-lib probe modules available without inherited PERL5LIB' );
is( $probe_stdout, "portable\n", 'BDD: launcher forwards arguments to Perl and preserves its output' );
is( $probe_stderr, '', 'BDD: launcher emits no errors for local modules' );

my $source = _slurp($source_makefile_pl);
like( $source, qr/use Config\b/, 'ATDD: Makefile.PL derives platform values from Config' );
unlike( $source, qr/x86_64-linux-gnu-thread-multi/, 'ATDD: Makefile.PL does not hard-code one architecture name' );
unlike( $source, qr/\b5\.38\.2\b/, 'ATDD: Makefile.PL does not hard-code one Perl version' );

done_testing;

# _open_write($path, $content)
# Writes one fixture file and closes it with error checking.
# Input: destination path and complete text content.
# Output: none; dies on write or close failure.
sub _open_write {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content or die "Unable to populate $path: $!";
    close $fh or die "Unable to close $path: $!";
    return;
}

# _slurp($path)
# Reads one generated or source file as a scalar for acceptance assertions.
# Input: path to a readable text file.
# Output: complete file content.
sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $content;
}

__END__

=pod

=head1 NAME

t/24-makefile-perl5lib-portability.t - portable Makefile.PL local-lib contract

=head1 PURPOSE

Verifies that Makefile.PL generates a portable Perl launcher from the active
Perl configuration, preserves absolute local-lib roots, and does not redefine
an imported postamble or use GNU-only Makefile environment syntax.

=head1 WHY IT EXISTS

The generated Makefile previously embedded one host's architecture and Perl
version, prefixed absolute HOME paths with the checkout directory, and emitted a
postamble redefinition warning. This test prevents those packaging regressions.

=head1 WHEN TO USE

Run this test when changing Makefile.PL local-lib discovery, generated Perl
launcher paths, platform handling, or File::ShareDir::Install postamble integration.

=head1 HOW TO USE

Run C<prove -lv t/24-makefile-perl5lib-portability.t> from the repository root.
The fixture uses the active Perl's C<Config> values and an absolute temporary HOME.

=head1 WHAT USES IT

Developers and release checks use this regression contract to keep generated
Makefiles portable across Perl versions, architectures, and path separators.

=head1 EXAMPLES

Example 1:

  prove -lv t/24-makefile-perl5lib-portability.t

Run the focused portability contract while implementing Makefile.PL changes.

Example 2:

  prove -lv t/15-release-metadata.t t/40-install-bootstrap.t

Run the closely related release-documentation and install-bootstrap contracts.

=cut
