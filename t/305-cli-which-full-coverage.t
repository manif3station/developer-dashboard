#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);

use lib 'lib';

use Developer::Dashboard::CLI::Which ();

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

my $missing = File::Spec->catdir( tempdir( CLEANUP => 1 ), 'no-such-hooks-dir' );
my $err = eval { Developer::Dashboard::CLI::Which::_runnable_hook_entries($missing); 1 } ? '' : $@;
like( $err, qr/Unable to read \Q$missing\E/, 'an unreadable or missing hook directory is reported' );

is_deeply( \@warnings, [], 'no warnings escaped' );

done_testing;

__END__

=pod

=head1 NAME

t/305-cli-which-full-coverage.t - hook directory failure coverage for CLI::Which

=head1 DESCRIPTION

Covers the opendir failure branch of the hook-entry scan in
L<Developer::Dashboard::CLI::Which>.

=cut
