use strict;
use warnings;
use utf8;
use Test::More;
use Scalar::Util qw(reftype);

binmode STDOUT, ':encoding(UTF-8)';

use Developer::Dashboard::GoRoutine;

my $state;
my $shared = eval {
    share $state = {
        count  => 0,
        jobs   => [],
        nested => { ready => 0, text => 'start' },
    };
    1;
};

ok $shared, 'share accepts and wraps a nested hash and array object graph'
  or diag "share failed: $@";

my $tied_proxy = $shared && ref($state) && ( reftype($state) || '' ) eq 'HASH'
  ? tied( %{$state} )
  : undef;
my $graph_proxy = $tied_proxy
  && eval { $tied_proxy->isa('Developer::Dashboard::GoRoutine::SharedProxyBase') };
ok $graph_proxy, 'share returns a dereferenceable shared object-graph proxy';

SKIP: {
    skip 'shared reference graph implementation is unavailable', 26
      unless $graph_proxy;

    for my $id (1 .. 12) {
        go sub {
            $state->{count}++;
            $state->{nested}{ready} = 1;
            push $state->{jobs}->@*, { id => $id, status => 'done' };
        };
    }

    wait_all();

    is 0 + $state->{count}, 12,
      'nested shared scalar updates remain visible and atomic';
    is 0 + $state->{nested}{ready}, 1,
      'a nested shared hash update is visible to the parent';
    is scalar($state->{jobs}->@*), 12,
      'concurrent nested shared array pushes are retained';

    my @rows = sort { 0 + $a->{id} <=> 0 + $b->{id} }
      $state->{jobs}->@*;
    is_deeply [ map { "$_->{id}:$_->{status}" } @rows ],
      [ map { "$_:done" } 1 .. 12 ],
      'each worker can publish a nested hash into the shared array';

    $state->{nested}{text} .= '-visible';
    is "$state->{nested}{text}", 'start-visible',
      'a shared nested string can be updated using normal Perl syntax';

    $state->{unicode} = '茶葉';
    $state->{unicode} .= '茶';
    is "$state->{unicode}", '茶葉茶',
      'shared nested strings preserve Perl Unicode character semantics';

    my $captured_unicode = '✅';
    share my $worker_unicode = '';
    share my $worker_unicode_flag = 0;
    share my $worker_unicode_codepoints = '';
    go sub {
        $worker_unicode_flag = utf8::is_utf8($captured_unicode) ? 1 : 0;
        $worker_unicode_codepoints = join ',', unpack 'U*', $captured_unicode;
        $worker_unicode = $captured_unicode;
    };
    wait_all();
    is 0 + $worker_unicode_flag, 1,
      'worker closure capture retains the source UTF-8 flag';
    is "$worker_unicode_codepoints", '9989',
      'worker closure capture retains Unicode code points';
    is "$worker_unicode", '✅',
      'worker closure captures preserve Unicode character semantics';

    $state->{temporary} = { value => 31 };
    ok exists $state->{temporary}, 'exists observes shared hash keys';
    is_deeply [ sort keys %{$state} ],
      [ qw(count jobs nested temporary unicode) ],
      'hash iteration returns a stable key snapshot';
    my $removed = delete $state->{temporary};
    is 0 + $removed->{value}, 31, 'delete returns the removed shared node';
    ok !exists $state->{temporary}, 'delete removes a key from the shared hash';

    {
        package Local::GoRoutineSharedCounter;

        sub new {
            my ($class) = @_;
            return bless { value => 0, events => [] }, $class;
        }

        sub increment {
            my ($self) = @_;
            $self->{value}++;
            push $self->{events}->@*, 0 + $self->{value};
        }
    }

    my $counter = eval {
        share my $object = Local::GoRoutineSharedCounter->new;
        $object;
    };
    ok $counter, 'share accepts an ordinary blessed hash-based Perl object'
      or diag "sharing blessed object failed: $@";

    if ($counter) {
        for (1 .. 8) {
            go sub { $counter->increment };
        }
        wait_all();
        is 0 + $counter->{value}, 8,
          'methods update blessed shared-object state across workers';
        is scalar($counter->{events}->@*), 8,
          'blessed shared-object nested arrays retain worker updates';
        isa_ok $counter, 'Local::GoRoutineSharedCounter';
    }
    else {
        skip 'blessed shared objects are not implemented yet', 3;
    }

    my $scalar_ref = eval {
        share my $reference = \(my $value = 7);
        $reference;
    };
    ok $scalar_ref, 'share accepts a scalar-reference value'
      or diag "sharing scalar reference failed: $@";

    if ($scalar_ref) {
        go sub { $$scalar_ref += 5 };
        wait_all();
        is 0 + $$scalar_ref, 12,
          'the referenced scalar is shared and updated across workers';
    }
    else {
        skip 'shared scalar references are not implemented yet', 1;
    }

    my $aliased_child = { value => 0 };
    my $alias_graph = eval {
        share my $value = { left => $aliased_child, right => $aliased_child };
        $value;
    };
    ok $alias_graph, 'share accepts repeated references in one object graph'
      or diag "sharing aliased graph failed: $@";
    if ($alias_graph) {
        $alias_graph->{left}{value} = 19;
        is 0 + $alias_graph->{right}{value}, 19,
          'multiple references to one source node remain aliases';
    }
    else {
        skip 'shared object graph aliases are unavailable', 1;
    }

    my $cycle_source = {};
    $cycle_source->{self} = $cycle_source;
    my $cycle = eval {
        share my $value = $cycle_source;
        $value;
    };
    ok $cycle, 'share accepts a cyclic hash reference graph'
      or diag "sharing cyclic graph failed: $@";
    if ($cycle) {
        $cycle->{self}{value} = 23;
        is 0 + $cycle->{value}, 23,
          'cyclic references resolve to the original shared node';
    }
    else {
        skip 'shared object graph cycles are unavailable', 1;
    }

    {
        package Local::GoRoutineSharedArrayObject;
        sub new { bless [0], $_[0] }
        sub bump { ++$_[0][0] }
    }
    my $array_object = eval {
        share my $value = Local::GoRoutineSharedArrayObject->new;
        $value;
    };
    ok $array_object, 'share accepts a blessed array-backed object'
      or diag "sharing blessed array failed: $@";
    if ($array_object) {
        go sub { $array_object->bump } for 1 .. 6;
        wait_all();
        is 0 + $array_object->[0], 6,
          'blessed array methods mutate shared array state across workers';
        isa_ok $array_object, 'Local::GoRoutineSharedArrayObject';
    }
    else {
        skip 'blessed array sharing is unavailable', 2;
    }

    my $list = eval {
        share my $value = [ 1, 2, 3, 4 ];
        $value;
    };
    ok $list, 'share accepts an array for standard mutation operations'
      or diag "sharing array failed: $@";
    if ($list) {
        my @removed = splice $list->@*, 1, 2, 8, 9;
        is_deeply [ map { 0 + $_ } @removed ], [ 2, 3 ],
          'splice returns removed shared array values';
        is_deeply [ map { 0 + $_ } $list->@* ], [ 1, 8, 9, 4 ],
          'splice updates shared array contents';
    }
    else {
        skip 'shared array mutations are unavailable', 2;
    }
}

