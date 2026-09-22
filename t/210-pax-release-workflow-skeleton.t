#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use YAML::XS qw(LoadFile);

my $path = '.github/workflows/pax-release.yml';

# AC-1: the workflow file exists and is valid YAML.
ok( -e $path, "$path exists" ) or BAIL_OUT("$path does not exist yet - nothing else in this file can run");

my $workflow = eval { LoadFile($path) };
ok( !$@, "$path parses as valid YAML" ) or diag("YAML parse error: $@");
BAIL_OUT('cannot continue without a parsed workflow') if !$workflow;

# AC-2: the trigger matches package-ghcr.yml's established push-to-master convention.
my $ghcr = LoadFile('.github/workflows/package-ghcr.yml');
is_deeply( $workflow->{on}{push}{branches}, $ghcr->{on}{push}{branches}, 'push.branches matches package-ghcr.yml' );
is_deeply( [ sort @{ $workflow->{on}{push}{tags} } ], [ sort @{ $ghcr->{on}{push}{tags} } ], 'push.tags matches package-ghcr.yml' );
ok( exists $workflow->{on}{workflow_dispatch}, 'workflow_dispatch trigger is present, matching package-ghcr.yml' );

# AC-3: the matrix strategy defines all 6 confirmed platform/arch entries with runs-on set.
my $job_names = [ keys %{ $workflow->{jobs} } ];
is( scalar @$job_names, 1, 'exactly one job carries the build matrix' );
my $job = $workflow->{jobs}{ $job_names->[0] };
my $matrix = $job->{strategy}{matrix}{include};
is( ref $matrix, 'ARRAY', 'matrix.include is an array' );
is( scalar @$matrix, 6, 'matrix defines exactly 6 platform/arch entries' );

my %seen_target;
for my $entry (@$matrix) {
    ok( $entry->{target}, "entry has a target name: " . ( $entry->{target} // '<missing>' ) );
    ok( $entry->{runs_on}, "entry $entry->{target} has runs_on set" );
    ok( $entry->{artifact_name}, "entry $entry->{target} has a distinct artifact_name" );
    $seen_target{ $entry->{target} }++;
}

my @expected_targets = qw(
    linux-amd64 linux-arm64 linux-i686
    macos-arm64
    windows-amd64 windows-arm64
);
is_deeply( [ sort keys %seen_target ], [ sort @expected_targets ], 'the 6 targets exactly match the owner-confirmed matrix' );

my %artifact_names = map { $_->{artifact_name} => 1 } @$matrix;
is( scalar keys %artifact_names, 6, 'all 6 artifact names are distinct' );

# AC-4: each matrix job has a placeholder step and an artifact-upload step.
my @steps = @{ $job->{steps} };
ok( ( grep { ( $_->{name} // '' ) =~ /placeholder/i } @steps ), 'a placeholder build step exists' );
ok( ( grep { ( $_->{uses} // '' ) =~ m{^actions/upload-artifact} } @steps ), 'an actions/upload-artifact step exists' );

done_testing();

__END__

=pod

=head1 NAME

210-pax-release-workflow-skeleton.t - proves DD-1012's PAX release workflow skeleton

=head1 PURPOSE

Guards DD-1012 (part of epic DDE-006): the new
C<.github/workflows/pax-release.yml> workflow must exist, parse as valid
YAML, trigger the same way C<package-ghcr.yml> already does, define all 6
owner-confirmed platform/arch matrix entries with a runner and a distinct
artifact name each, and give every matrix job a placeholder build step
plus an C<actions/upload-artifact> step ready for sibling tickets
(DD-1013/1014/1015) to wire real C<dashboard pax build> invocations into.

=head1 WHY IT EXISTS

Nothing else in this suite parses or validates C<.github/workflows/*.yml>
as structured YAML - C<t/15-release-metadata.t> only checks that
C<.github/workflows/test.yml> is correctly excluded from the release
tarball, which says nothing about a workflow file's own correctness. A
malformed or incomplete workflow file would otherwise only be discovered
by actually pushing to master and watching CI fail live.

=head1 WHEN TO USE

Run this file whenever C<.github/workflows/pax-release.yml> changes, or
whenever C<package-ghcr.yml>'s trigger convention changes (this file
compares against it directly rather than hardcoding a copy, so drift
between the two is caught automatically).

=head1 HOW TO USE

    prove -lv t/210-pax-release-workflow-skeleton.t

=head1 WHAT USES IT

C<.github/workflows/pax-release.yml> is not itself exercised by any other
test file in this suite.

=head1 EXAMPLES

A matrix entry looks like:

    - target: linux-amd64
      runs_on: ubuntu-latest
      artifact_name: d2-dashboard-linux-amd64

=cut
