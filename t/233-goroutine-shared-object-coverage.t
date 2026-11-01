#!/usr/bin/env perl

use strict;
use warnings;

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
my $concatenated = $counter_proxy . '!';
is( "$concatenated", '9!', 'shared operation can be evaluated as a concatenation' );
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
