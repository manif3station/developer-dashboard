#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use lib 'lib';

use Developer::Dashboard::ActionRunner;
use Developer::Dashboard::GoRoutine ();
use Developer::Dashboard::JSON qw(json_encode);

my $run = sub {
    return Developer::Dashboard::ActionRunner->run_background_supervisor(
        json_encode( {
            command    => 'echo supervisor',
            cwd        => '.',
            timeout_ms => $_[0],
            log        => '/tmp/actionrunner-supervisor-test.log',
        } )
    );
};

for my $payload (
    '[]',
    json_encode({}),
    json_encode({ command => 'echo x' }),
    json_encode({ command => 'echo x', cwd => '.' }),
    json_encode({ command => 'echo x', cwd => '.', timeout_ms => 0 }),
) {
    my $ok = eval { Developer::Dashboard::ActionRunner->run_background_supervisor($payload); 1 };
    ok( !$ok, 'invalid supervisor payload is rejected' );
    like( $@, qr/(?:must be a hash|missing (?:command|cwd|timeout_ms|log))/, 'payload error explains the invalid input' );
}

{
    no warnings 'redefine';
    my @calls;
    my $polls = 0;
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 4204 };
    local *Developer::Dashboard::GoRoutine::process_exited = sub {
        ++$polls;
        select undef, undef, undef, 1.1 if $polls == 1;
        return 0;
    };
    local *Developer::Dashboard::GoRoutine::terminate_process = sub { push @calls, [ terminate => @_ ] };
    local *Developer::Dashboard::GoRoutine::wait_process = sub { push @calls, [ wait => @_ ]; return 0 };
    is( $run->(1), 124, 'supervisor reports timeout when the child ignores TERM' );
    is_deeply( [ map { $_->[0] } @calls ], [ 'terminate', 'terminate', 'wait' ],
        'timeout escalates from TERM to KILL before reaping a child that remains alive' );
    is_deeply( [ map { $_->[2] } grep { $_->[0] eq 'terminate' } @calls ], [ 'TERM', 'KILL' ],
        'a child that remains alive after TERM receives KILL' );
}

{
    no warnings 'redefine';
    my @calls;
    local *Developer::Dashboard::GoRoutine::spawn = sub {
        push @calls, [ spawn => $_[0], $_[1] ];
        return 4201;
    };
    local *Developer::Dashboard::GoRoutine::process_exited = sub { return 1 };
    local *Developer::Dashboard::GoRoutine::wait_process = sub { push @calls, [ wait => $_[0] ]; return 7 };
    is( $run->(0), 7, 'supervisor returns a normally exited child status' );
    is( $calls[0][0], 'spawn', 'supervisor launches the command through GoRoutine' );
    is( $calls[1][0], 'wait', 'supervisor collects the child result' );
}

{
    no warnings 'redefine';
    my $polls = 0;
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 4206 };
    local *Developer::Dashboard::GoRoutine::process_exited = sub { return ++$polls > 1 };
    local *Developer::Dashboard::GoRoutine::wait_process = sub { return 11 };
    is( $run->(5000), 11, 'supervisor waits for a child that exits before its deadline' );
    is( $polls, 2, 'supervisor checks its deadline while the child is still running' );
}

{
    no warnings 'redefine';
    my @calls;
    my $polls = 0;
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 4202 };
    local *Developer::Dashboard::GoRoutine::process_exited = sub {
        ++$polls;
        select undef, undef, undef, 1.1 if $polls == 1;
        return $polls > 1;
    };
    local *Developer::Dashboard::GoRoutine::terminate_process = sub { push @calls, [ terminate => @_ ] };
    local *Developer::Dashboard::GoRoutine::wait_process = sub { push @calls, [ wait => @_ ]; return 0 };
    is( $run->(1), 124, 'supervisor returns timeout status after its deadline' );
    is_deeply( [ map { $_->[0] } @calls ], [ 'terminate', 'wait' ],
        'timeout sends TERM and reaps a child that exits during the grace period' );
    is_deeply( [ map { $_->[2] } grep { $_->[0] eq 'terminate' } @calls ], ['TERM'],
        'the timeout path does not send KILL after the child exits during grace' );
}

