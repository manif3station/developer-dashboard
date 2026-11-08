use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempfile);
use FindBin qw($RealBin);
use Test::More;

my $root = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $selector = File::Spec->catfile( $root, 'script', 'select-ci-platforms' );

ok( -f $selector, 'the platform selection script is present' );

# select_for($message)
# Purpose: execute the exact script used by the GitHub Actions selector.
# Input: a complete single-commit message.
# Output: its exit status, output mapping, and raw output.
sub select_for {
    my ($message) = @_;
    my ( $fh, $filename ) = tempfile( UNLINK => 1 );
    print {$fh} $message or die "Could not write commit message: $!";
    close $fh or die "Could not close commit message: $!";

    open my $pipe, '-|', $^X, $selector, $filename
      or die "Could not launch the selector: $!";
    my $output = do { local $/; <$pipe> };
    # A nonzero child exit makes close return false, but still stores its
    # wait status in $?. Expected rejection cases must inspect that status.
    close $pipe;
    my $exit_code = $? >> 8;
    my %values = map { split /=/, $_, 2 }
      grep { length $_ } split /\n/, $output;
    return ( $exit_code, \%values, $output );
}

my @platforms = qw(mac ubuntu_amd64 ubuntu_arm64 win_amd64 win_arm64);
sub expected {
    my (@selected) = @_;
    my %wanted = map { $_ => 1 } @selected;
    return { map { $_ => ( $wanted{$_} ? 'true' : 'false' ) } @platforms };
}

my ( $status, $outputs ) = select_for("fix: an ordinary change\n\nNo CI tags.\n");
is( $status, 0, 'untagged messages are accepted' );
is_deeply( $outputs, expected(@platforms), 'untagged commits run all five stages' );

( $status, $outputs ) = select_for("fix: Mac integration [win-amd64]\n");
is( $status, 0, 'one tag is accepted' );
is_deeply( $outputs, expected('win_amd64'), 'a middle-stage tag skips its prerequisites' );

( $status, $outputs ) = select_for("test: only ARM [ubuntu-arm64] [win-arm64]\n");
is( $status, 0, 'multiple bracket tags are accepted' );
is_deeply( $outputs, expected(qw(ubuntu_arm64 win_arm64)),
    'nonadjacent stages can be selected without intermediate stages' );

( $status, $outputs ) = select_for("fix: local macOS\n\nCI-Platforms: MAC, win-arm64\n");
is( $status, 0, 'comma-separated trailer is accepted' );
is_deeply( $outputs, expected(qw(mac win_arm64)),
    'explicit CI-Platforms trailer selects just its listed stages' );

( $status, $outputs ) = select_for("fix: Windows package\n\n[win-amd64]\nCI-Platforms: ubuntu-amd64\n");
is( $status, 0, 'the two tag formats can be combined' );
is_deeply( $outputs, expected(qw(ubuntu_amd64 win_amd64)),
    'combined formats produce the union of selected stages' );

( $status, $outputs ) = select_for("docs: macOS and Windows updates\n");
is( $status, 0, 'prose platform names are not mistaken for tags' );
is_deeply( $outputs, expected(@platforms), 'plain words do not turn off coverage' );

( $status, $outputs ) = select_for("docs: CI-Platforms: explained in prose\n\nNormal body.\n");
is( $status, 0, 'a platform-looking phrase in the subject is not a trailer' );
is_deeply( $outputs, expected(@platforms), 'subject prose keeps default full coverage' );

( $status, $outputs ) = select_for("docs: explain syntax\n\nCI-Platforms: not-a-platform\n\nThis later paragraph is ordinary prose.\n");
is( $status, 0, 'platform-looking prose in a nonfinal paragraph is ignored' );
is_deeply( $outputs, expected(@platforms), 'an earlier paragraph cannot override coverage' );

( $status, $outputs ) = select_for("docs: explain syntax\n\nCI-Platforms: not-a-platform\nThis explanatory line makes it prose.\n");
is( $status, 0, 'a non-trailer final paragraph is not parsed as tags' );
is_deeply( $outputs, expected(@platforms), 'free-form prose cannot skip coverage stages' );

( $status, $outputs ) = select_for("fix: test\n\nSigned-off-by: Example Maintainer\nCI-Platforms: win-amd64\n");
is( $status, 0, 'the final paragraph may contain standard Git trailers' );
is_deeply( $outputs, expected('win_amd64'), 'CI-Platforms is recognized beside other trailers' );

( $status, $outputs ) = select_for("fix: test\n\nCI-Platforms: win-amd6\n");
isnt( $status, 0, 'unknown explicit trailer platform is rejected' );

( $status, $outputs ) = select_for("fix: test\n\nCI-Platforms:\n");
isnt( $status, 0, 'empty explicit trailer is rejected' );

done_testing();

__END__

=head1 NAME

228-ci-platform-selection.t - verify opt-in commit platform tags

=head1 PURPOSE

Exercise the actual CI selection script so that single-platform, nonadjacent
multi-platform, and untagged defaults cannot silently change.

=head1 WHY IT EXISTS

A targeted coverage run must not be blocked by skipped earlier platforms, and
a typo in an explicit selector must not silently switch back to the full chain.
This test checks the tag parser without requiring hosted runner minutes.

=head1 WHEN TO USE

Run after changing platform selectors or the commit-message tag grammar.

=head1 HOW TO USE

    prove -lv t/228-ci-platform-selection.t

=head1 WHAT USES IT

Developers, the complete repository test suite and the five-platform coverage
jobs use this regression to keep commit-message platform selection stable.

=head1 EXAMPLES

The C<[win-amd64]> tag selects Windows amd64 without macOS or Linux. An
untagged commit selects the full original chain.

=cut
