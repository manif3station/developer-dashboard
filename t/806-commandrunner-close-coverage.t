#!/usr/bin/env perl
use strict;
use warnings;

# A scoped open redirect must be installed before CommandRunner is compiled:
# the production code deliberately uses CORE::close rather than a hookable
# close, so a pipe whose child exits nonzero gives a real close failure.
our $BROKEN_PID_FILE = 'fixture-command-close-failure.pid';

BEGIN {
    *CORE::GLOBAL::open = sub (*;$@) {
        if (@_ >= 3 && defined $_[2] && !ref $_[2]
            && $_[1] eq '>' && $_[2] eq $BROKEN_PID_FILE) {
            return CORE::open( $_[0], '|-', $^X, '-e',
                'while (<STDIN>) {} exit 7;' );
        }
        return CORE::open( $_[0], $_[1] ) if @_ == 2;
        return CORE::open( $_[0], $_[1], @_[2 .. $#_] );
    };
}

use Test::More;
use lib 'lib';
use Developer::Dashboard::CommandRunner ();

my $ok = eval {
    Developer::Dashboard::CommandRunner::record_command_pid(
        $BROKEN_PID_FILE, 4242
    );
    1;
};
ok( !$ok, 'record_command_pid rejects a failed descriptor close' );
like( $@, qr/Unable to close collector command pid file/,
    'record_command_pid reports the close failure with its pidfile context' );

done_testing;