my $base = 7;
my $callbacks = eval {
    share my $value = {
        callback => sub {
            my ($number) = @_;
            return $base + $number;
        },
    };
    $value;
};
ok $callbacks, 'share accepts CODE references in a shared object graph'
  or diag "sharing CODE references failed: $@";
if ($callbacks) {
    is ref( $callbacks->{callback} ), 'CODE',
      'shared CODE reference materializes as a callable Perl code reference';
    my $parent_result = eval { $callbacks->{callback}->(5) };
    is $parent_result, 12,
      'shared closure preserves its captured lexical in the parent interpreter';
    diag "calling shared closure in parent failed: $@" if $@;
}
else {
    fail 'shared CODE reference materializes as a callable Perl code reference';
    fail 'shared closure preserves its captured lexical in the parent interpreter';
}

share my $callback_worker_result = 0;
share my $callback_worker_error = '';
if ($callbacks) {
    go sub {
        my $result = eval { $callbacks->{callback}->(8) };
        if ($@) {
            $callback_worker_error = "$@";
        }
        else {
            $callback_worker_result = $result;
        }
    };
    wait_all();
    is 0 + $callback_worker_result, 15,
      'shared CODE reference can be called from a GoRoutine worker';
    diag "calling shared closure in worker failed: $callback_worker_error"
      if $callback_worker_error;
}
else {
    fail 'shared CODE reference can be called from a GoRoutine worker';
}

