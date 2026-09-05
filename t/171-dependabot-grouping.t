#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Spec;
use YAML::XS ();

# Purpose: prove .github/dependabot.yml groups the codeql-action family into one
#          pull request.
# Input:   the repository's .github/dependabot.yml
# Output:  test results; fails when the grouping is absent or too narrow to cover
#          every codeql-action path.

my $config_path = File::Spec->catfile( '.github', 'dependabot.yml' );

plan skip_all => "no $config_path in this tree" if !-f $config_path;
plan tests => 6;

# Purpose: read and parse the dependabot configuration.
# Input:   $path - the configuration file
# Output:  the parsed structure, or undef when it cannot be read
sub _load_config {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $text = do { local $/; <$fh> };
    close $fh;
    return YAML::XS::Load($text);
}

# Purpose: turn one dependabot pattern into a regex, so a pattern can be tested
#          against the literal paths it must cover rather than eyeballed.
# Input:   $pattern - a dependabot group pattern, '*' being the only wildcard
# Output:  a compiled regex matching the whole string
sub _pattern_to_regex {
    my ($pattern) = @_;
    my $escaped = join '.*', map { quotemeta } split /\*/, $pattern, -1;
    return qr/\A$escaped\z/;
}

my $config = _load_config($config_path);
ok( $config, 'dependabot.yml parses as YAML' );

my ($actions) = grep { ( $_->{'package-ecosystem'} // '' ) eq 'github-actions' }
    @{ $config->{updates} || [] };
ok( $actions, 'a github-actions update entry exists' );

# THE DEFECT THIS GUARDS (DD-741). CodeQL refuses to run unless init, autobuild
# and analyze use the SAME version. Dependabot opens one pull request per action
# PATH, so without grouping each PR moves one step and strands the other two -
# every PR then fails with "Loaded a configuration file for version X, but
# running version Y", and none can pass alone. It happened three times before
# this test existed: 4.37.6->4.37.7, 4.37.7->4.37.8, 4.37.8->4.37.9.
ok( $actions->{groups},
    'the github-actions entry declares groups, so a version-locked action family can arrive as ONE pull request' );

my @patterns = map { @{ $_->{patterns} || [] } } values %{ $actions->{groups} || {} };
ok( scalar(@patterns), 'at least one group carries patterns' );

# EVERY path, not merely one. The whole defect is three paths being treated
# separately, so a pattern covering two of them reproduces it more quietly.
my @required = qw(
    github/codeql-action/init
    github/codeql-action/autobuild
    github/codeql-action/analyze
);
my @uncovered = grep {
    my $path = $_;
    !grep { $path =~ _pattern_to_regex($_) } @patterns;
} @required;
is_deeply( \@uncovered, [],
    'every codeql-action path used by the workflow is covered by a group pattern' );

# The canonical example uses '*', which would group EVERY action update into one
# pull request - broader than this defect needs, and it makes one failing update
# block the whole batch. DD-741 chose to group the family, not everything.
my @blanket = grep { $_ eq '*' } @patterns;
is_deeply( \@blanket, [],
    'the grouping targets the action family rather than a blanket wildcard over every action' );

__END__

=head1 NAME

t/171-dependabot-grouping.t - guard the dependabot grouping that keeps a
version-locked action family updatable

=head1 DESCRIPTION

Asserts that the github-actions entry in the repository's dependabot
configuration groups the codeql-action family into a single pull request, and
that the grouping covers every action path the CodeQL workflow calls.

=head1 PURPOSE

To stop a defect returning that has already arrived three times. CodeQL requires
its init, autobuild and analyze steps to run the same version. Dependabot
proposes one pull request per action path, so without a grouping rule each pull
request moves one step and leaves the others behind, and every one of them fails
the version check. Grouping makes the family arrive as one pull request that can
actually pass.

=head1 WHY IT EXISTS

The grouping is a single block in a configuration file that nothing else reads.
An edit, a rewritten file, or a merge conflict resolved the wrong way would
remove it silently, and the loss would only surface the next time the action
family published a release - as three red pull requests that nobody could merge.
This test converts that silence into a failing suite.

=head1 WHEN TO USE

It runs with the full suite. Consult it directly when changing
F<.github/dependabot.yml>, when adding an action family whose steps must share a
version, or when dependency pull requests start failing on a version mismatch.

=head1 HOW TO USE

    prove -l t/171-dependabot-grouping.t

The test skips when the configuration file is absent, so a checkout without it
reports honestly rather than failing for the wrong reason.

=head1 WHAT USES IT

The full test suite, and the release gates that depend on it being green. No
production code loads this file.

=head1 EXAMPLES

A configuration satisfying it:

    - package-ecosystem: "github-actions"
      directory: "/"
      schedule:
        interval: "weekly"
      groups:
        codeql-action:
          patterns:
            - "github/codeql-action*"

Removing the C<groups> block, or narrowing the pattern so it no longer covers
C<github/codeql-action/analyze>, makes this test fail.

=cut
