#!/usr/bin/env perl

use strict;
use warnings;

use File::Temp qw(tempfile);
use POSIX ();
use Scalar::Util qw(reftype);
use Test::More;

use lib 'lib';

use Developer::Dashboard::GoRoutine;

share my $counter = 4;
ok( Developer::Dashboard::GoRoutine::_is_shared_proxy(
        tied($counter), 'Developer::Dashboard::GoRoutine::SharedScalar' ),
    'proxy predicate accepts a shared scalar tie' );
ok( !Developer::Dashboard::GoRoutine::_is_shared_proxy(
        bless( {}, 'Local::UnrelatedProxy' ),
        'Developer::Dashboard::GoRoutine::SharedScalar' ),
    'proxy predicate rejects a different blessed class' );
ok( !Developer::Dashboard::GoRoutine::_is_shared_proxy(
        'ordinary value', 'Developer::Dashboard::GoRoutine::SharedScalar' ),
    'proxy predicate rejects a non-reference value' );
is( 0 + $counter, 4, 'shared scalar reads through its proxy' );
$counter += 3;
is( 0 + $counter, 7, 'shared scalar compound addition is applied on store' );
$counter = 20 - $counter;
is( 0 + $counter, 13, 'shared scalar applies reverse arithmetic when assigned' );
$counter = 9;
is( 0 + $counter, 9, 'shared scalar accepts a plain scalar assignment' );
my $counter_proxy = $counter;
is( tied($counter)->_ptr, tied($counter)->{ptr},
    'shared proxy base accessor returns the native handle' );
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
is( 0 + ( 20 + $counter_proxy ), 29, 'shared scalar supports reverse addition' );
is( 0 + ( 20 - $counter_proxy ), 11, 'shared scalar supports reverse subtraction' );
is( 0 + ( 3 * $counter_proxy ), 27, 'shared scalar supports reverse multiplication' );
is( 0 + ( 27 / $counter_proxy ), 3, 'shared scalar supports reverse division' );
is( 0 + ( 18 % $counter_proxy ), 0, 'shared scalar supports reverse modulo' );
is( "prefix-" . $counter_proxy, 'prefix-9', 'shared scalar supports reverse concatenation' );
is( int($counter_proxy), 9, 'shared scalar proxy converts directly to an integer' );
my $concatenated = $counter_proxy . '!';
is( "$concatenated", '9!', 'shared operation can be evaluated as a concatenation' );
my $concatenation_op = bless {
    ptr     => tied($counter)->_ptr,
    op      => 'concat',
    arg     => '-tail',
    reverse => 0,
}, 'Developer::Dashboard::GoRoutine::SharedOp';
is( $concatenation_op->_evaluate, '9-tail',
    'shared operation evaluator handles a forward concatenation' );
my $unknown_operation = bless {
    ptr     => tied($counter)->_ptr,
    op      => 'unsupported',
    arg     => 'value',
    reverse => 0,
}, 'Developer::Dashboard::GoRoutine::SharedOp';
my $unknown_operation_ok = eval { $unknown_operation->_evaluate; 1 };
ok( !$unknown_operation_ok, 'shared operation evaluator rejects an unknown operation' );
like( $@, qr/unknown shared operation 'unsupported'/,
    'unknown shared operation failure names the operation' );
ok( !!($counter_proxy + 1), 'non-zero shared operation is true in boolean context' );
ok( !($counter_proxy - 9), 'zero-valued shared operation is false in boolean context' );
my $already_applied = ++$counter;
is( 0 + $counter, 10, 'pre-increment applies to the shared scalar' );
my $map;
share $map = {};
$map->{incremented} = $already_applied;
is( 0 + $map->{incremented}, 10, 'storing an already-applied increment does not apply it twice' );
$counter = ++$counter;
is( 0 + $counter, 11,
    'assigning a pre-incremented value back to its source is not applied twice' );
$counter = 10;
my $same_pointer_value = Developer::Dashboard::GoRoutine::SharedValue->_new(
    tied($counter)->_ptr
);
tied($counter)->STORE($same_pointer_value);
is( 0 + $counter, 10,
    'storing a pending shared value that points to the same scalar is a no-op' );
--$counter;
is( 0 + $counter, 9, 'pre-decrement applies to the shared scalar' );

share my ($group_left, $group_right) = (5, 6);
is( 0 + $group_left, 5, 'grouped share declaration initializes its first scalar' );
is( 0 + $group_right, 6, 'grouped share declaration initializes its second scalar' );
share my @declared_array = qw(red green);
is_deeply( [@declared_array], [qw(red green)],
    'aggregate share declaration preserves its array initializer' );
share my %declared_hash = (enabled => 1);
is( 0 + $declared_hash{enabled}, 1,
    'aggregate share declaration preserves its hash initializer' );

