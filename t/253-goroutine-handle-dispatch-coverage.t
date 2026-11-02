#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use Symbol qw(gensym);

use lib 'lib';
use Developer::Dashboard::GoRoutine;

{
    package Local::GoRoutine::FalsePrintHandle;

    # TIEHANDLE creates a harmless tied handle for dispatcher failure testing.
    # Input: class name; output: a tied-handle object.
    sub TIEHANDLE {
        my ($class) = @_;
        return bless {}, $class;
    }

    # PRINT deliberately reports a failed write without emitting a warning.
    # Input: tied-handle object and print arguments; output: false status.
    sub PRINT {
        return 0;
    }
}

package main;

my ( $handle, $path ) = tempfile( UNLINK => 1 );
binmode $handle or die "Could not set the temporary handle to raw mode: $!";

ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'PRINT', "first\n" ),
    'PRINT writes through the remote-handle dispatcher' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'PRINTF', "%s:%d\n", 'second', 2 ),
    'PRINTF preserves formatting arguments' );

is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'SEEK', 0, 0 ),
    1, 'SEEK returns the underlying seek result' );
is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'READLINE_SCALAR' ),
    "first\n", 'READLINE_SCALAR returns one line' );
is_deeply(
    [ Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
            $handle, 'READLINE_LIST' ) ],
    [ "second:2\n" ], 'READLINE_LIST returns remaining lines in list context' );

is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'SEEK', 0, 0 ),
    1, 'SEEK rewinds before GETC' );
is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'GETC' ),
    'f', 'GETC returns one character' );

Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
    $handle, 'SEEK', 0, 0 );
my ( $list_read, $list_buffer ) =
    Developer::Dashboard::GoRoutine::_handle_remote_dispatch( $handle, 'READ', 3 );
is( $list_read, 3, 'list-context READ reports the byte count' );
is( $list_buffer, 'fir', 'list-context READ returns the populated buffer' );

Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
    $handle, 'SEEK', 0, 0 );
my $scalar_read = scalar Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
    $handle, 'READ', 2 );
is( $scalar_read, 2, 'scalar-context READ reports only the byte count' );

ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'BINMODE', ':raw' ),
    'BINMODE accepts an explicit layer' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'BINMODE' ),
    'BINMODE without a layer preserves Perl defaults' );

Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
    $handle, 'SEEK', 2, 0 );
is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'TELL' ),
    2, 'TELL returns the current file position' );
ok( defined Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'FILENO' ),
    'FILENO exposes the underlying descriptor' );

is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'SEEK', 15, 0 ),
    1, 'SEEK reaches the known end of the fixture' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'EOF' ),
    'EOF reports the consumed file end' );

Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
    $handle, 'SEEK', 2, 0 );
is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'WRITE', '--tag', 3, 2 ),
    3, 'WRITE applies the requested length and offset' );
is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'WRITE', 'X', 1 ),
    1, 'WRITE defaults an omitted offset to zero' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'CLOSE' ),
    'CLOSE returns the underlying close result' );

open my $verify, '<:raw', $path or die "Could not reopen '$path': $!";
my $contents = do { local $/; <$verify> };
close $verify or die "Could not close '$path': $!";
is( $contents, "fitagXsecond:2\n", 'WRITE updates the intended byte range' );

my $failed_handle = gensym();
tie *{$failed_handle}, 'Local::GoRoutine::FalsePrintHandle'
    or die 'Could not create the tied test handle';
my $failed_write = Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
    $failed_handle, 'WRITE', 'x', 1, 0 );
ok( !defined $failed_write,
    'WRITE returns undef when the handle declines the print' );
untie *{$failed_handle};

my $unknown_ok = eval {
    Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $handle, 'UNKNOWN' );
    1;
};
ok( !$unknown_ok, 'dispatcher rejects an unsupported operation' );
like( $@, qr/unsupported shared filehandle operation 'UNKNOWN'/,
    'unsupported-operation error names the request' );

done_testing;

__END__

=head1 NAME

t/253-goroutine-handle-dispatch-coverage.t - test shared handle dispatch paths

=head1 PURPOSE

Tests the internal GoRoutine dispatcher used to execute filehandle operations
for shared PerlIO handles in a worker interpreter.

=head1 WHY IT EXISTS

Shared filehandle behavior crosses a worker boundary, but the dispatcher can
be tested directly with an ordinary temporary file. This gives deterministic
coverage for operation semantics without creating threads or relying on a
platform-specific file descriptor implementation.

=head1 WHEN TO USE

Run this test when changing shared handle operations, byte-count behavior,
position handling, or dispatcher error reporting:

    d2 docker compose exec dev prove -lv t/253-goroutine-handle-dispatch-coverage.t

=head1 HOW TO USE

The test opens a temporary raw file, calls each dispatcher operation directly,
and checks return values and final file contents. It tests both scalar and list
context for C<READ>, and both forms of C<BINMODE>.

=head1 WHAT USES IT

The repository test suite and four-metric coverage gate use this test to verify
the shared-handle operation dispatcher in Developer::Dashboard::GoRoutine.

=head1 EXAMPLES

The test exercises C<PRINT>, C<PRINTF>, line reads, C<GETC>, C<READ>, C<WRITE>,
C<SEEK>, C<TELL>, C<EOF>, C<FILENO>, C<BINMODE>, and C<CLOSE>. An unsupported
operation is also checked for an explicit error naming the requested action.
C<WRITE> is tested with both an explicit offset and its default offset, plus a
tied handle that declines the print so the dispatcher returns C<undef> without
creating a warning.

=cut
