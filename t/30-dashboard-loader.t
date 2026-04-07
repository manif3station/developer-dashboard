#!/usr/bin/env perl
use strict;
use warnings;

use Cwd qw(getcwd);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use Developer::Dashboard::CLI::SeededPages ();

my $repo_root = getcwd();
my $dashboard = File::Spec->catfile( $repo_root, 'bin', 'dashboard' );
my $source = _slurp($dashboard);

like( $source, qr/\A#!\/usr\/bin\/env perl\b/, 'dashboard entrypoint uses /usr/bin/env perl' );
unlike( $source, qr/TITLE:\s+API Dashboard/, 'dashboard entrypoint no longer embeds the api-dashboard bookmark source' );
unlike( $source, qr/BOOKMARK:\s+api-dashboard/, 'dashboard entrypoint no longer embeds the api-dashboard bookmark id source' );
unlike( $source, qr/TITLE:\s+SQL Dashboard/, 'dashboard entrypoint no longer embeds the sql-dashboard bookmark source' );
unlike( $source, qr/BOOKMARK:\s+sql-dashboard/, 'dashboard entrypoint no longer embeds the sql-dashboard bookmark id source' );
like( $source, qr/Developer::Dashboard::CLI::SeededPages/, 'dashboard entrypoint delegates seeded bookmark creation to a dedicated module' );
unlike( $source, qr/Developer::Dashboard::CLI::Query/, 'dashboard entrypoint no longer loads the query CLI module directly' );
unlike( $source, qr/Developer::Dashboard::CLI::OpenFile/, 'dashboard entrypoint no longer loads the open-file CLI module directly' );
unlike( $source, qr/Developer::Dashboard::CLI::Ticket/, 'dashboard entrypoint no longer loads the ticket CLI module directly' );

my $repo_seeded_root = Developer::Dashboard::CLI::SeededPages::_repo_seeded_pages_root();
my $welcome_seeded_path = Developer::Dashboard::CLI::SeededPages::_seeded_page_asset_path('welcome.page');
ok(
    ( -d $repo_seeded_root ) || ( -f $welcome_seeded_path ),
    'seeded page loader resolves either the repo seeded-pages root or the installed share asset path',
);
ok( -f $welcome_seeded_path, 'seeded page loader resolves the shipped welcome bookmark asset path' );
is(
    Developer::Dashboard::CLI::SeededPages::welcome_page()->as_hash->{id},
    'welcome',
    'welcome_page loads the shipped welcome bookmark document',
);
is(
    Developer::Dashboard::CLI::SeededPages::api_dashboard_page()->as_hash->{id},
    'api-dashboard',
    'api_dashboard_page loads the shipped api-dashboard bookmark document',
);
is(
    Developer::Dashboard::CLI::SeededPages::sql_dashboard_page()->as_hash->{id},
    'sql-dashboard',
    'sql_dashboard_page loads the shipped sql-dashboard bookmark document',
);
my $missing_seeded_error = eval { Developer::Dashboard::CLI::SeededPages::_page_from_asset(''); 1 } ? '' : ($@ || '');
like( $missing_seeded_error, qr/Missing seeded page filename/, 'seeded page loader rejects missing asset filenames' );

my $lib = File::Spec->catdir( $repo_root, 'lib' );
my $fake_lib = tempdir( CLEANUP => 1 );
my $fake_web_dir = File::Spec->catdir( $fake_lib, 'Developer', 'Dashboard', 'Web' );
make_path($fake_web_dir);
my $fake_web_app = File::Spec->catfile( $fake_web_dir, 'App.pm' );
open my $fake_web_fh, '>', $fake_web_app or die "Unable to write $fake_web_app: $!";
print {$fake_web_fh} <<'PERL';
package Developer::Dashboard::Web::App;
die "lazy-loader-regression: heavy web runtime was loaded for a lightweight command\n";
PERL
close $fake_web_fh;

local $ENV{HOME} = tempdir( CLEANUP => 1 );
local $ENV{PERL5OPT} = '-I' . $fake_lib;
my $jq_json = File::Spec->catfile( $ENV{HOME}, 'sample.json' );
open my $jq_fh, '>', $jq_json or die "Unable to write $jq_json: $!";
print {$jq_fh} qq|{"alpha":1}\n|;
close $jq_fh;

my $jq_output = qx{$^X -I$lib $dashboard jq .alpha "$jq_json" 2>&1};
my $jq_exit = $? >> 8;
is( $jq_exit, 0, 'dashboard jq stays on the lazy lightweight path without loading heavy web modules' )
  or diag $jq_output;
like( $jq_output, qr/\b1\b/, 'dashboard jq still returns the requested value' );

my $version_output = qx{$^X -I$lib $dashboard version 2>&1};
my $version_exit = $? >> 8;
is( $version_exit, 0, 'dashboard version also stays on the lightweight path without loading heavy web modules' )
  or diag $version_output;
like( $version_output, qr/^\d+\.\d+\s*\z/, 'dashboard version still prints the package version' );

my $fake_share_root = tempdir( CLEANUP => 1 );
my $fake_seeded_dir = File::Spec->catdir( $fake_share_root, 'seeded-pages' );
make_path($fake_seeded_dir);
my $fake_seeded_page = File::Spec->catfile( $fake_seeded_dir, 'fallback.page' );
open my $fake_seeded_fh, '>', $fake_seeded_page or die "Unable to write $fake_seeded_page: $!";
print {$fake_seeded_fh} "TITLE: ShareDir Fallback\n:--------------------------------------------------------------------------------:\nBODY: fallback\n";
close $fake_seeded_fh;

{
    no warnings 'redefine';
    local *Developer::Dashboard::CLI::SeededPages::_repo_seeded_pages_root = sub { return File::Spec->catdir( $fake_share_root, 'missing-repo-share' ); };
    local *Developer::Dashboard::CLI::SeededPages::_shared_seeded_pages_root = sub { return $fake_seeded_dir; };
    is(
        Developer::Dashboard::CLI::SeededPages::_seeded_page_instruction('fallback.page'),
        "TITLE: ShareDir Fallback\n:--------------------------------------------------------------------------------:\nBODY: fallback\n",
        'seeded page loader falls back to the installed dist share directory when repo assets are absent',
    );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::CLI::SeededPages::dist_dir = sub { return $fake_share_root; };
    is(
        Developer::Dashboard::CLI::SeededPages::_shared_seeded_pages_root(),
        $fake_seeded_dir,
        'seeded page loader resolves the installed dist share directory root',
    );
}

my @perl_scripts = (
    File::Spec->catfile( $repo_root, 'bin', 'dashboard' ),
    File::Spec->catfile( $repo_root, 'app.psgi' ),
    (
    map { File::Spec->catfile( $repo_root, 'updates', $_ ) } qw(
      01-bootstrap-runtime.pl
      02-install-deps.pl
      03-shell-bootstrap.pl
    ),
    ),
    (
    map { File::Spec->catfile( $repo_root, 'share', 'private-cli', $_ ) } qw(
      jq
      yq
      tomq
      propq
      iniq
      csvq
      xmlq
      of
      open-file
      ticket
      path
      paths
      ps1
    ),
    ),
    (
    map { File::Spec->catfile( $repo_root, 't', $_ ) } qw(
      19-skill-system.t
      20-skill-web-routes.t
    ),
    ),
    File::Spec->catfile( $repo_root, 'integration', 'blank-env', 'run-integration.pl' ),
);

for my $path (@perl_scripts) {
    my $content = _slurp($path);
    like( $content, qr/\A#!\/usr\/bin\/env perl\b/, "$path uses /usr/bin/env perl" );
}

done_testing();

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

__END__

=head1 NAME

30-dashboard-loader.t - verify dashboard stays thin, lazy, and env-perl based

=head1 DESCRIPTION

This test keeps the public dashboard entrypoint free from embedded bookmark
source, verifies lightweight commands avoid the heavy web runtime, and enforces
the C</usr/bin/env perl> shebang for shipped Perl scripts.

=cut