my $existing_scalar = 7;
my @existing_array = qw(one two);
my %existing_hash = (ready => 1);
share $existing_scalar, @existing_array, %existing_hash;
is( 0 + $existing_scalar, 7, 'existing-variable share preserves scalar data' );
is_deeply( [@existing_array], [qw(one two)],
    'existing-variable share preserves array data' );
is( 0 + $existing_hash{ready}, 1,
    'existing-variable share preserves hash data' );

my $other;
share $other = 2;
my $already_applied_other = bless {
    ptr             => tied($other)->{ptr},
    already_applied => 1,
}, 'Developer::Dashboard::GoRoutine::SharedValue';
my $applied_alias_error = eval { $counter = $already_applied_other; 1 };
ok( !$applied_alias_error,
    'assigning an already-applied value from a different scalar is rejected' );
like( $@, qr/assigning one shared reference directly/,
    'already-applied cross-scalar assignment reports the aliasing constraint' );
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
$hash->{computed} = $counter_proxy * 2;
is( 0 + $counter_proxy, 18, 'shared hash store applies a shared scalar operation to its source' );
ok( !exists $hash->{computed}, 'shared scalar operation is not stored as a hash value' );
$hash->{reverse_computed} = 20 - $counter_proxy;
is( 0 + $counter_proxy, 2, 'shared hash store applies a reverse shared operation to its source' );
ok( !exists $hash->{reverse_computed}, 'reverse shared scalar operation is not stored as a hash value' );
$counter = 9;
my $pending_hash_value = Developer::Dashboard::GoRoutine::SharedValue->_new(
    tied($counter)->_ptr
);
$hash->{pending_shared_value} = $pending_hash_value;
is( 0 + $hash->{pending_shared_value}, 9,
    'shared hash store links a not-yet-applied shared value' );
$hash->{already_applied_value} = ++$counter_proxy;
is( 0 + $counter_proxy, 10,
    'shared hash store does not apply a pre-incremented value twice' );
ok( !exists $hash->{already_applied_value},
    'shared hash store does not retain an already-applied value' );
$counter = 9;
$hash->{concatenated_operation} = $counter_proxy . '-tail';
is( "$counter_proxy", '9-tail',
    'shared hash store applies a shared concatenation operation to its source' );
$hash->{unicode} = "caf\x{e9}";
is( $hash->{unicode}, "caf\x{e9}", 'shared hash store preserves a UTF-8 scalar' );
$counter = "caf\x{e9}";
is( $counter, "caf\x{e9}", 'shared scalar assignment preserves a UTF-8 scalar' );
$counter = 9;
my $upgraded_unicode = join q{}, 'caf', chr(0xE9);
utf8::upgrade($upgraded_unicode);
ok( utf8::is_utf8($upgraded_unicode), 'UTF-8 fixture is explicitly upgraded' );
$counter = $upgraded_unicode;
is( $counter, $upgraded_unicode,
    'shared scalar assignment preserves an explicitly upgraded UTF-8 value' );
my $counter_after_unicode = $counter;
$counter = $counter_after_unicode;
is( $counter, $counter_after_unicode,
    'shared scalar accepts a copied upgraded UTF-8 scalar' );
 $counter = 9;
my $aggregate_scalar_error = eval { $counter = $hash; 1 };
ok( !$aggregate_scalar_error,
    'shared scalar assignment rejects a shared aggregate proxy' );
like( $@, qr/assigning one shared reference directly/,
    'shared aggregate assignment error explains the supported location' );
$counter = 9;
$hash->{nested_array} = $state->{array};
is( $hash->{nested_array}[0], 'zero',
    'shared hash store preserves a shared aggregate proxy reference' );
is( scalar %{$hash}, 6, 'shared hash scalar context returns the key count' );
my @keys = sort keys %{$hash};
is_deeply( \@keys, [qw(first nested_array pending_shared_value second third unicode)],
    'shared hash iterates a stable key snapshot' );
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
ok( exists $array->[-1], 'shared array exists resolves a negative index' );
$array->[-1] = 'negative-store';
is( $array->[-1], 'negative-store', 'shared array store resolves a negative index' );
is( tied(@{$array})->FETCH(-1), 'negative-store',
    'tied shared array FETCH normalizes a negative index passed directly' );
ok( !defined tied(@{$array})->STORE(-1, 'negative-direct-store'),
    'tied shared array STORE normalizes a negative index passed directly' );
is( $array->[-1], 'negative-direct-store',
    'direct negative-index STORE updates the normalized array element' );
ok( tied(@{$array})->EXISTS(-1),
    'tied shared array EXISTS normalizes a negative index passed directly' );
