use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Find qw(find);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my @offenders;

find(
    {
        no_chdir => 1,
        wanted   => sub {
            return if !-f $_ || $_ !~ /\.pm\z/;

            open my $fh, '<', $_ or die "Unable to read $_: $!";
            while ( my $line = <$fh> ) {
                push @offenders, File::Spec->abs2rel( $_, $ROOT ) . ":$."
                  if $line =~ /grep\s*\{\s*defined\s*&&\s*\$_\s+ne\s+''\s*\}\s*split\b/;
            }
            close $fh or die "Unable to close $_: $!";
        },
    },
    File::Spec->catdir( $ROOT, 'lib' ),
);

is_deeply(
    \@offenders,
    [],
    'split-derived grep filters do not retain a redundant defined check',
);

done_testing;

__END__

=pod

=head1 NAME

81-defined-grep-cleanup.t - enforce concise filters for split-derived fields

=head1 PURPOSE

This source-policy test finds Perl module lines that filter the direct output of
C<split> with both C<defined> and a non-empty-string comparison. Perl C<split>
returns defined strings, so those guards add an unreachable branch without
changing the resulting list.

=head1 WHY IT EXISTS

A broader cleanup previously removed C<defined> from filters whose inputs could
legitimately contain undefined values. This narrower contract distinguishes the
safe, split-derived cases from argument, environment, and hash-derived lists
where preserving C<defined> remains necessary for warning-free behavior.

=head1 WHEN TO USE

Run this test when editing list normalization, route parsing, path parsing,
colon-separated environment variables, or coverage annotations around Perl
C<split> expressions. Use it before applying mechanical grep-filter cleanup so
only expressions with guaranteed-defined inputs are changed.

=head1 HOW TO USE

Run C<prove -lv t/81-defined-grep-cleanup.t> for the focused source-policy
check. A failure reports every module and line that still combines C<defined>
with C<< $_ ne '' >> immediately around direct C<split> output. Review each
reported expression to confirm that C<split> is the actual list producer, then
remove only the redundant check and its obsolete coverage annotation. Follow
with the affected module tests and C<prove -lr t>.

=head1 WHAT USES IT

Developers performing safe condition cleanup, the repository test suite, and
the release metadata gate use this file. It protects the distinction between
split-derived values and caller-provided values that may remain undefined.

=head1 EXAMPLES

Example 1:

  prove -lv t/81-defined-grep-cleanup.t

Run the focused policy test and inspect any reported module-line pairs.

Example 2:

  prove -lr t

Run the full suite after the focused check passes to verify warning-free
behavior across callers that may supply undefined values.

=cut
