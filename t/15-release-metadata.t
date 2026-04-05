use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );

my $pm = _slurp( _repo_path('lib', 'Developer', 'Dashboard.pm') );
my $readme = _slurp( _repo_path('README.md') );
my $skill_guide = _slurp( _repo_path('SKILL.md') );
my $release_doc = _slurp( _repo_path( 'doc', 'update-and-release.md' ) );
my $changes = _slurp( _repo_path('Changes') );
my $dist = _slurp_optional( _repo_path('dist.ini') );
my $meta = _slurp_optional( _repo_path('META.json') );
my $makefile = _slurp( _repo_path('Makefile.PL') );
my @doc_paths = (
    _repo_path('README.md'),
    _repo_path('SKILL.md'),
    _repo_path('FIXED_BUGS.md'),
    _repo_path('MISTAKE.md'),
    _repo_path('CONTRIBUTING.md'),
    _repo_path('SOFTWARE_SPEC.md'),
    _repo_path('TEST_PLAN.md'),
    _repo_path( 'doc', 'architecture.md' ),
    _repo_path( 'doc', 'integration-test-plan.md' ),
    _repo_path( 'doc', 'security.md' ),
    _repo_path( 'doc', 'skills.md' ),
    _repo_path( 'doc', 'static-file-serving.md' ),
    _repo_path( 'doc', 'testing.md' ),
    _repo_path( 'doc', 'update-and-release.md' ),
);
my @pod_paths = (
    _repo_path( 'lib', 'Developer', 'Dashboard.pm' ),
    _repo_path( 'lib', 'Developer', 'Dashboard', 'SKILLS.pm' ),
    _repo_path( 'lib', 'Developer', 'Dashboard', 'CLI', 'Query.pm' ),
    _repo_path( 'lib', 'Developer', 'Dashboard', 'DataHelper.pm' ),
    _repo_path( 'lib', 'Developer', 'Dashboard', 'Doctor.pm' ),
    _repo_path( 'lib', 'Developer', 'Dashboard', 'File.pm' ),
    _repo_path( 'lib', 'Developer', 'Dashboard', 'Folder.pm' ),
    _repo_path( 'lib', 'Developer', 'Dashboard', 'PageRuntime.pm' ),
    _repo_path( 'lib', 'Developer', 'Dashboard', 'Zipper.pm' ),
);
my $skills_pm = _slurp( _repo_path( 'lib', 'Developer', 'Dashboard', 'SKILLS.pm' ) );
my $skills_pod = _extract_pod($skills_pm);

like( $pm, qr/our \$VERSION = '([^']+)'/, 'main module declares a version' );
my ($version) = $pm =~ /our \$VERSION = '([^']+)'/;
is( $version, '1.72', 'repo version bumped for the sql profile permission hardening release' );
like( $pm, qr/^1\.72$/m, 'main POD version matches the module version' );
if ( $dist ne '' ) {
    like( $dist, qr/^version = 1\.72$/m, 'dist.ini version matches the module version in the source tree' );
}
else {
    like( $meta, qr/"version"\s*:\s*"1\.72"/, 'META.json version matches the module version in the built distribution' );
}
like( $changes, qr/^1\.72\s+2026-04-05$/m, 'Changes top entry matches the bumped version' );

for my $path (
    qw(
    bin/pjq
    bin/pyq
    bin/ptomq
    bin/pjp
    bin/jq
    bin/yq
    bin/tomq
    bin/propq
    bin/iniq
    bin/csvq
    bin/xmlq
    bin/of
    bin/open-file
    )
  )
{
    ok( !-e _repo_path($path), "$path is no longer shipped as a public executable" );
}

for my $module (
    qw(
    Developer::Dashboard::Folder
    Developer::Dashboard::DataHelper
    Developer::Dashboard::Zipper
    Developer::Dashboard::Runtime::Result
    )
  )
{
    like( $pm, qr/\Q$module\E/, "main POD documents $module" );
}

