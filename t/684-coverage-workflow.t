use strict;
use warnings FATAL => 'all';

use Capture::Tiny qw(capture);
use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use Test::More;
use YAML::XS ();

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $coverage_workflow = File::Spec->catfile( $ROOT, '.github', 'workflows', 'coverage.yml' );
my $platform_workflow = File::Spec->catfile( $ROOT, '.github', 'workflows', 'platform-compatibility.yml' );
my $pod_gate = File::Spec->catfile( $ROOT, 'script', 'pod-coverage-gate' );
my $markdown_gate = File::Spec->catfile( $ROOT, 'script', 'markdown-coverage-gate' );

plan skip_all => 'coverage workflow is source-tree-only' if !-f $coverage_workflow;

ok( -x $pod_gate || -f $pod_gate, 'POD coverage gate exists' );
ok( -x $markdown_gate || -f $markdown_gate, 'Markdown coverage gate exists' );

my $coverage = YAML::XS::LoadFile($coverage_workflow);
is_deeply(
    [ sort keys %{ $coverage->{jobs} || {} } ],
    [ qw(markdown-coverage pod-coverage test-coverage) ],
    'Coverage workflow exposes exactly the three requested coverage jobs',
);

my $coverage_text = _slurp($coverage_workflow);
like( $coverage_text, qr/perl\s+script\/coverage-gate/,
    'test coverage uses the canonical all-metric 100 percent gate' );
like( $coverage_text, qr/perl\s+script\/pod-coverage-gate/,
    'POD coverage uses the repository-wide POD gate' );
like( $coverage_text, qr/perl\s+script\/markdown-coverage-gate/,
    'Markdown coverage uses the repository-wide Markdown gate' );

my $platform_text = _slurp($platform_workflow);
like( $platform_text, qr/label:\s*Windows arm64.*?runner:\s*windows-11-arm/s,
    'Platform compatibility includes Windows ARM64 in the full test matrix' );
like( $platform_text, qr/strawberry-perl-5\.42\.3\.1-64bit-portable\.zip/,
    'Windows ARM64 uses the supported portable Strawberry Perl release' );
like( $platform_text, qr/6a081a811781c30aca51dbc036afd93092af91e3297901f02c17043795a10690/,
    'Windows ARM64 verifies the portable Strawberry Perl SHA256' );
like( $platform_text, qr/DD_RUNNER_ARCH:\s*\$\{\{ runner\.arch \}\}/,
    'platform architecture checks use the GitHub runner architecture' );
unlike( $platform_text, qr/native_perl=false|native_perl == 'true'/,
    'Windows ARM64 no longer skips the build and tests behind a native-Perl probe' );
unlike( $platform_text, qr/name:\s*Verify all-metric lib coverage/,
    'code coverage is owned by the dedicated Coverage workflow only' );

my $tmp = tempdir( CLEANUP => 1 );
my $good_pod = File::Spec->catfile( $tmp, 'good.t' );
my $bad_pod  = File::Spec->catfile( $tmp, 'bad.t' );
_write( $good_pod, "use strict;\n1;\n__END__\n\n=head1 NAME\n\ngood\n\n=cut\n" );
_write( $bad_pod, "use strict;\n1;\n" );

my ( $pod_ok_rc, $pod_ok_out ) = _run( $^X, $pod_gate, $good_pod );
is( $pod_ok_rc, 0, 'POD gate accepts a fully documented Perl source file' );
like( $pod_ok_out, qr/POD coverage:\s*1\/1\s*\(100\.0%\)/,
    'POD gate reports an explicit 100 percent result' );

my ( $pod_bad_rc, $pod_bad_out ) = _run( $^X, $pod_gate, $bad_pod );
isnt( $pod_bad_rc, 0, 'POD gate fails when a Perl source file has no POD' );
like( $pod_bad_out, qr/POD coverage:\s*0\/1\s*\(0\.0%\)/,
    'POD gate reports the failed coverage percentage' );

my $good_md = File::Spec->catfile( $tmp, 'good.md' );
my $bad_md  = File::Spec->catfile( $tmp, 'bad.md' );
_write( $good_md, "# Good\n\n```text\nok\n```\n" );
_write( $bad_md,  "# Bad\n\n```text\nnot closed\n" );

my ( $md_ok_rc, $md_ok_out ) = _run( $^X, $markdown_gate, $good_md );
is( $md_ok_rc, 0, 'Markdown gate accepts structurally valid Markdown' );
like( $md_ok_out, qr/Markdown coverage:\s*1\/1\s*\(100\.0%\)/,
    'Markdown gate reports an explicit 100 percent result' );

my ( $md_bad_rc, $md_bad_out ) = _run( $^X, $markdown_gate, $bad_md );
isnt( $md_bad_rc, 0, 'Markdown gate fails an unclosed fenced code block' );
like( $md_bad_out, qr/Markdown coverage:\s*0\/1\s*\(0\.0%\)/,
    'Markdown gate reports the failed coverage percentage' );

done_testing();

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return $text // q{};
}

sub _write {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content;
    close $fh or die "Unable to close $path: $!";
}

sub _run {
    my (@command) = @_;
    my ( $stdout, $stderr, $exit ) = capture {
        system @command;
        return $? >> 8;
    };
    return ( $exit, $stdout . $stderr );
}

__END__

=head1 NAME

t/684-coverage-workflow.t - protect the three 100 percent coverage gates

=head1 PURPOSE

Verify the dedicated Coverage workflow, its POD and Markdown gate behaviour, and
the Windows ARM64 platform matrix regression.

=head1 WHY IT EXISTS

Coverage ownership moved out of Platform compatibility at the same time the
Windows ARM64 job stopped being a skip-only native-Perl probe. Both changes are
easy to regress through workflow-only edits that ordinary unit tests cannot see.

=head1 WHEN TO USE

Run this test whenever changing coverage workflows, documentation gates, the
Windows ARM64 runner, or the Perl bootstrap used on that runner.

=head1 HOW TO USE

    prove -lv t/684-coverage-workflow.t

=head1 WHAT USES IT

The full repository test suite and Platform compatibility workflow execute this
regression test.

=head1 EXAMPLES

A valid workflow has exactly C<test-coverage>, C<pod-coverage>, and
C<markdown-coverage> jobs, and the Windows ARM64 matrix entry runs rather than
being conditional on a native ARM64 Perl binary.

=cut