is( tied(@{$array})->DELETE(-1), 'negative-direct-store',
    'tied shared array DELETE normalizes a negative index passed directly' );
$array->[0] = $counter_proxy + 1;
is( 0 + $counter_proxy, 10, 'shared array store applies a shared scalar operation to its source' );
is( $array->[0], 'zero', 'shared scalar operation is not stored as an array item' );
$array->[0] = 30 - $counter_proxy;
is( 0 + $counter_proxy, 20, 'shared array store applies a reverse shared operation to its source' );
is( $array->[0], 'zero', 'reverse shared scalar operation is not stored as an array item' );
$counter = 9;
my $pending_array_value = Developer::Dashboard::GoRoutine::SharedValue->_new(
    tied($counter)->_ptr
);
$array->[0] = $pending_array_value;
is( 0 + $array->[0], 9, 'shared array store links a not-yet-applied shared value' );
$counter = 10;
my $array_size_before_increment = scalar @{$array};
$array->[20] = ++$counter_proxy;
is( 0 + $counter_proxy, 11, 'shared array assignment preserves the already-applied increment' );
is( scalar @{$array}, $array_size_before_increment,
    'storing an already-applied increment does not grow the shared array' );
ok( !exists $array->[20], 'already-applied increment result is not stored as an array element' );
$counter = 9;
$hash->{computed} = 18;
$array->[1] = $hash;
is( $array->[1]{computed}, 18,
    'shared array store preserves a shared hash proxy reference' );
$array->[3] = 'sparse';
is( scalar @{$array}, 4, 'shared array indexed store grows the array' );
is( delete $array->[3], 'sparse', 'shared array delete returns its removed value' );
push @{$array}, 'tail';
is( pop @{$array}, 'tail', 'shared array pop returns the last value' );
unshift @{$array}, 'head';
is( shift @{$array}, 'head', 'shared array shift returns the first value' );
$hash->{available} = 'now';
unshift @{$array}, $hash;
is( $array->[0]{available}, 'now',
    'shared array unshift preserves an aggregate proxy reference' );
shift @{$array};
@{$array} = qw(zero updated one two three four);
is_deeply( [ splice @{$array}, 1, 2, 'replacement' ], [ 'updated', 'one' ], 'shared array splice returns removed values' );
is_deeply( [ @{$array} ], [ 'zero', 'replacement', 'two', 'three', 'four' ], 'shared array splice replaces the selected range' );
is( scalar splice( @{$array}, -1 ), 'four', 'scalar splice returns the final removed value' );
is( scalar @{$array}, 4, 'splice without a length removes through the end' );
@{$array} = qw(alpha beta gamma delta);
is_deeply( [ splice @{$array}, -99, 99 ], [qw(alpha beta gamma delta)],
    'splice clamps a far-negative offset and oversized length to array bounds' );
@{$array} = qw(alpha beta gamma delta);
is_deeply( [ splice @{$array}, 99, 1 ], [],
    'splice clamps an offset beyond the array end' );
@{$array} = qw(alpha beta gamma delta);
is_deeply( [ splice @{$array}, 1, -99 ], [],
    'splice clamps a negative length beyond the remaining range to zero' );
@{$array} = qw(alpha beta gamma delta);
is_deeply( [ splice @{$array}, 1, 99 ], [qw(beta gamma delta)],
    'splice clamps an oversized positive length to the remaining range' );
@{$array} = qw(alpha beta gamma delta);
is_deeply( [ splice @{$array} ], [qw(alpha beta gamma delta)],
    'splice without arguments defaults to the full array' );
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
my $blessed_scalar_value = 14;
$state->{blessed_scalar_ref} = bless( \$blessed_scalar_value, 'Local::SharedScalarRef' );
my $blessed_scalar_ref = $state->{blessed_scalar_ref};
is( ref($blessed_scalar_ref), 'Local::SharedScalarRef',
    'shared scalar-reference proxy preserves its blessing' );
is( 0 + ${$blessed_scalar_ref}, 14,
    'blessed shared scalar-reference proxy remains dereferenceable' );
my $scalar_ref_node = Developer::Dashboard::GoRoutine::_shared_hash_fetch_ptr(
    tied(%{$state})->{ptr}, 'blessed_scalar_ref'
);
my $unblessed_scalar_ref =
    Developer::Dashboard::GoRoutine::SharedScalarRef->_new_ref($scalar_ref_node, q{});
is( ref($unblessed_scalar_ref), 'SCALAR',
    'scalar-reference materializer leaves an empty optional class unblessed' );

