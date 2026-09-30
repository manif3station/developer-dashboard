#!/usr/bin/env perl

use strict;
use warnings;

use Capture::Tiny qw(capture);
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use Developer::Dashboard::CLI::Skills ();

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";

# run_cli(@argv)
# Runs one skills helper command with stdout and stderr captured.
# Input: argv list following the command name.
# Output: hash reference with exit code, stdout and stderr.
sub run_cli {
    my (@argv) = @_;
    my $exit;
    my ( $stdout, $stderr ) = capture {
        $exit = Developer::Dashboard::CLI::Skills::run_skills_command( command => 'skills', args => [@argv] );
    };
    return { exit => $exit, stdout => $stdout, stderr => $stderr };
}

is( run_cli( 'install', '--branch', 'main' )->{exit}, 2, 'the long --branch form without a source reports usage' );
is( run_cli( 'install', '--branch', '--notest', 'alpha' )->{exit}, 2, '--branch followed by another option reports usage' );
is( run_cli( 'install', '-b', '-o', 'json' )->{exit}, 2, '-b followed by another option reports usage' );

my $unknown = run_cli( 'install', '--definitely-not-an-option' );
is( $unknown->{exit}, 2, 'an unknown install option reports usage' );
like( $unknown->{stdout} . $unknown->{stderr}, qr/Usage: dashboard skills install/, 'the usage text is printed' );

is_deeply( \@warnings, [], 'no warnings escaped' );

done_testing;

__END__

=pod

=head1 NAME

t/302-cli-skills-full-coverage.t - install option-parsing condition coverage for CLI::Skills

=head1 DESCRIPTION

Covers the C<--branch> long form, a branch flag followed by another option, and
GetOptions failures in C<dashboard skills install> option validation.

=cut