{
    no warnings 'redefine';
    my @calls;
    my $first_poll = 1;
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 4203 };
    local *Developer::Dashboard::GoRoutine::process_exited = sub {
        if ($first_poll) {
            $first_poll = 0;
            kill 'TERM', $$;
            return 0;
        }
        return 1;
    };
    local *Developer::Dashboard::GoRoutine::terminate_process = sub { push @calls, [ terminate => @_ ] };
    local *Developer::Dashboard::GoRoutine::wait_process = sub { push @calls, [ wait => @_ ]; return 0 };
    is( $run->(0), 0, 'supervisor stops on a forwarded TERM request' );
    is_deeply( [ map { $_->[0] } @calls ], [ 'terminate', 'wait' ],
        'signal handling terminates then reaps the command child' );
}

{
    no warnings 'redefine';
    my @calls;
    my $first_poll = 1;
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 4208 };
    local *Developer::Dashboard::GoRoutine::process_exited = sub {
        if ($first_poll) {
            $first_poll = 0;
            kill 'TERM', $$;
        }
        return 0;
    };
    local *Developer::Dashboard::GoRoutine::terminate_process = sub { push @calls, [ terminate => @_ ] };
    local *Developer::Dashboard::GoRoutine::wait_process = sub { push @calls, [ wait => @_ ]; return 0 };
    is( $run->(0), 0, 'supervisor stops on TERM when the command child ignores termination' );
    is_deeply( [ map { $_->[0] } @calls ], [ 'terminate', 'terminate', 'wait' ],
        'signal handling escalates to KILL before reaping a child that remains alive' );
    is_deeply( [ map { $_->[2] } grep { $_->[0] eq 'terminate' } @calls ], [ 'TERM', 'KILL' ],
        'signal shutdown sends KILL only after the TERM grace period expires' );
}

{
    no warnings 'redefine';
    my @calls;
    my $first_poll = 1;
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 4205 };
    local *Developer::Dashboard::GoRoutine::process_exited = sub {
        if ($first_poll) {
            $first_poll = 0;
            kill 'INT', $$;
            return 0;
        }
        return 1;
    };
    local *Developer::Dashboard::GoRoutine::terminate_process = sub { push @calls, [ terminate => @_ ] };
    local *Developer::Dashboard::GoRoutine::wait_process = sub { push @calls, [ wait => @_ ]; return 0 };
    is( $run->(0), 0, 'supervisor stops on a forwarded INT request' );
    is_deeply( [ map { $_->[0] } @calls ], [ 'terminate', 'wait' ],
        'INT handling terminates then reaps the command child' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::GoRoutine::process_exited = sub { return 1 };
    ok( Developer::Dashboard::ActionRunner::_wait_background_child_exit( 4207, 0 ),
        'bounded child wait reports an exit detected at its final poll' );
}

done_testing;

__END__

=head1 NAME

t/252-actionrunner-supervisor-coverage.t - exercise detached action supervisor exits

=head1 PURPOSE

Test the background ActionRunner supervisor's payload validation, successful
child completion, timeout handling, and forwarded termination signal handling.
GoRoutine calls are replaced with deterministic local stubs so these branches,
including TERM-to-KILL escalation when a child ignores termination, are covered
without leaving child processes running.

=head1 WHY IT EXISTS

The supervisor owns detached command lifecycle behavior. A regression in its
timeout or signal branch could leave commands running after the page action has
stopped. Direct unit coverage verifies the TERM grace period, conditional KILL
escalation, and child reaping without relying on process timing or unmanaged
external processes.

=head1 WHEN TO USE

Run when ActionRunner's background supervisor, payload contract, or GoRoutine
process API changes.

=head1 HOW TO USE

    d2 docker compose exec dev prove -lv t/252-actionrunner-supervisor-coverage.t

=head1 WHAT USES IT

The normal distribution test suite runs this file. It covers the supervisor
called by detached browser/page actions while isolating operating-system
process creation behind mocked GoRoutine entry points.

=head1 EXAMPLES

Run the isolated lifecycle regression:

    d2 docker compose exec dev prove -lv t/252-actionrunner-supervisor-coverage.t

Run it alongside process migration checks:

    d2 docker compose exec dev prove -lv t/246-no-direct-perl-fork.t t/252-actionrunner-supervisor-coverage.t

=cut