my $blessed_hash = bless { value => 5 }, 'Local::SharedHash';
$state->{blessed_hash} = $blessed_hash;
is( ref( $state->{blessed_hash} ), 'Local::SharedHash', 'shared hash proxy preserves its blessing' );
is( 0 + $state->{blessed_hash}{value}, 5, 'blessed shared hash remains dereferenceable' );
my $hash_node = Developer::Dashboard::GoRoutine::_shared_hash_fetch_ptr(
    tied(%{$state})->{ptr}, 'blessed_hash'
);
my $unblessed_shared_hash = Developer::Dashboard::GoRoutine::SharedHash->_new_ref(
    $hash_node, q{}
);
is( ref($unblessed_shared_hash), 'HASH',
    'hash materializer leaves an empty optional class unblessed' );
my $blessed_array = bless [ 6, 7 ], 'Local::SharedArray';
$state->{blessed_array} = $blessed_array;
is( ref( $state->{blessed_array} ), 'Local::SharedArray', 'shared array proxy preserves its blessing' );
is( 0 + $state->{blessed_array}[1], 7, 'blessed shared array remains dereferenceable' );
my $array_node = Developer::Dashboard::GoRoutine::_shared_hash_fetch_ptr(
    tied(%{$state})->{ptr}, 'blessed_array'
);
my $unblessed_shared_array = Developer::Dashboard::GoRoutine::SharedArray->_new_ref(
    $array_node, q{}
);
is( ref($unblessed_shared_array), 'ARRAY',
    'array materializer leaves an empty optional class unblessed' );

ok( !Developer::Dashboard::GoRoutine::_proxy_ptr('ordinary scalar'), 'ordinary scalars have no proxy pointer' );
ok( !Developer::Dashboard::GoRoutine::_value_for_ptr(0), 'a null native handle has no Perl proxy' );
is( Developer::Dashboard::GoRoutine::_scalar_snapshot('plain'), 'plain', 'ordinary scalar snapshot is unchanged' );
is( Developer::Dashboard::GoRoutine::_scalar_snapshot($counter_proxy), 9, 'shared scalar snapshot reads its native value' );

my $channel = channel(2);
is( $channel->capacity, 2, 'buffered channel wrapper reports its capacity' );
is( $channel->size, 0, 'empty buffered channel wrapper reports zero size' );
ok( !$channel->is_closed, 'open buffered channel wrapper reports its open state' );
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
my $scalar_channel_ok = eval {
    Developer::Dashboard::GoRoutine::Channel::_ptr('not-a-reference');
    1;
};
ok( !$scalar_channel_ok, 'channel wrapper rejects a non-reference handle' );
like( $@, qr/invalid channel handle/, 'non-reference channel diagnostic names the handle' );
my $invalid_routine = bless {}, 'Developer::Dashboard::GoRoutine::Routine';
my $invalid_routine_ok = eval { $invalid_routine->is_running; 1 };
ok( !$invalid_routine_ok, 'routine wrapper rejects a missing native handle' );
like( $@, qr/invalid go routine handle/, 'invalid routine diagnostic names the handle' );
my $scalar_routine_ok = eval {
    Developer::Dashboard::GoRoutine::Routine::_ptr('not-a-reference');
    1;
};
ok( !$scalar_routine_ok, 'routine wrapper rejects a non-reference handle' );
like( $@, qr/invalid go routine handle/, 'non-reference routine diagnostic names the handle' );

{
    no warnings 'redefine';
    my $exited_routine = bless { ptr => 1 }, 'Developer::Dashboard::GoRoutine::Routine';
    for my $status (qw(killed timed_out exited)) {
        local *Developer::Dashboard::GoRoutine::_routine_status = sub { $status };
        is( $exited_routine->is_killed, $status eq 'exited' ? 0 : 1,
            "routine wrapper classifies $status correctly" );
    }
}

my $regexp_ptr = Developer::Dashboard::GoRoutine::_shared_node_new();
Developer::Dashboard::GoRoutine::_shared_node_set( $regexp_ptr, qr/^native+$/i );
my $regexp_proxy = Developer::Dashboard::GoRoutine::_value_for_ptr($regexp_ptr);
is( ref($regexp_proxy), 'Regexp', 'native regexp node materializes as a Perl regexp' );
ok( 'NATIVEEE' =~ $regexp_proxy, 'materialized regexp preserves matching behavior' );

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_kind = sub { 'object' };
    local *Developer::Dashboard::GoRoutine::_shared_node_class = sub { 'Local::SharedObject' };
    local *Developer::Dashboard::GoRoutine::_shared_object_proxy = sub {
        return bless { native_ptr => $_[0] }, 'Local::SharedObject';
    };
    my $object_proxy = Developer::Dashboard::GoRoutine::_value_for_ptr(456);
    is( ref($object_proxy), 'Local::SharedObject',
        'native object nodes materialize through the object proxy adapter' );
    is( $object_proxy->{native_ptr}, 456,
        'native object proxy receives its shared node handle' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_kind = sub { 'unknown-test-kind' };
    local *Developer::Dashboard::GoRoutine::_shared_node_class = sub { undef };
    my $known = eval { Developer::Dashboard::GoRoutine::_value_for_ptr(457); 1 };
    ok( !$known, 'unknown shared-node kinds are rejected' );
    like( $@, qr/unknown shared value kind 'unknown-test-kind'/,
        'unknown shared-node diagnostic includes the unsupported kind' );
}

