#!/usr/bin/env perl

use strict;
use warnings;

use File::Temp qw(tempfile);
use Scalar::Util qw(reftype);
use Test::More;

use lib 'lib';

use Developer::Dashboard::GoRoutine;

share my $counter = 4;
is( 0 + $counter, 4, 'shared scalar reads through its proxy' );
$counter += 3;
is( 0 + $counter, 7, 'shared scalar compound addition is applied on store' );
$counter = 9;
is( 0 + $counter, 9, 'shared scalar accepts a plain scalar assignment' );
my $counter_proxy = $counter;
is( 0 + $counter_proxy, 9, 'shared scalar proxy converts to a number' );
is( "$counter_proxy", '9', 'shared scalar proxy converts to a string' );
ok( !!$counter_proxy, 'non-zero shared scalar proxy is true' );

my $operation = $counter_proxy + 2;
is( 0 + $operation, 11, 'unassigned shared operation can be evaluated' );
is( 0 + ( 20 - $counter_proxy ), 11, 'reverse arithmetic evaluates with the right operand first' );
is( 0 + ( $counter_proxy * 3 ), 27, 'shared scalar supports multiplication' );
is( 0 + ( $counter_proxy / 3 ), 3, 'shared scalar supports division' );
is( 0 + ( 20 / $counter_proxy ), 20 / 9, 'shared scalar supports reverse division' );
is( 0 + ( $counter_proxy % 4 ), 1, 'shared scalar supports modulo' );
my $concatenated = $counter_proxy . '!';
is( "$concatenated", '9!', 'shared operation can be evaluated as a concatenation' );
ok( !!($counter_proxy + 1), 'non-zero shared operation is true in boolean context' );
ok( !($counter_proxy - 9), 'zero-valued shared operation is false in boolean context' );
my $already_applied = ++$counter;
is( 0 + $counter, 10, 'pre-increment applies to the shared scalar' );
my $map;
share $map = {};
$map->{incremented} = $already_applied;
is( 0 + $map->{incremented}, 10, 'storing an already-applied increment does not apply it twice' );
--$counter;
is( 0 + $counter, 9, 'pre-decrement applies to the shared scalar' );

my $other;
share $other = 2;
my $direct_ref_error = eval { $counter = $other; 1 };
ok( !$direct_ref_error, 'direct top-level shared-reference assignment is refused' );
like( $@, qr/assigning one shared reference directly/, 'top-level alias error explains the supported alternative' );

my $state;
share $state = {
    hash  => { first => 'one', second => 'two' },
    array => [ 'zero', 'one' ],
};
my $hash = $state->{hash};
is( $hash->{first}, 'one', 'shared hash fetch returns its scalar child' );
$hash->{third} = 'three';
is( $hash->{third}, 'three', 'shared hash store writes a scalar child' );
ok( exists $hash->{second}, 'shared hash exists checks a present key' );
ok( !exists $hash->{absent}, 'shared hash exists checks an absent key' );
is( scalar %{$hash}, 3, 'shared hash scalar context returns the key count' );
my @keys = sort keys %{$hash};
is_deeply( \@keys, [qw(first second third)], 'shared hash iterates a stable key snapshot' );
is( delete $hash->{second}, 'two', 'shared hash delete returns the removed scalar' );
ok( !exists $hash->{second}, 'deleted shared hash key is absent' );
tied( %{$hash} )->CLEAR;
is( scalar %{$hash}, 0, 'shared hash clear removes its keys' );

my $array = $state->{array};
is( scalar @{$array}, 2, 'shared array fetchsize returns its length' );
is( $array->[0], 'zero', 'shared array fetch reads a non-negative index' );
is( $array->[-1], 'one', 'shared array fetch resolves a negative index' );
$array->[1] = 'updated';
is( $array->[1], 'updated', 'shared array store writes an indexed value' );
ok( exists $array->[0], 'shared array exists checks a present index' );
ok( !exists $array->[8], 'shared array exists checks an absent index' );
$array->[3] = 'sparse';
is( scalar @{$array}, 4, 'shared array indexed store grows the array' );
is( delete $array->[3], 'sparse', 'shared array delete returns its removed value' );
push @{$array}, 'tail';
is( pop @{$array}, 'tail', 'shared array pop returns the last value' );
unshift @{$array}, 'head';
is( shift @{$array}, 'head', 'shared array shift returns the first value' );
@{$array} = qw(zero updated one two three four);
is_deeply( [ splice @{$array}, 1, 2, 'replacement' ], [ 'updated', 'one' ], 'shared array splice returns removed values' );
is_deeply( [ @{$array} ], [ 'zero', 'replacement', 'two', 'three', 'four' ], 'shared array splice replaces the selected range' );
is( scalar splice( @{$array}, -1 ), 'four', 'scalar splice returns the final removed value' );
is( scalar @{$array}, 4, 'splice without a length removes through the end' );
$#{$array} = 5;
is( scalar @{$array}, 6, 'shared array size assignment grows through storesize' );
tied( @{$array} )->CLEAR;
is( scalar @{$array}, 0, 'shared array clear removes all entries' );

