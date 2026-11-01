use strict;
use warnings;

use Test::More;
use Developer::Dashboard::GoRoutine qw(go share wait_all);

my $channel_factory = Developer::Dashboard::GoRoutine->can('channel');
ok( $channel_factory, 'GoRoutine exposes the channel factory' );
ok(
    ( grep { $_ eq 'channel' } @Developer::Dashboard::GoRoutine::EXPORT ) > 0,
    'channel is exported by the existing GoRoutine module',
);

SKIP: {
    skip 'channel API is not integrated yet', 11 if !$channel_factory;

    my $unbuffered = $channel_factory->();
    isa_ok( $unbuffered, 'Developer::Dashboard::GoRoutine::Channel' );
    is( $unbuffered->capacity, 0, 'channel() creates an unbuffered channel' );

    share my $received = '';
    my $receiver = go sub { $received = $unbuffered->receive };
    $unbuffered->send('rendezvous');
    wait_all();
    is( $received, 'rendezvous', 'unbuffered send waits for a receiver' );
    is( $receiver->status, 'done', 'receiver routine finishes after rendezvous' );

    my $buffered = $channel_factory->(2);
    is( $buffered->capacity, 2, 'channel(N) creates the requested buffer capacity' );
    $buffered->send('first');
    $buffered->send('second');
    is( $buffered->size, 2, 'buffered sends do not wait until the buffer is full' );
    my ( $first, $first_ok ) = $buffered->receive;
    my ( $second, $second_ok ) = $buffered->receive;
    is_deeply( [ $first, $first_ok, $second, $second_ok ],
        [ 'first', 1, 'second', 1 ], 'buffered receive preserves FIFO values and open status' );

    $buffered->close;
    my ( $closed_value, $closed_ok ) = $buffered->receive;
    is_deeply( [ $closed_value, $closed_ok ], [ undef, 0 ],
        'receive from a closed drained channel reports closed state' );
    my $send_error = eval { $buffered->send('after-close'); 1 } ? '' : $@;
    like( $send_error, qr/closed channel/i, 'sending after close fails explicitly' );

    my $waiting = $channel_factory->();
    my $blocked = go sub { $waiting->receive };
    select undef, undef, undef, 0.05;
    ok( $blocked->kill, 'a routine blocked on receive accepts cancellation' );
    wait_all();
    is( $blocked->status, 'killed', 'a cancelled channel waiter terminates cleanly' );
}

done_testing;

__END__

=head1 NAME

t/244-goroutine-channels.t - GoRoutine 0.12 channel contract tests

=head1 PURPOSE

Verifies the GoRoutine channel API: unbuffered rendezvous, buffered FIFO
transport, close behavior, explicit errors for sends after close, and
cancellation while a routine is blocked on receive.

=head1 WHY IT EXISTS

The GoRoutine 0.12 package adds process-wide channels as a first-class API.
Dashboard currently exposes GoRoutine controls and shared object graphs, so
this test prevents an incomplete integration that omits channels or changes
their Go-style blocking and close semantics.

=head1 WHEN TO USE

Run when changing the Dashboard GoRoutine XS, shared transport, channel
implementation, or module exports. The test should fail against a build that
does not expose the channel API and pass only when the channel lifecycle is
implemented.

=head1 HOW TO USE

Build the XS bundle and run this test in the dev Docker service:

  d2 docker compose exec dev prove -Iblib/lib -Iblib/arch -Ilib -lv t/244-goroutine-channels.t

=head1 WHAT USES IT

Dashboard asynchronous code may use channels for cancellation-aware
communication between GoRoutine workers. The test exercises only the public
Developer::Dashboard::GoRoutine API and does not depend on a separate module
name or extension object.

=head1 EXAMPLES

Run this contract alone:

  prove -Iblib/lib -Iblib/arch -Ilib -lv t/244-goroutine-channels.t

Run it together with the shared-object and routine-control contracts:

  prove -Iblib/lib -Iblib/arch -Ilib -lv t/237-goroutine-shared-objects.t t/238-goroutine-routine-controls.t t/244-goroutine-channels.t

=cut