{
    my @materialized;
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_kind = sub { $_[0] };
    local *Developer::Dashboard::GoRoutine::_shared_node_class = sub { 'Local::SharedType' };
    local *Developer::Dashboard::GoRoutine::_glob_for_ptr = sub {
        push @materialized, [ glob => @_ ];
        return 'glob-proxy';
    };
    local *Developer::Dashboard::GoRoutine::_io_for_ptr = sub {
        push @materialized, [ io => @_ ];
        return 'io-proxy';
    };
    local *Developer::Dashboard::GoRoutine::_format_for_ptr = sub {
        push @materialized, [ format => @_ ];
        return 'format-proxy';
    };

    is( Developer::Dashboard::GoRoutine::_value_for_ptr('glob'), 'glob-proxy',
        'glob shared-node values delegate to the glob materializer' );
    is( Developer::Dashboard::GoRoutine::_value_for_ptr('io'), 'io-proxy',
        'IO shared-node values delegate to the IO materializer' );
    is( Developer::Dashboard::GoRoutine::_value_for_ptr('format'), 'format-proxy',
        'format shared-node values delegate to the format materializer' );
    is_deeply( \@materialized,
        [
            [ glob   => 'glob',   'Local::SharedType' ],
            [ io     => 'io',     'Local::SharedType' ],
            [ format => 'format' ],
        ],
        'materializers receive the shared node and applicable class' );
}

{
    my ($native_fh) = tempfile();
    my $native_fd = fileno($native_fh);
    {
        no warnings 'redefine';
        local *Developer::Dashboard::GoRoutine::_shared_handle_fd = sub { $native_fd };
        local *Developer::Dashboard::GoRoutine::_shared_handle_mode = sub { '<&' };
        local *Developer::Dashboard::GoRoutine::_shared_glob_slot_ptr = sub { undef };

        my $shared_glob = Developer::Dashboard::GoRoutine::_glob_for_ptr(123, undef);
        is( reftype($shared_glob), 'GLOB',
            'native glob materializer opens a duplicated filehandle without a worker' );
        ok( close($shared_glob), 'materialized native glob closes cleanly' );

        my $blessed_glob = Developer::Dashboard::GoRoutine::_glob_for_ptr(123, 'Local::SharedGlob');
        is( ref($blessed_glob), 'Local::SharedGlob',
            'native glob materializer preserves the requested handle class' );
        ok( close($blessed_glob), 'blessed materialized glob closes cleanly' );

        my $shared_io = Developer::Dashboard::GoRoutine::_io_for_ptr(123, undef);
        is( reftype($shared_io), 'IO',
            'native IO materializer returns the duplicated filehandle IO slot' );
        ok( close($shared_io), 'materialized native IO handle closes cleanly' );

        my $unblessed_glob = Developer::Dashboard::GoRoutine::_glob_for_ptr(123, q{});
        is( reftype($unblessed_glob), 'GLOB',
            'native glob materializer accepts an empty optional class' );
        ok( close($unblessed_glob), 'unblessed materialized glob closes cleanly' );

        my $unblessed_io = Developer::Dashboard::GoRoutine::_io_for_ptr(123, q{});
        is( reftype($unblessed_io), 'IO',
            'native IO materializer accepts an empty optional class' );
        ok( close($unblessed_io), 'unblessed materialized IO closes cleanly' );

        my $blessed_io = Developer::Dashboard::GoRoutine::_io_for_ptr(123, 'Local::SharedIO');
        is( ref($blessed_io), 'Local::SharedIO',
            'native IO materializer preserves the requested handle class' );
        ok( close($blessed_io), 'blessed materialized IO handle closes cleanly' );

        my $opened_handle = Developer::Dashboard::GoRoutine::_open_shared_handle(123);
        is( reftype($opened_handle), 'GLOB',
            'shared handle opener duplicates a supplied descriptor' );
        ok( close($opened_handle), 'duplicated shared filehandle closes cleanly' );
    }
    close($native_fh) or die "cannot close native filehandle fixture: $!";
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_handle_fd = sub { 999999 };
    local *Developer::Dashboard::GoRoutine::_shared_handle_mode = sub { '<&' };
    my $opened = eval { Developer::Dashboard::GoRoutine::_open_shared_handle(123); 1 };
    ok( !$opened, 'shared handle opener rejects a descriptor that cannot be duplicated' );
    like( $@, qr/cannot duplicate shared filehandle fd 999999/,
        'descriptor duplication failure identifies the invalid descriptor' );
}