my $scalar_value = 12;
$state->{scalar_ref} = \$scalar_value;
my $shared_scalar_ref = $state->{scalar_ref};
is( ref($shared_scalar_ref), 'SCALAR', 'shared scalar-reference child remains a scalar reference' );
is( 0 + ${$shared_scalar_ref}, 12, 'shared scalar-reference child reads its value' );
${$shared_scalar_ref} = 13;
is( $scalar_value, 12, 'shared scalar-reference assignment updates the shared graph copy' );
is( 0 + ${$shared_scalar_ref}, 13, 'shared scalar-reference proxy reads its updated graph value' );

my $blessed_hash = bless { value => 5 }, 'Local::SharedHash';
$state->{blessed_hash} = $blessed_hash;
is( ref( $state->{blessed_hash} ), 'Local::SharedHash', 'shared hash proxy preserves its blessing' );
is( 0 + $state->{blessed_hash}{value}, 5, 'blessed shared hash remains dereferenceable' );
my $blessed_array = bless [ 6, 7 ], 'Local::SharedArray';
$state->{blessed_array} = $blessed_array;
is( ref( $state->{blessed_array} ), 'Local::SharedArray', 'shared array proxy preserves its blessing' );
is( 0 + $state->{blessed_array}[1], 7, 'blessed shared array remains dereferenceable' );

ok( !Developer::Dashboard::GoRoutine::_proxy_ptr('ordinary scalar'), 'ordinary scalars have no proxy pointer' );
ok( !Developer::Dashboard::GoRoutine::_value_for_ptr(0), 'a null native handle has no Perl proxy' );
is( Developer::Dashboard::GoRoutine::_scalar_snapshot('plain'), 'plain', 'ordinary scalar snapshot is unchanged' );
is( Developer::Dashboard::GoRoutine::_scalar_snapshot($counter_proxy), 9, 'shared scalar snapshot reads its native value' );

my $channel = channel(2);
is( $channel->capacity, 2, 'buffered channel wrapper reports its capacity' );
is( $channel->size, 0, 'empty buffered channel wrapper reports zero size' );
is( $channel->send('queued'), $channel,
    'channel send returns the wrapper for chaining' );
is( $channel->size, 1, 'buffered channel wrapper reports a queued value' );
my ( $channel_value, $channel_ok ) = $channel->receive;
is( $channel_value, 'queued', 'buffered channel wrapper receives its queued value' );
ok( $channel_ok, 'buffered channel receive reports a successful value' );
$channel->send('scalar-context');
is( scalar $channel->receive, 'scalar-context',
    'buffered channel receive returns the value in scalar context' );
is( $channel->close, $channel, 'channel close returns the wrapper for chaining' );
ok( $channel->is_closed, 'closed channel wrapper reports its closed state' );
my ( $closed_value, $closed_ok ) = $channel->receive;
ok( !defined $closed_value, 'closed channel returns no further value' );
ok( !$closed_ok, 'closed channel receive reports failure' );
my $closed_send = eval { $channel->send('rejected'); 1 };
ok( !$closed_send, 'channel wrapper propagates send-after-close errors' );
like( $@, qr/closed/, 'send-after-close failure has an explicit diagnostic' );
my $invalid_channel = bless {}, 'Developer::Dashboard::GoRoutine::Channel';
my $invalid_channel_ok = eval { $invalid_channel->size; 1 };
ok( !$invalid_channel_ok, 'channel wrapper rejects a missing native handle' );
like( $@, qr/invalid channel handle/, 'invalid channel diagnostic names the handle' );
my $invalid_routine = bless {}, 'Developer::Dashboard::GoRoutine::Routine';
my $invalid_routine_ok = eval { $invalid_routine->is_running; 1 };
ok( !$invalid_routine_ok, 'routine wrapper rejects a missing native handle' );
like( $@, qr/invalid go routine handle/, 'invalid routine diagnostic names the handle' );

