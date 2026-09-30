#!/usr/bin/env perl

use strict;
use warnings;

# Paths whose read-open should fail even for a privileged user, so the
# "Unable to read" branch of the manifest reader can be driven hermetically.
our %FAIL_OPEN;

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::open = sub (*;$@) {
        if ( @_ >= 3 && defined $_[2] && exists $FAIL_OPEN{ $_[2] } ) {
            $! = 13;
            return 0;
        }
        return CORE::open( $_[0], $_[1] )                 if @_ == 2;
        return CORE::open( $_[0], $_[1], @_[ 2 .. $#_ ] ) if @_ >= 3;
        return CORE::open( $_[0] );
    };
}

use Test::More;
use File::Temp qw(tempdir);

use lib 'lib';

use Developer::Dashboard::CLI::SeededPages;

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;

my $SP = 'Developer::Dashboard::CLI::SeededPages';

{

    package Test::SP301::Paths;

    # new(%args)
    # Minimal path registry exposing only config_root.
    # Input: root directory string.
    # Output: stub object.
    sub new { my ( $class, %a ) = @_; return bless {%a}, $class }

    # config_root()
    # Returns the configured root directory.
    # Input: none.
    # Output: directory string.
    sub config_root { return $_[0]{root} }
}

subtest 'stub helpers that ship no seeded pages' => sub {
    my $err = eval { $SP->can('page_for_id')->('whatever'); 1 } ? '' : $@;
    like( $err, qr/Unknown seeded page id 'whatever'/, 'page_for_id rejects every id' );
    is_deeply( [ $SP->can('known_managed_page_md5s')->('whatever') ], [], 'no managed md5s are shipped' );
};

subtest 'manifest reader and writer guards' => sub {
    my $paths    = Test::SP301::Paths->new( root => $home );
    my $manifest = $SP->can('seed_manifest_path')->( paths => $paths );

    my $err = eval { Developer::Dashboard::CLI::SeededPages::_write_manifest( paths => $paths, manifest => [] ); 1 } ? '' : $@;
    like( $err, qr/Missing seeded page manifest hash/, 'a non-hash manifest is refused' );

    Developer::Dashboard::CLI::SeededPages::_write_manifest( paths => $paths, manifest => { a => 1 } );
    is_deeply( Developer::Dashboard::CLI::SeededPages::_read_manifest( paths => $paths ), { a => 1 }, 'written manifest reads back' );

    local $FAIL_OPEN{$manifest} = 1;
    $err = eval { Developer::Dashboard::CLI::SeededPages::_read_manifest( paths => $paths ); 1 } ? '' : $@;
    like( $err, qr/Unable to read \Q$manifest\E/, 'an unreadable manifest is reported' );
};

is_deeply( \@warnings, [], 'no warnings escaped' );

done_testing;

__END__

=pod

=head1 NAME

t/301-cli-seededpages-full-coverage.t - remaining branch coverage for CLI::SeededPages

=head1 DESCRIPTION

Covers the stub seeded-page helpers, the non-hash manifest guard in the writer,
and the unreadable-manifest branch of the reader (driven through an C<open>
override so it also fails for privileged users).

=cut