{
    require Symbol;
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_open_shared_handle = sub { Symbol::gensym() };
    my $io_ok = eval { Developer::Dashboard::GoRoutine::_io_for_ptr(123, undef); 1 };
    ok( !$io_ok, 'IO materializer rejects a handle without an IO slot' );
    like( $@, qr/shared IO value has no materializable filehandle/,
        'missing IO slot reports the materialization failure explicitly' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_text = sub { 'example' };
    my $regexp = Developer::Dashboard::GoRoutine::_regexp_for_ptr(124, 'Local::SharedRegexp');
    is( ref($regexp), 'Local::SharedRegexp',
        'regexp materializer preserves a non-default blessing' );
    ok( 'an example' =~ $regexp, 'blessed materialized regexp still matches' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_text = sub { 'example' };
    my $regexp = Developer::Dashboard::GoRoutine::_regexp_for_ptr(124, q{});
    is( ref($regexp), 'Regexp',
        'regexp materializer leaves an empty optional class unblessed' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_text = sub { 'example' };
    my $regexp = Developer::Dashboard::GoRoutine::_regexp_for_ptr(124, 'Regexp');
    is( ref($regexp), 'Regexp',
        'regexp materializer does not bless the built-in regexp class' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_text = sub { 'example' };
    my $regexp = Developer::Dashboard::GoRoutine::_regexp_for_ptr(124, undef);
    is( ref($regexp), 'Regexp',
        'regexp materializer accepts an undefined optional class' );
}

{
    my $value = 1;
    my $scalar_ref = \$value;
    my $ref_ref = \$scalar_ref;
    ok( !defined Developer::Dashboard::GoRoutine::_proxy_ptr($ref_ref),
        'proxy lookup safely ignores a reference-to-reference without a shared tie' );
}
{
    my $value = bless {}, 'Local::ReferenceWithoutType';
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::reftype = sub { return; };
    ok( !defined Developer::Dashboard::GoRoutine::_proxy_ptr($value),
        'proxy lookup safely handles a reference without a reported referent type' );
}

{
    my $auto_shared;
    tie $auto_shared, 'Developer::Dashboard::GoRoutine::SharedScalar';
    tied($auto_shared)->STORE(42);
    is( 0 + $auto_shared, 42,
        'shared scalar tie allocates its native node when no pointer is supplied' );
    untie $auto_shared;
}

{
    my %slot_ptr = ( scalar => 11, array => 12, hash => 13, code => 14 );
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_handle_fd = sub { -1 };
    local *Developer::Dashboard::GoRoutine::_shared_handle_mode = sub { '<&' };
    local *Developer::Dashboard::GoRoutine::_shared_glob_slot_ptr = sub {
        return $slot_ptr{ $_[1] };
    };
    local *Developer::Dashboard::GoRoutine::_field_ref_for_ptr = sub {
        my $value = "scalar-$_[0]";
        return \$value;
    };
    local *Developer::Dashboard::GoRoutine::_value_for_ptr = sub {
        return [ "array-$_[0]" ] if $_[0] == $slot_ptr{array};
        return { value => "hash-$_[0]" } if $_[0] == $slot_ptr{hash};
        if ( $_[0] == $slot_ptr{code} ) {
            my $ptr = $_[0];
            return sub { "code-$ptr" };
        }
        return;
    };

    my $shared_glob = Developer::Dashboard::GoRoutine::_glob_for_ptr(10, undef);
    is( ${ *{$shared_glob}{SCALAR} }, 'scalar-11',
        'descriptorless shared glob materializes its scalar slot' );
    is_deeply( *{$shared_glob}{ARRAY}, ['array-12'],
        'descriptorless shared glob materializes its array slot' );
    is_deeply( *{$shared_glob}{HASH}, { value => 'hash-13' },
        'descriptorless shared glob materializes its hash slot' );
    is( *{$shared_glob}{CODE}->(), 'code-14',
        'descriptorless shared glob materializes its code slot' );
    ok( tied( *{$shared_glob} ), 'descriptorless shared glob retains its tied handle' );
    untie *{$shared_glob};
}

my $format_ref;
{
    our $coverage_format_value = 'abc';
    format GOROUTINE_COVERAGE_FORMAT =
@<<<<
$coverage_format_value
.
    $format_ref = *GOROUTINE_COVERAGE_FORMAT{FORMAT};
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_text = sub { return undef };
    ok( !defined Developer::Dashboard::GoRoutine::_format_for_ptr(124),
        'format materializer returns undef when the shared name is absent' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_text = sub { return q{} };
    ok( !defined Developer::Dashboard::GoRoutine::_format_for_ptr(124),
        'format materializer returns undef when the shared name is empty' );
}
{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_text = sub {
        return 'main::GOROUTINE_COVERAGE_FORMAT';
    };
    is( Developer::Dashboard::GoRoutine::_format_for_ptr(123), $format_ref,
        'format materializer looks up a format reference by its shared name' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_node_kind = sub { 'code' };
    local *Developer::Dashboard::GoRoutine::_shared_node_class = sub { undef };
    local *Developer::Dashboard::GoRoutine::_shared_code_call = sub {
        return join q{:}, @_;
    };
    my $shared_code = Developer::Dashboard::GoRoutine::_value_for_ptr(123);
    is( $shared_code->('argument'), '123:argument',
        'shared code proxy delegates calls to the native call adapter' );
}

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

{
    my @dispatches;
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::_shared_handle_remote = sub {
        my ( $ptr, $operation, @args ) = @_;
        push @dispatches, [ $ptr, $operation, @args ];
        return ( undef, undef ) if $operation eq 'READ' && $args[0] == 0;
        return ( 3, 'abc' ) if $operation eq 'READ';
        return ('one', 'two') if $operation eq 'READLINE_LIST';
        return 'line' if $operation eq 'READLINE_SCALAR';
        return 'character' if $operation eq 'GETC';
        return 2 if $operation eq 'WRITE';
        return 'position' if $operation eq 'TELL';
        return $operation eq 'EOF' ? 1 : 1;
    };

    my $handle = Developer::Dashboard::GoRoutine::SharedHandle->TIEHANDLE(42);
    is( $handle->PRINT('text'), 1, 'tied shared handle PRINT dispatches its arguments' );
    is( $handle->PRINTF('%s', 'text'), 1, 'tied shared handle PRINTF dispatches its arguments' );
    is( scalar $handle->READLINE, 'line',
        'tied shared handle READLINE selects scalar context' );
    is_deeply( [ $handle->READLINE ], ['one', 'two'],
        'tied shared handle READLINE selects list context' );
    is( $handle->GETC, 'character', 'tied shared handle GETC returns a character' );
    my $buffer = '____';
    is( $handle->READ($buffer, 3, 1), 3,
        'tied shared handle READ returns the dispatcher byte count' );
    is( $buffer, '_abc', 'tied shared handle READ updates the caller buffer at its offset' );
    my $default_offset_buffer;
    is( $handle->READ($default_offset_buffer, 3), 3,
        'tied shared handle READ accepts an omitted offset and buffer' );
    is( $default_offset_buffer, 'abc',
        'tied shared handle READ initializes an undefined caller buffer' );
    my $unchanged_buffer = 'unchanged';
    ok( !defined $handle->READ($unchanged_buffer, 0),
        'tied shared handle READ returns undef when the remote read has no result' );
    is( $unchanged_buffer, 'unchanged',
        'tied shared handle READ leaves the caller buffer unchanged without data' );
    is( $handle->WRITE('text', 2, 1), 2,
        'tied shared handle WRITE returns the dispatcher byte count' );
    is( $handle->WRITE('text', 2), 2,
        'tied shared handle WRITE defaults an omitted offset to zero' );
    is( $handle->SEEK(2, 0), 1, 'tied shared handle SEEK dispatches its arguments' );
    is( $handle->TELL, 'position', 'tied shared handle TELL returns the dispatcher result' );
    is( $handle->EOF, 1, 'tied shared handle EOF returns the dispatcher state' );
    is( $handle->FILENO, 1, 'tied shared handle FILENO returns the dispatcher descriptor' );
    is( $handle->BINMODE, 1, 'tied shared handle BINMODE dispatches without a layer' );
    is( $handle->BINMODE(':raw'), 1, 'tied shared handle BINMODE dispatches a layer' );
    is( $handle->CLOSE, 1, 'tied shared handle CLOSE dispatches cleanly' );
    is_deeply( [ map { $_->[1] } @dispatches ],
        [qw(PRINT PRINTF READLINE_SCALAR READLINE_LIST GETC READ READ READ WRITE WRITE SEEK TELL EOF FILENO BINMODE BINMODE CLOSE)],
        'tied shared handle wrappers preserve each operation name' );
}

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
    local *Developer::Dashboard::GoRoutine::_routine_kill = sub {
        return 0 if $routine_state->{killed};
        $routine_state->{killed} = 1;
        return 1;
    };
    local *Developer::Dashboard::GoRoutine::_routine_timeout = sub { $routine_state->{timeout} = $_[1] };
    local *Developer::Dashboard::GoRoutine::_routine_status = sub { $routine_state->{status} };
    my $routine = bless $routine_state, 'Developer::Dashboard::GoRoutine::Routine';
    ok( $routine->is_running, 'routine wrapper reports its mocked running state' );
    $routine_state->{running} = 0;
    ok( !$routine->is_running, 'routine wrapper reports its mocked stopped state' );
    $routine_state->{running} = 1;
    is( $routine->age, 2.5, 'routine wrapper reports its mocked age' );
    ok( $routine->kill, 'routine wrapper requests cancellation' );
    ok( !$routine->kill, 'routine wrapper reports a rejected duplicate cancellation' );
    is( $routine->timeout(0.25), $routine, 'valid timeout returns the routine for chaining' );
    is( $routine_state->{timeout}, 0.25, 'valid timeout forwards a numeric value' );
    is( $routine->status, 'running', 'routine wrapper returns the native status' );
    ok( !$routine->is_killed, 'running routine is not marked as killed' );
    $routine_state->{status} = 'timed_out';
    ok( $routine->is_killed, 'timed-out routine is marked as killed' );
}

for my $bad_timeout ( undef, [], 'not-a-number', 'NaN', 'Inf', '1e999', -1 ) {
    my $routine = bless {}, 'Developer::Dashboard::GoRoutine::Routine';
    my $ok = eval { $routine->timeout($bad_timeout); 1 };
    ok( !$ok, 'invalid timeout is rejected' );
    like( $@, qr/timeout\(\) requires a non-negative number/, 'invalid timeout has a clear diagnostic' );
}

{
    package Local::NaNTimeout;
    use overload
        '""' => sub { return '1' },
        '0+' => sub { return POSIX::nan() },
        fallback => 1;
    package main;

    my $routine = bless {}, 'Developer::Dashboard::GoRoutine::Routine';
    my $nan_timeout = bless {}, 'Local::NaNTimeout';
    my $ok = eval { $routine->timeout($nan_timeout); 1 };
    ok( !$ok, 'timeout rejects a value that stringifies numerically but numifies to NaN' );
    like( $@, qr/timeout\(\) requires a non-negative number/,
        'NaN timeout rejection uses the public validation diagnostic' );
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

    my $unsupported_scalar = eval {
        Developer::Dashboard::GoRoutine::_share_many('ordinary value');
        1;
    };
    ok( !$unsupported_scalar, '_share_many rejects a non-reference value' );
    like( $@, qr/expects scalar, array, or hash/,
        'non-reference rejection names the accepted shared types' );
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
overload, shared-node type dispatch, and routine-handle wrapper code in
C<Developer::Dashboard::GoRoutine> without starting worker threads. The
separate integration tests exercise real worker and shared-object concurrency
outside Devel::Cover instrumentation. It also verifies handle-class and
regexp-blessing preservation, explicit failure when an IO handle cannot be
materialized, forward concatenation evaluation, upgraded UTF-8 scalar storage,
unknown-operation rejection, and each public C<is_killed> status classification. Array
coverage includes proxy references, applied and pending shared values, reverse
operations, UTF-8 values, and splice-boundary normalization. Channel and
routine wrappers are exercised in both positive and negative states.

=head1 WHY IT EXISTS

Devel::Cover cannot safely instrument Perl ithreads, so the concurrency tests
run in a separate native-thread suite. Without this thread-free contract test,
the Perl code that adapts native shared nodes to ordinary Perl references would
not be measured by the four-metric library coverage gate.

=head1 WHEN TO USE

Run this test in the project Docker service whenever GoRoutine proxy methods,
operator overloads, tied container operations, timeout validation, or routine
handle wrappers or array-boundary behavior change:

    d2 docker compose exec dev prove -lv t/233-goroutine-shared-object-coverage.t

=head1 HOW TO USE

The test requires the checkout's built XS object and loads it through the
existing C<Developer::Dashboard::HtmlEscape> distribution module. It uses
ordinary Perl operations against shared values but replaces only the native
routine-handle XSUB calls with local in-process stubs, so it never creates a
worker thread. Its dispatch checks prove that glob, IO, and format node kinds
reach their respective materializers with the correct shared handle and class
metadata. Materializer edge checks cover blessed IO and regexp values as well
as empty optional class/name values, invalid descriptor duplication, and the
explicit missing-IO-slot error. Shared-reference checks reject non-reference
inputs. Mocked routine statuses cover killed,
timed-out, and normally exited handles without loading Devel::Cover into an
ithread. Proxy storage assertions cover already-applied and pending shared
values, UTF-8 scalars, reverse operations, and array splice offset/length
clamping. Timeout validation rejects overloaded values whose string form looks
numeric but whose numeric form is NaN. Channel and routine handle stubs exercise both sides of their
boolean state results. Run it with the normal test library paths and the
coverage gate will include its Perl-module execution in the lib-only report.

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