my $regexp_ptr = Developer::Dashboard::GoRoutine::_shared_node_new();
Developer::Dashboard::GoRoutine::_shared_node_set( $regexp_ptr, qr/^native+$/i );
my $regexp_proxy = Developer::Dashboard::GoRoutine::_value_for_ptr($regexp_ptr);
is( ref($regexp_proxy), 'Regexp', 'native regexp node materializes as a Perl regexp' );
ok( 'NATIVEEE' =~ $regexp_proxy, 'materialized regexp preserves matching behavior' );

my $field_ptr = Developer::Dashboard::GoRoutine::_shared_node_new();
Developer::Dashboard::GoRoutine::_shared_node_set( $field_ptr, 4 );
my $field_ref = Developer::Dashboard::GoRoutine::_field_ref_for_ptr($field_ptr);
is( 0 + $$field_ref, 4, 'native scalar field materializes as a tied scalar reference' );
$$field_ref = 8;
is( 0 + $$field_ref, 8, 'tied field reference writes through to its shared node' );

my ( $remote_fh, $remote_path ) = tempfile();
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $remote_fh, 'PRINT', "first\n" ),
    'remote handle dispatcher prints to its private handle' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $remote_fh, 'PRINTF', "%s %d\n", 'second', 2 ),
    'remote handle dispatcher supports formatted output' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $remote_fh, 'SEEK', 0, 0 ),
    'remote handle dispatcher seeks' );
is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'TELL'), 0,
    'remote handle dispatcher reports position' );
is( scalar Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'READLINE_SCALAR'),
    "first\n", 'remote handle dispatcher reads one line in scalar context' );
my @line = Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'READLINE_LIST');
is_deeply( \@line, [ "second 2\n" ], 'remote handle dispatcher reads remaining lines in list context' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'EOF'),
    'remote handle dispatcher detects end of file' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'SEEK', 0, 0),
    'remote handle dispatcher can rewind before byte reads' );
is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'GETC'), 'f',
    'remote handle dispatcher reads a character' );
my ( $read_count, $read_buffer ) = Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
    $remote_fh, 'READ', 4
);
is( $read_count, 4, 'remote handle dispatcher returns byte count' );
is( $read_buffer, 'irst', 'remote handle dispatcher returns the requested bytes' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'SEEK', 0, 2),
    'remote handle dispatcher seeks to a write offset' );
is( Developer::Dashboard::GoRoutine::_handle_remote_dispatch(
        $remote_fh, 'WRITE', 'replacement', 4, 0 ),
    4, 'remote handle dispatcher writes the requested substring' );
ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'BINMODE'),
    'remote handle dispatcher supports binmode' );
ok( defined Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'FILENO'),
    'remote handle dispatcher reports a real file descriptor' );
my $unsupported_handle_op = eval {
    Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'NOPE'); 1;
};
ok( !$unsupported_handle_op, 'remote handle dispatcher rejects unknown operations' );
like( $@, qr/unsupported shared filehandle operation/, 'unknown handle operation has a clear diagnostic' );

ok( Developer::Dashboard::GoRoutine::_handle_remote_dispatch($remote_fh, 'CLOSE'),
    'remote handle dispatcher closes the private handle' );

my $routine_state = {
    ptr     => 1,
    running => 1,
    age     => 2.5,
    status  => 'running',
    killed  => 0,
};
{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_routine_is_running = sub { $routine_state->{running} };
    local *Developer::Dashboard::GoRoutine::_routine_age = sub { $routine_state->{age} };
    local *Developer::Dashboard::GoRoutine::_routine_kill = sub { $routine_state->{killed} = 1 };
    local *Developer::Dashboard::GoRoutine::_routine_timeout = sub { $routine_state->{timeout} = $_[1] };
    local *Developer::Dashboard::GoRoutine::_routine_status = sub { $routine_state->{status} };
    my $routine = bless $routine_state, 'Developer::Dashboard::GoRoutine::Routine';
    ok( $routine->is_running, 'routine wrapper reports its mocked running state' );
    is( $routine->age, 2.5, 'routine wrapper reports its mocked age' );
    ok( $routine->kill, 'routine wrapper requests cancellation' );
    is( $routine->timeout(0.25), $routine, 'valid timeout returns the routine for chaining' );
    is( $routine_state->{timeout}, 0.25, 'valid timeout forwards a numeric value' );
    is( $routine->status, 'running', 'routine wrapper returns the native status' );
    ok( !$routine->is_killed, 'running routine is not marked as killed' );
    $routine_state->{status} = 'timed_out';
    ok( $routine->is_killed, 'timed-out routine is marked as killed' );
}

