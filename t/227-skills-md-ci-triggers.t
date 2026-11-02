use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;
use YAML::XS ();

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $WORKFLOWS = File::Spec->catdir( $ROOT, '.github', 'workflows' );

plan skip_all => 'workflow YAML files are excluded from the built distribution'
  if !-d $WORKFLOWS;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh or die "Unable to close $path: $!";
    return $content // '';
}

sub trigger_block {
    my ($workflow_file) = @_;
    my $doc = YAML::XS::LoadFile( File::Spec->catfile( $WORKFLOWS, $workflow_file ) );
    my ($block) = grep { ref $_ eq 'HASH' }
      map { $doc->{$_} } grep { m/\A(?:on|true|1)\z/ } keys %$doc;
    return $block // {};
}

opendir my $workflow_dir, $WORKFLOWS
  or die "Unable to read workflow directory $WORKFLOWS: $!";
my @workflow_files = sort grep { /\.ya?ml\z/ && -f File::Spec->catfile( $WORKFLOWS, $_ ) }
  readdir $workflow_dir;
closedir $workflow_dir or die "Unable to close workflow directory $WORKFLOWS: $!";

is_deeply(
    \@workflow_files,
    [ qw(coverage.yml dockerhub-image.yml platform-compatibility.yml release-github.yml) ],
    'the repository exposes exactly the four owner-approved GitHub Actions workflows',
);

for my $removed (qw(test.yml codeql.yml package-ghcr.yml fuzz-js.yml)) {
    ok( !-e File::Spec->catfile( $WORKFLOWS, $removed ),
        "$removed is removed from the active workflow directory" );
}

my %triggers = map { $_ => trigger_block($_) } @workflow_files;

for my $workflow (qw(platform-compatibility.yml coverage.yml)) {
    ok( exists $triggers{$workflow}{push},
        "$workflow runs on push" );
    is_deeply(
        $triggers{$workflow}{push}{branches},
        ['master'],
        "$workflow push runs are scoped to master",
    );
    ok( exists $triggers{$workflow}{pull_request},
        "$workflow also runs on pull requests" );
    ok( !exists $triggers{$workflow}{workflow_dispatch},
        "$workflow has no duplicate manual verification path" );
}

ok( exists $triggers{'release-github.yml'}{push},
    'GitHub Release runs on tag pushes' );
is_deeply(
    $triggers{'release-github.yml'}{push}{tags},
    ['v*'],
    'GitHub Release is scoped to version tags',
);
ok( exists $triggers{'release-github.yml'}{workflow_dispatch},
    'GitHub Release keeps its recovery dispatch path' );
ok( !exists $triggers{'release-github.yml'}{pull_request},
    'GitHub Release does not run on pull requests' );

ok( exists $triggers{'dockerhub-image.yml'}{push},
    'Docker Hub publishing runs on push' );
is_deeply(
    $triggers{'dockerhub-image.yml'}{push}{branches},
    ['master'],
    'Docker Hub publishing is scoped to master pushes',
);
ok( exists $triggers{'dockerhub-image.yml'}{workflow_dispatch},
    'Docker Hub publishing keeps manual dispatch' );
ok( !exists $triggers{'dockerhub-image.yml'}{pull_request},
    'Docker Hub publishing does not run on pull requests' );

my $platform = YAML::XS::LoadFile(
    File::Spec->catfile( $WORKFLOWS, 'platform-compatibility.yml' ) );
my @setup_perl_steps = map { @{ $_->{steps} || [] } }
  grep { ref $_ eq 'HASH' } values %{ $platform->{jobs} || {} };