share my $worker_created_state = {};
share my $worker_created_error = '';
go sub {
    my $inside_worker = 100;
    eval {
        $worker_created_state->{callback} = sub {
            my ($number) = @_;
            return $inside_worker + $number;
        };
    };
    $worker_created_error = "$@" if $@;
};
wait_all();
my $worker_callback = $worker_created_state->{callback};
is ref($worker_callback), 'CODE',
  'a CODE reference created inside a worker remains callable after it exits';
my $worker_callback_result = eval { $worker_callback->(23) };
is $worker_callback_result, 123,
  'worker-created closure retains its captured lexical';
diag "creating shared closure in worker failed: $worker_created_error"
  if $worker_created_error;
diag "calling worker-created shared closure failed: $@" if $@;

my $direct_callback_error = '';
my $direct_callback = eval { share my $value = sub { $_[0] * 2 }; $value };
$direct_callback_error = "$@" if $@;
is ref($direct_callback), 'CODE',
  'share accepts a CODE reference as a top-level scalar value';
my $direct_callback_result = eval { $direct_callback->(9) } if $direct_callback;
is $direct_callback_result, 18,
  'top-level shared CODE reference remains callable';
diag "sharing top-level CODE reference failed: $direct_callback_error"
  if $direct_callback_error;
diag "calling top-level shared CODE reference failed: $@" if $@;

done_testing;

__END__

=head1 NAME

237-goroutine-shared-objects.t - verify GoRoutine shared Perl object graphs

=head1 PURPOSE

This test protects the GoRoutine 0.12 contract that C<share> can expose Perl
reference data structures and callable CODE references through the shared
graph. It prevents the Dashboard integration from regressing to a scalar-only
implementation or silently dropping supported closure behavior.

=head1 WHY IT EXISTS

The Dashboard GoRoutine API must preserve the shared-reference behavior
defined by the 0.12 source package. A scalar-only test would miss broken
nested references, lost aliases, incorrect blessing, or container operations
that fail after crossing the XS interpreter boundary.

=head1 WHAT IT TESTS

The test exercises a nested hash containing a nested hash and array, concurrent
updates through ordinary Perl dereferencing, publication of nested hash
records from workers, Unicode character semantics, aliases and cycles,
preservation of blessed hash- and array-based object methods, standard hash and
array operations, scalar-reference sharing, callable CODE references,
closures captured by shared graphs, worker invocation of shared callbacks, and
closures created inside a worker. These are observable API behaviours, rather
than checks for private XS symbols.

=head1 WHEN TO USE

Run this test after building the Dashboard XS extension and whenever the
GoRoutine Perl or XS implementation changes. It must run in the project's
supported Docker development environment because the extension is compiled
native code.

=head1 HOW TO USE

    d2 docker compose exec dev prove -Iblib/lib -Iblib/arch -Ilib -lv t/237-goroutine-shared-objects.t

The project-level invocation is:

    d2 docker compose exec dev prove -Iblib/lib -Iblib/arch -Ilib -lv t/237-goroutine-shared-objects.t

=head1 EXAMPLES

The central example creates one shared object graph and updates it from
multiple C<go> callbacks:

    share my $state = { count => 0, rows => [] };
    go sub { $state->{count}++; push $state->{rows}->@*, { ok => 1 } };
    wait_all();

A second example shares an ordinary blessed data object whose state is made
only of Perl references:

    share my $counter = Counter->new;
    go sub { $counter->increment };
    wait_all();

=head1 WHAT USES IT

C<prove> runs this test as part of the distribution test suite. Developers use
it when changing C<Developer::Dashboard::GoRoutine>, the XS shared-graph
implementation, or the way worker interpreters access shared values.

=head1 RELATED TESTS

C<t/231-goroutine-integration.t> covers the scalar operator API. The supplied
0.12 archive's C<t/basic.t>, C<t/structures.t>, C<t/code_ref.t> and
C<t/shutdown.t> cover the source distribution independently. This test is the
Dashboard package-level contract for nested, blessed and callable shared values.

=cut
