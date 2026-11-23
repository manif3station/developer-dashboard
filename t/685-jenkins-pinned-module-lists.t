use strict;
use warnings FATAL => 'all';

use Cwd qw(abs_path);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );

# Purpose: read one pinned list exactly as it is stored.
# Input: file name under share/jenkins.
# Output: the raw file content, or an empty string when the file is missing.
sub _slurp_raw {
    my ($name) = @_;
    my $path = File::Spec->catfile( $ROOT, 'share', 'jenkins', $name );
    return q{} if !-f $path;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    binmode $fh;
    my $content = do { local $/; <$fh> };
    close $fh or die "Unable to close $path after reading: $!";
    return defined $content ? $content : q{};
}

# Purpose: split raw list content into its lines without hiding blank ones.
# Input: raw file content.
# Output: list of lines, line endings removed, a final empty field dropped.
sub _lines {
    my ($content) = @_;
    my @lines = split /\n/, $content, -1;
    pop @lines if @lines && $lines[-1] eq q{};
    return @lines;
}

# One CPAN distribution file: first letter, first two letters, author, file.
my $entry_shape = qr{\A([A-Z])/([A-Z]{2})/([A-Z][A-Z0-9-]*)/[A-Za-z0-9_.-]+-v?[0-9][0-9._]*\.tar\.gz\z};

# Anything that would name a machine, a person or a place on a disk.
my $private_shape = qr{
      \b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b    # an IP address
    | ://                                       # a URL with a host name
    | @                                         # user at host
    | \\                                        # a Windows path
    | \A/                                       # an absolute path
    | ~                                         # a home shorthand
    | (?:\A|/)(?:home|Users|root)(?:/|\z)       # a home folder
    | \$                                        # a variable
}xi;

my %expected_count = (
    'modules-unix.txt'             => 119,
    'modules-compiled.txt'         => 20,
    'modules-windows.txt'          => 118,
    'modules-compiled-windows.txt' => 19,
);

my %list;
for my $name ( sort keys %expected_count ) {
    my $path    = File::Spec->catfile( $ROOT, 'share', 'jenkins', $name );
    my $content = _slurp_raw($name);
    my @lines   = _lines($content);
    $list{$name} = \@lines;

    ok( -f $path, "share/jenkins/$name exists" );
    is( scalar(@lines), $expected_count{$name}, "share/jenkins/$name holds $expected_count{$name} entries" );
    ok(
        $content =~ /[^\n]\n\z/ && $content !~ /\r/,
        "share/jenkins/$name ends with one line feed and has no carriage returns",
    );

    my @padded = grep { $_ eq q{} || /\A\s/ || /\s\z/ || /\s/ } @lines;
    is_deeply( \@padded, [], "share/jenkins/$name has no blank line and no white space in any line" );

    my %seen;
    my @duplicates = grep { $seen{$_}++ == 1 } @lines;
    is_deeply( \@duplicates, [], "share/jenkins/$name names no distribution twice" );

    my @misshapen = grep {
        my $ok = 0;
        if ( $_ =~ $entry_shape ) {
            my ( $first, $two, $author ) = ( $1, $2, $3 );
            $ok = 1 if substr( $author, 0, 1 ) eq $first && substr( $author, 0, 2 ) eq $two;
        }
        !$ok;
    } @lines;
    is_deeply( \@misshapen, [], "every line of share/jenkins/$name is one CPAN distribution file under its author" );

    my @private = grep { $_ =~ $private_shape } @lines;
    is_deeply( \@private, [],
        "share/jenkins/$name holds no IP address, host name, user name or home path" );
}

my @unix             = @{ $list{'modules-unix.txt'} };
my @compiled         = @{ $list{'modules-compiled.txt'} };
my @windows          = @{ $list{'modules-windows.txt'} };
my @compiled_windows = @{ $list{'modules-compiled-windows.txt'} };

my %in_unix    = map { $_ => 1 } @unix;
my %in_windows = map { $_ => 1 } @windows;

is_deeply( [ grep { !$in_unix{$_} } @compiled ], [],
    'every compiled distribution is in the Unix pinned list' );
is_deeply( [ grep { !$in_windows{$_} } @compiled_windows ], [],
    'every Windows compiled distribution is in the Windows pinned list' );

my @coverage = grep { m{/Devel-Cover-[0-9]} } @unix;
is( scalar(@coverage), 1, 'the Unix pinned list names Devel::Cover exactly once' );
is_deeply( [ grep { m{/Devel-Cover-[0-9]} } @windows, @compiled_windows ], [],
    'the Windows lists leave Devel::Cover out' );
is_deeply(
    \@windows,
    [ grep { $_ !~ m{/Devel-Cover-[0-9]} } @unix ],
    'the Windows pinned list is the Unix pinned list less Devel::Cover, in the same order',
);

done_testing();

__END__

=head1 NAME

t/685-jenkins-pinned-module-lists.t - protect the pinned module lists for Jenkins test nodes

=head1 PURPOSE

Verify that the four plain-text lists under the share folder for Jenkins test
nodes are well formed: the right number of entries, no duplicates, no blank or
padded lines, every entry one CPAN distribution file, the compiled lists inside
their full lists, and the Windows list equal to the Unix list less Devel::Cover.

=head1 WHY IT EXISTS

A Jenkins test node is only the same as the others when it installs exactly the
same distribution files in the same order. The lists are data, so nothing else
would notice a dropped line, a doubled line, a stray space or a private detail
such as an address or a home path slipping into a public file.

=head1 WHEN TO USE

Run this test whenever a distribution is added to, removed from or moved within
any of the pinned lists, and whenever the Windows set is changed.

=head1 HOW TO USE

    prove -lv t/685-jenkins-pinned-module-lists.t

=head1 WHAT USES IT

The full repository test suite runs this test on every platform. The Jenkins
test-node setup reads the same list files when it installs a node.

=head1 EXAMPLES

The Unix list must hold 119 entries and the Windows list 118. Removing the
Devel::Cover line from the Unix list must give the Windows list exactly, line
for line.

=cut