@setup_perl_steps = grep { ($_->{uses} // '') =~ /actions-setup-perl\@/ } @setup_perl_steps;
ok( @setup_perl_steps, 'Platform compatibility configures Perl explicitly' );
ok( !scalar grep { !$_->{with}{'multi-thread'} } @setup_perl_steps,
    'every Platform compatibility setup-perl step enables ithreads for GoRoutine XS' );

my $platform_text = _slurp(
    File::Spec->catfile( $WORKFLOWS, 'platform-compatibility.yml' ) );
like( $platform_text, qr/libayatana-appindicator3-dev/,
    'Platform compatibility installs Ayatana development headers on Linux' );
like( $platform_text, qr/libgtk-3-dev/,
    'Platform compatibility installs GTK development headers on Linux' );
like( $platform_text, qr/label:\s*Windows arm64.*?runner:\s*windows-11-arm/s,
    'Platform compatibility runs the full suite on the Windows ARM64 host' );
like( $platform_text, qr/choco install strawberryperl --version=5\.42\.3\.1/,
    'Windows ARM64 receives a supported Perl instead of the image Perl 5.32' );
unlike( $platform_text, qr/native_perl=false|native_perl == 'true'/,
    'Windows ARM64 no longer skips work behind a native-Perl availability flag' );
like( $platform_text, qr/name:\s*Run fast-check property tests/,
    'Platform compatibility owns the property-test gate formerly provided by JS Fuzz' );
like( $platform_text, qr/name:\s*Audit declared dependency chain \(RELEASE GATE\)/,
    'Platform compatibility owns the declared dependency audit release gate' );
unlike( $platform_text, qr/name:\s*Verify all-metric lib coverage/,
    'Platform compatibility leaves coverage to the dedicated Coverage workflow' );

my $coverage_text = _slurp(
    File::Spec->catfile( $WORKFLOWS, 'coverage.yml' ) );
like( $coverage_text, qr/name:\s*Test coverage 100%/,
    'Coverage workflow exposes the 100 percent test coverage verdict' );
like( $coverage_text, qr/name:\s*POD coverage 100%/,
    'Coverage workflow exposes the 100 percent POD coverage verdict' );
like( $coverage_text, qr/name:\s*Markdown coverage 100%/,
    'Coverage workflow exposes the 100 percent Markdown coverage verdict' );

my $skills = _slurp( File::Spec->catfile( $ROOT, 'SKILLS.md' ) );
for my $name ( 'Platform compatibility', 'Coverage', 'GitHub Release', 'Publish Docker Hub Image' ) {
    like( $skills, qr/\Q$name\E/i, "SKILLS.md names the retained $name workflow" );
}
unlike( $skills, qr/\b(?:CodeQL|Package GHCR|JS Fuzz)\b/,
    'SKILLS.md no longer advertises removed workflows as current CI' );

my $trigger_doc = _slurp( File::Spec->catfile( $ROOT, 'docs', 'ci-workflow-triggers.md' ) );
for my $file (qw(coverage.yml platform-compatibility.yml release-github.yml dockerhub-image.yml)) {
    like( $trigger_doc, qr/\Q$file\E/, "workflow trigger documentation includes $file" );
}
like( $trigger_doc, qr/^## Removed workflows\s*$/m,
    'workflow trigger documentation explicitly separates retired workflow names from the active set' );
for my $file (qw(test.yml codeql.yml package-ghcr.yml fuzz-js.yml)) {
    like( $trigger_doc, qr/^- `\Q$file\E`\s*$/m,
        "workflow trigger documentation records $file as deliberately removed" );
}

done_testing();

__END__

=head1 NAME

227-skills-md-ci-triggers.t - protect the four-workflow GitHub Actions contract

=head1 DESCRIPTION

Checks the active workflow directory, trigger sets, platform compatibility
matrix, dedicated coverage gates, and public CI documentation.

=head1 PURPOSE

Keep the repository from silently reintroducing duplicate Test, CodeQL, GHCR, or
standalone JavaScript fuzz workflows while preserving the explicitly requested
Coverage workflow alongside platform testing and publishing.

=head1 WHY IT EXISTS

Workflow files are executable configuration. Removing or adding a YAML file in
one place is not enough if tests or documentation still describe a different
Actions surface.

=head1 WHEN TO USE

Run this test whenever adding, deleting, renaming, or changing triggers in
F<.github/workflows/>, or when changing the CI description in C<SKILLS.md> or
the workflow trigger reference.

=head1 HOW TO USE

  prove -lv t/227-skills-md-ci-triggers.t

=head1 WHAT USES IT

The repository test suite and Platform compatibility workflow use this test to
enforce the owner-approved four-workflow layout.

=head1 EXAMPLES

Check just the workflow contract:

  prove -lv t/227-skills-md-ci-triggers.t

Check it as part of the full platform suite:

  prove -lr t

=cut