for my $bad_timeout ( undef, [], 'not-a-number', 'NaN', 'Inf', -1 ) {
    my $routine = bless {}, 'Developer::Dashboard::GoRoutine::Routine';
    my $ok = eval { $routine->timeout($bad_timeout); 1 };
    ok( !$ok, 'invalid timeout is rejected' );
    like( $@, qr/timeout\(\) requires a non-negative number/, 'invalid timeout has a clear diagnostic' );
}

{
    my $scalar_value = 21;
    my @array_values = qw(alpha beta);
    my %hash_values = ( key => 'value' );
    Developer::Dashboard::GoRoutine::_share_many(
        \$scalar_value, \@array_values, \%hash_values
    );
    is( 0 + $scalar_value, 21, '_share_many ties a scalar reference and preserves its initial value' );
    is_deeply( [@array_values], [qw(alpha beta)], '_share_many ties an array and preserves its items' );
    is_deeply( { %hash_values }, { key => 'value' }, '_share_many ties a hash and preserves its entries' );

    my $already_shared = eval { Developer::Dashboard::GoRoutine::_share_many(
            \$scalar_value, \@array_values, \%hash_values
        ); 1 };
    ok( $already_shared, '_share_many accepts its own already-shared scalar, array, and hash values' );

    my $code = sub { return 1 };
    my $unsupported = eval {
        Developer::Dashboard::GoRoutine::_share_many($code);
        1;
    };
    ok( !$unsupported, '_share_many rejects a code reference' );
    like( $@, qr/expects scalar, array, or hash/, 'unsupported shared-reference error names accepted types' );
}

{
    package Local::UnsupportedSharedScalar;
    sub TIESCALAR { return bless {}, shift }
    package Local::UnsupportedSharedArray;
    sub TIEARRAY { return bless {}, shift }
    package Local::UnsupportedSharedHash;
    sub TIEHASH { return bless {}, shift }
    package main;

    tie my $foreign_scalar, 'Local::UnsupportedSharedScalar';
    tie my @foreign_array, 'Local::UnsupportedSharedArray';
    tie my %foreign_hash, 'Local::UnsupportedSharedHash';
    for my $case (
        [ \$foreign_scalar, qr/already tied scalar/ ],
        [ \@foreign_array, qr/already tied array/ ],
        [ \%foreign_hash, qr/already tied hash/ ],
    ) {
        my $accepted = eval { Developer::Dashboard::GoRoutine::_share_many( $case->[0] ); 1 };
        ok( !$accepted, '_share_many rejects an incompatible pre-tied aggregate' );
        like( $@, $case->[1], 'incompatible tied-aggregate diagnostic is explicit' );
    }
}

done_testing;

__END__

=head1 NAME

t/233-goroutine-shared-object-coverage.t - exercise GoRoutine Perl proxies without workers

=head1 PURPOSE

This test exercises the Perl proxy, tied-hash, tied-array, scalar-reference,
overload, and routine-handle wrapper code in C<Developer::Dashboard::GoRoutine>
without starting worker threads. The separate integration tests exercise real
worker and shared-object concurrency outside Devel::Cover instrumentation.

=head1 WHY IT EXISTS

Devel::Cover cannot safely instrument Perl ithreads, so the concurrency tests
run in a separate native-thread suite. Without this thread-free contract test,
the Perl code that adapts native shared nodes to ordinary Perl references would
not be measured by the four-metric library coverage gate.

=head1 WHEN TO USE

Run this test in the project Docker service whenever GoRoutine proxy methods,
operator overloads, tied container operations, timeout validation, or routine
handle wrappers change:

    d2 docker compose exec dev prove -lv t/233-goroutine-shared-object-coverage.t

=head1 HOW TO USE

The test requires the checkout's built XS object and loads it through the
existing C<Developer::Dashboard::HtmlEscape> distribution module. It uses
ordinary Perl operations against shared values but replaces only the native
routine-handle XSUB calls with local in-process stubs, so it never creates a
worker thread. Run it with the normal test library paths and the coverage gate
will include its Perl-module execution in the lib-only report.

=head1 EXAMPLES

Run the focused proxy contract:

    d2 docker compose exec dev prove -lv t/233-goroutine-shared-object-coverage.t

Run it as part of all tests and coverage:

    d2 docker compose exec dev perl script/coverage-gate

=head1 WHAT USES IT

The repository test and coverage workflows use this file to measure the Perl
adapter code while the native-thread tests independently verify concurrency.
It is not installed as an end-user command.

=cut
