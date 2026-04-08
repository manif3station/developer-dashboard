use strict;
use warnings FATAL => 'all';

use Capture::Tiny qw(capture);
use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );

my $node_bin = _find_command('node');
my $npm_bin  = _find_command('npm');

plan skip_all => 'JS fast-check fuzz test requires node and npm on PATH'
  if !$node_bin || !$npm_bin;

my $node_modules = File::Spec->catdir( $ROOT, 'node_modules' );
if ( !-d $node_modules ) {
    my ( $stdout, $stderr, $exit ) = capture {
        local %ENV = %ENV;
        $ENV{npm_config_audit} = 'false';
        $ENV{npm_config_fund}  = 'false';
        system( $npm_bin, 'ci', '--ignore-scripts' );
    };
    is( $exit, 0, 'npm ci prepares the fast-check dependency tree' )
      or diag($stdout), diag($stderr);
}

my ( $stdout, $stderr, $exit ) = capture {
    system( $npm_bin, 'run', 'fuzz:scorecard' );
};

is( $exit,   0,  'fast-check property tests pass' );
is( $stderr, '', 'fast-check property tests do not emit stderr' );
like( $stdout, qr/^>/m, 'npm run produced the expected script runner banner' );

done_testing;

sub _find_command {
    my ($name) = @_;
    for my $dir ( split /:/, ( $ENV{PATH} || '' ) ) {
        my $candidate = File::Spec->catfile( $dir, $name );
        return $candidate if -x $candidate;
    }
    return;
}

__END__

=pod

=head1 NAME

t/35-js-fast-check.t - run the Scorecard-targeted fast-check property suite

=head1 PURPOSE

This test runs the JavaScript C<fast-check> property suite that backs the
repository's Scorecard fuzzing signal.

=head1 WHY IT EXISTS

Scorecard only treats fuzzing as present when the repository carries a
recognized fuzz or property-based testing setup. This wrapper makes the
C<fast-check> suite part of the normal test discipline instead of leaving it as
an unverified workflow decoration.

=head1 WHEN TO USE

Run this test when changing the Scorecard workflows, the JavaScript property
test harness, or the dashboard encode/decode path that the fuzz suite covers.

=head1 HOW TO USE

Run it directly:

  prove -lv t/35-js-fast-check.t

If C<node> or C<npm> are missing, the test skips instead of failing the Perl
suite on hosts that do not provide JavaScript tooling.

=head1 WHAT USES IT

The full repository test suite, the GitHub Actions fuzz workflow, and local TDD
when changing the Scorecard hardening layer.

=head1 EXAMPLES

  prove -lv t/35-js-fast-check.t

  npm run fuzz:scorecard

The first command exercises the Perl wrapper that prepares dependencies when
needed. The second runs the property suite directly through npm.

=cut