unlike( $makefile, qr/bin\/pjq|bin\/pyq|bin\/ptomq|bin\/pjp|bin\/jq|bin\/yq|bin\/tomq|bin\/propq|bin\/iniq|bin\/csvq|bin\/xmlq|bin\/of|bin\/open-file/, 'Makefile.PL does not install generic helper commands into the global PATH' );
like( $makefile, qr/["']LWP::UserAgent["']\s*=>\s*0/, 'Makefile.PL declares the api-dashboard HTTP client runtime prerequisite' );
like( $makefile, qr/["']HTTP::Request["']\s*=>\s*0/, 'Makefile.PL declares the api-dashboard request object runtime prerequisite' );
like( $makefile, qr/["']LWP::Protocol::https["']\s*=>\s*0/, 'Makefile.PL declares the api-dashboard HTTPS protocol runtime prerequisite' );
like( $makefile, qr/["']URI["']\s*=>\s*0/, 'Makefile.PL declares the api-dashboard URI runtime prerequisite' );
for my $helper (qw(jq yq tomq propq iniq csvq xmlq)) {
    ok( -f _repo_path( 'private-cli', $helper ), "private-cli/$helper is shipped as a private helper asset" );
}

for my $doc ( $readme, $pm ) {
    like( $doc, qr/~\/\.developer-dashboard\/cli/, 'docs describe private helper extraction under the runtime cli root' );
    like( $doc, qr/\bof\b.*~\/\.developer-dashboard\/cli|~\/\.developer-dashboard\/cli.*\bof\b/s, 'docs describe private of/open-file helper staging' );
    like( $doc, qr/\bticket\b.*~\/\.developer-dashboard\/cli|~\/\.developer-dashboard\/cli.*\bticket\b/s, 'docs describe private ticket helper staging' );
    like( $doc, qr/dashboard jq/, 'docs describe the renamed jq subcommand' );
    like( $doc, qr/dashboard yq/, 'docs describe the renamed yq subcommand' );
    like( $doc, qr/dashboard tomq/, 'docs describe the renamed tomq subcommand' );
    like( $doc, qr/dashboard propq/, 'docs describe the renamed propq subcommand' );
    like( $doc, qr/dashboard of \. jq|jq\.js.*jquery\.js|jquery\.js.*jq\.js/s, 'docs describe the scoped open-file ranking behaviour' );
    like( $doc, qr/vim -p|C<vim -p>/, 'docs describe vim tab mode for blank-enter open-all' );
    like( $doc, qr/stream_data\(url, target, options, formatter\)|C<stream_data\(url, target, options, formatter\)>/, 'docs describe the bookmark stream_data helper' );
    like( $doc, qr/XMLHttpRequest/, 'docs describe incremental browser streaming through XMLHttpRequest' );
    like( $doc, qr/Postman-style|Postman collection/, 'docs describe the Postman-style api-dashboard workspace' );
    like( $doc, qr/import and export(?: of)? Postman collection v2\.1 JSON|import and export(?: of)? Postman collection v2\.1 JSON/i, 'docs describe Postman collection import/export support' );
    like( $doc, qr/config\/api-dashboard/, 'docs describe the runtime config/api-dashboard collection storage path' );
    like( $doc, qr/API_DASHBOARD_IMPORT_FIXTURE/, 'docs describe the generic api-dashboard import-fixture browser repro' );
    like( $doc, qr/t\/25-api-dashboard-large-import-playwright\.t/, 'docs describe the oversized api-dashboard browser import regression' );
    like( $doc, qr/Collections and Workspace.*top-level tabs|top-level tabs.*Collections and Workspace/s, 'docs describe the tabbed api-dashboard shell layout' );
    like( $doc, qr/config\/sql-dashboard.*0700|0700.*config\/sql-dashboard/s, 'docs describe the owner-only sql-dashboard profile directory' );
    like( $doc, qr/profile JSON file owner-only at `0600`|profile JSON file owner-only at C<0600>|saved profile files at `0600`|saved profile files at C<0600>/, 'docs describe owner-only sql-dashboard profile files' );
    like( $doc, qr/current SQL .*browser URL instead of a saved SQL file|current SQL .*browser URL.*saved SQL file/s, 'docs describe current SQL as URL state instead of a saved SQL file' );
    like( $doc, qr/stored collections as click-through tabs|collection tab strip|collection-to-collection tab strip/s, 'docs describe the tabbed api-dashboard collection browser' );
    like( $doc, qr/Request Details, Response Body, and Response Headers.*inner workspace tabs|inner workspace tabs.*Request Details, Response Body, and Response Headers/s, 'docs describe the tabbed api-dashboard response layout' );
    like( $doc, qr/request-specific\s+token\s+form|carry(?:ing)?\s+those\s+token\s+values\s+across\s+matching\s+placeholders|(?:`\{\{token\}\}`|C<\{\{token\}\}>|\{\{token\}\})\s+placeholders/s, 'docs describe the request-token carry-over workflow' );
    like( $doc, qr/below\s+the\s+response\s+`pre`|below\s+the\s+response\s+C<pre>/s, 'docs describe the response tabs below the response pre box' );
    like( $doc, qr/back\/forward navigation|browser URL/, 'docs describe browser navigation-aware api-dashboard state' );
    like( $doc, qr/PDF,\s+image,\s+and\s+TIFF\s+responses|PDF,\s+image,\s+and\s+TIFF/is, 'docs describe api-dashboard media preview support' );
    like( $doc, qr/empty `200` save\/delete responses|empty C<200> save\/delete responses|execve/s, 'docs describe the stricter api-dashboard save success handling and large-import transport guardrail' );
    like( $doc, qr/dashboard cpan(?: <Module\.\.\.>| E<lt>Module\.\.\.E<gt>)?|C<dashboard cpan E<lt>Module\.\.\.E<gt>>/, 'docs describe the runtime-local dashboard cpan command' );
    like( $doc, qr/sql-dashboard/, 'docs describe the seeded sql-dashboard workspace' );
    like( $doc, qr/config\/sql-dashboard/, 'docs describe the runtime config/sql-dashboard profile storage path' );
    like( $doc, qr/table_info|column_info/, 'docs describe generic DBI schema metadata browsing for sql-dashboard' );
    like( $doc, qr/SQLS_SEP.*INSTRUCTION_SEP|INSTRUCTION_SEP.*SQLS_SEP/s, 'docs describe programmable sql-dashboard statement separators' );
    like( $doc, qr/dashboard cpan DBD::Driver|DBD::\*/, 'docs describe optional DBD driver installation instead of bundling one database driver' );
    like( $doc, qr/t\/27-sql-dashboard-playwright\.t/, 'docs describe the sql-dashboard Playwright browser verification' );
    like( $doc, qr/bin\/dashboard|dashboard entrypoint|C<dashboard> entrypoint/, 'docs describe the dashboard cpan implementation as entrypoint-local' );
    unlike( $doc, qr/CPANManager/, 'docs do not describe a dedicated CPAN manager module for the sql-dashboard runtime driver flow' );
    like( $doc, qr/SKILL\.md/, 'docs point readers at the skill authoring guide' );
    like( $doc, qr/Developer::Dashboard::SKILLS/, 'docs point readers at the shipped skill POD module' );
    unlike( $doc, qr/standalone `of` and `open-file`|standalone of and open-file/, 'docs no longer advertise public standalone of/open-file executables' );
    unlike( $doc, qr/standalone `ticket` executable|standalone ticket executable/, 'docs no longer advertise a public standalone ticket executable' );
    like( $doc, qr/Developer::Dashboard::Runtime::Result/, 'docs use the namespaced Runtime::Result module name' );
    like( $doc, qr/Developer::Dashboard::Folder/, 'docs use the namespaced Folder module name' );
}

for my $doc ( $skill_guide, $skills_pod ) {
    like( $doc, qr/dashboard skills install/, 'skill authoring docs explain installation' );
    like( $doc, qr/dashboard skill example-skill/, 'skill authoring docs explain command dispatch' );
    like( $doc, qr{~/.developer-dashboard/skills/<repo-name>/|F<~/.developer-dashboard/skills/E<lt>repo-nameE<gt>/>}, 'skill authoring docs describe the isolated skill root' );
    like( $doc, qr/cli\/<command>\.d|cli\/E<lt>commandE<gt>\.d/, 'skill authoring docs explain skill hook directories' );
    like( $doc, qr/dashboards\//, 'skill authoring docs explain skill bookmark storage' );
    like( $doc, qr{/skill/<repo-name>/bookmarks/<id>|/skill/E<lt>repo-nameE<gt>/bookmarks/E<lt>idE<gt>}, 'skill authoring docs explain skill bookmark routes' );
    like( $doc, qr/TITLE:.*BOOKMARK:.*HTML:.*CODE1:/s, 'skill authoring docs explain bookmark section syntax' );
    like( $doc, qr/fetch_value\(|stream_value\(|stream_data\(/, 'skill authoring docs explain bookmark browser helpers' );
    like( $doc, qr/Ajax\(file\s*=>\s*'name'|C<Ajax\(file =E<gt> 'name'/, 'skill authoring docs explain saved Ajax endpoints' );
    like( $doc, qr/nav\/\*\.tt|nav\/foo\.tt/, 'skill authoring docs explain nav bookmark structure' );
    like( $doc, qr{~/.developer-dashboard/cli/<command>\.d|~/.developer-dashboard/cli/E<lt>commandE<gt>\.d}, 'skill authoring docs explain dashboard-wide custom CLI hooks' );
    like( $doc, qr/DEVELOPER_DASHBOARD_SKILL_ROOT/, 'skill authoring docs explain the skill command environment' );
    like( $doc, qr/cpanfile/, 'skill authoring docs explain isolated dependency installation' );
    like( $doc, qr/FAQ/i, 'skill authoring docs include an FAQ section' );
    unlike( $doc, qr/FORM\.TT:|FORM:/, 'skill authoring docs no longer document removed FORM bookmark directives' );
}

for my $path (@doc_paths) {
    my $doc = _slurp($path);
    unlike( $doc, qr/\blegacy\b/i, "$path no longer mentions the retired internal wording" );
    unlike( $doc, qr/`FORM\.TT:`|`FORM:`|\bFORM\.TT\b/, "$path no longer documents removed FORM bookmark directives" );
}

for my $path (@pod_paths) {
    my $pod = _extract_pod( _slurp($path) );
    unlike( $pod, qr/\blegacy\b/i, "$path POD no longer mentions the retired internal wording" );
    unlike( $pod, qr/C<FORM\.TT:>|C<FORM:>|\bFORM\.TT\b/, "$path POD no longer documents removed FORM bookmark directives" );
}

for my $doc ($readme) {
    like( $doc, qr/dashboard skills install/, 'README documents skill installation' );
    like( $doc, qr/dashboard skills uninstall/, 'README documents skill uninstallation' );
    like( $doc, qr/dashboard skills update/, 'README documents skill updates' );
    like( $doc, qr/dashboard skill example-skill/, 'README documents isolated skill command dispatch' );
}
like( $release_doc, qr/dzil build/, 'release doc still documents the dzil build step' );
like( $release_doc, qr/cpanm .*Developer-Dashboard-1\.\d+\.tar\.gz/, 'release doc still documents tarball installation verification' );

done_testing();

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die $!;
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

sub _slurp_optional {
    my ($path) = @_;
    return '' if !-f $path;
    return _slurp($path);
}

sub _repo_path {
    return File::Spec->catfile( $ROOT, @_ );
}

sub _extract_pod {
    my ($content) = @_;
    return '' if $content !~ /\n__END__\n/s;
    $content =~ /\n__END__\n(.*)\z/s;
    return $1 // '';
}

__END__

=head1 NAME

15-release-metadata.t - verify release metadata and docs for private helpers and skills

=head1 DESCRIPTION

This test keeps the shipped version metadata, public executable list, and core
documentation aligned for the private-helper and isolated-skill packaging
model.

=cut
