use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use IO::Select;

use Developer::Dashboard::GoRoutine;

# Micro-repro for the t/238 test-57 Windows hang (build #132: Windows
# printed ok 1..56 then no output for 3 minutes inside wait_all()).
# Every wait here is bounded: pump(0.2) at most 25 times, never wait_all,
# so this file fails with diagnostics instead of hanging. It distinguishes
#   (a) the callback never fires (engine _ev_wait never reports the IO)
#   (b) the callback fires but wait_all never returns.
# Phase 1 (single readable) and phase 3 (single writable) isolate the
# Windows select path from the two-node dual-trigger shape; phase 2 calls
# _ev_wait directly to separate the engine from pump/dispatch; phase 4
# is the exact test-57 shape. Probe only: never merge this file.

diag "OS: $^O perl $^V";

sub make_pair {
    my $server = IO::Socket::INET->new(
        Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0,
        Proto => 'tcp', ReuseAddr => 1,
    ) or die "cannot listen: $!";
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $server->sockport, Proto => 'tcp',
    ) or die "cannot connect: $!";
    my $accepted = $server->accept or die "cannot accept: $!";
    $client->autoflush(1);
    return ($server, $client, $accepted);
}

# Bounded pump loop: at most 25 x 0.2s. Returns iterations used.
sub pump_until {
    my ($done) = @_;
    my $used = 0;
    for my $i (1 .. 25) {
        my $p = Developer::Dashboard::GoRoutine::pump(0.2);
        $used = $i;
        diag "  pump $i progress=$p done=" . ($done->() ? 1 : 0);
        last if $done->();
    }
    return $used;
}

# Phase 0: what fd values does Perl hand the engine, and what is the
# real Windows SOCKET for the same handle (CRT fd vs SOCKET is the
# prime suspect: Winsock select() needs a SOCKET, Perl fileno() on a
# socket returns a CRT fd on Strawberry Perl).
{
    my ($server, $client, $accepted) = make_pair();
    diag "phase 0: fileno accepted=" . fileno($accepted)
        . " fileno client=" . fileno($client);
    if ($^O eq 'MSWin32') {
        my $sock = eval {
            require Win32::API;
            my $fn = Win32::API->new('msvcrt', '_get_osfhandle', 'I', 'N')
                or die "no _get_osfhandle: $^E";
            $fn->Call(fileno($accepted));
        };
        diag "phase 0: _get_osfhandle(accepted)="
            . (defined $sock ? $sock : "unavailable: $@");
    }
    close $accepted;
    close $client;
    close $server;
}

# Phase 1: single readable trigger through pump().
my $ran1 = 0;
{
    my ($server, $client, $accepted) = make_pair();
    print $client "x";
    diag "phase 1: fileno accepted=" . fileno($accepted);
    my $sel = IO::Select->new($accepted);
    my @ready = $sel->can_read(0);
    diag "phase 1: Perl IO::Select can_read(0) says "
        . (@ready ? "READABLE (control passes)" : "NOT READABLE (control fails)");
    ok(@ready, 'control: Perl select sees the accepted socket readable');
    my $routine = go sub { $ran1++ }, { readable => $accepted };
    my $used = pump_until(sub { $ran1 == 1 });
    diag "phase 1: ran=$ran1 after $used bounded pumps, status="
        . $routine->status;
    $routine->kill if $routine->status eq 'pending';
    is($ran1, 1, 'phase 1: single readable trigger fires through pump');
    close $accepted;
    close $client;
    close $server;
}

# Phase 2: direct _ev_wait on a fresh pair, engine only, no pump.
{
    my ($server, $client, $accepted) = make_pair();
    print $client "x";
    my $ran2 = 0;
    my $routine = go sub { $ran2++ }, { readable => $accepted };
    my @due;
    if (defined &Developer::Dashboard::GoRoutine::_ev_wait) {
        @due = Developer::Dashboard::GoRoutine::_ev_wait(500);
    }
    else {
        diag "phase 2: _ev_wait not callable from Perl";
    }
    diag "phase 2: direct _ev_wait(500) returned [@due] for routine id "
        . $routine->{id};
    is(scalar @due, 1, 'phase 2: direct _ev_wait reports one due id');
    is($due[0], $routine->{id},
        'phase 2: direct _ev_wait reports the readable routine id')
        if @due;
    $routine->kill if $routine->status eq 'pending';
    close $accepted;
    close $client;
    close $server;
}

# Phase 3: single writable trigger through pump().
my $ran3 = 0;
{
    my ($server, $client, $accepted) = make_pair();
    my $routine = go sub { $ran3++ }, { writable => $client };
    my $used = pump_until(sub { $ran3 == 1 });
    diag "phase 3: ran=$ran3 after $used bounded pumps, status="
        . $routine->status;
    $routine->kill if $routine->status eq 'pending';
    is($ran3, 1, 'phase 3: single writable trigger fires through pump');
    close $accepted;
    close $client;
    close $server;
}

# Phase 4: the exact test-57 shape: one routine, readable + writable.
my $ran4 = 0;
{
    my ($server, $client, $accepted) = make_pair();
    print $client "x";
    my $routine = go sub { $ran4++ },
        { readable => $accepted, writable => $client };
    my $used = pump_until(sub { $ran4 == 1 });
    diag "phase 4: ran=$ran4 after $used bounded pumps, status="
        . $routine->status;
    $routine->kill if $routine->status eq 'pending';
    is($ran4, 1,
        'phase 4: routine with both readable and writable triggers runs once');
    is($routine->status, 'done',
        'phase 4: both-direction routine finishes done');
    close $accepted;
    close $client;
    close $server;
}

done_testing;
