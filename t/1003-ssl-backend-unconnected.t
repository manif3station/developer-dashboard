use strict;
use warnings;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use File::Temp qw(tempdir);
use IO::Socket::INET;
use Socket qw(AF_UNIX PF_UNSPEC SOCK_STREAM);
use Test::More;

# Group 3 (Mac install failure, Michael's other Mac, perl 5.44): the
# existing t/17 checks (lines 707-708) fail there because
# IO::Socket::INET->new with Timeout => 5 returns a socket even when the
# connect to 127.0.0.1:9 was refused, so the Server.pm die ("Unable to
# connect to internal SSL backend") never fires and the handler returns 1
# with $@ empty. They pass on Jenkins (perl 5.38.2, where new() returns
# undef on a refused connect), so they cannot prove the fix there. The
# fix (R105 decision) is a product change in Server.pm: after new(), verify
# the socket is actually connected and die with the same message if it is
# not. This test simulates the quirk by making new() return a socket that
# is NOT connected, and asserts the handler dies with the backend message.
# Before the fix the handler does not die with that message, so the test
# fails; after the fix it dies, so the test passes — making the fix provable
# on Jenkins.

my $server_loaded = eval {
    require Developer::Dashboard::Web::Server;
    1;
};
plan skip_all => 'Developer::Dashboard::Web::Server is unavailable'
  if !$server_loaded;

{
    package Local::SSLTestApp;

    sub new { bless {}, shift }

    sub authorize_request { return; }

    sub root_response {
        return [ 200, 'text/plain; charset=utf-8', 'OK', {} ];
    }
}

my $temp_home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $temp_home;
local $SIG{PIPE} = 'IGNORE';

my $server = Developer::Dashboard::Web::Server->new(
    app     => Local::SSLTestApp->new,
    host    => '127.0.0.1',
    port    => 17893,
    workers => 1,
    ssl     => 1,
);
my $daemon = Developer::Dashboard::Web::Server::Daemon->new(
    host          => '127.0.0.1',
    port          => 17893,
    internal_host => '127.0.0.1',
    internal_port => 9,
);

# _tls_client()
# Returns one end of a socketpair with a TLS first byte written and the
# peer half-closed, exactly as t/17 Test 12 drives the handler.
sub _tls_client {
    socketpair( my $client, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
      or die "socketpair failed: $!";
    my $bytes = syswrite( $peer, "\x16" );
    die "Unable to write TLS handshake byte: $!" if !defined $bytes || $bytes != 1;
    shutdown( $peer, 1 ) or die "Unable to half-close TLS peer: $!";
    close $peer or die "Unable to close TLS peer: $!";
    return $client;
}

# _run_handler($client)
# Runs the frontend handler on one TLS client and returns (ok, error):
# ok is true when the handler returns, error holds $@ when it dies.
# Guarded by a 10-second alarm: before the fix, an unconnected backend
# socket is never writable under select, so the proxy step spins forever
# instead of dying — without the alarm the test would hang the suite.
# The handler normally completes in milliseconds, so a timeout is a
# failure, never a pass.
sub _run_handler {
    my ($client) = @_;
    local $SIG{ALRM} = sub { die "handler timed out after 10s\n" };
    alarm(10);
    my $ok = eval {
        $server->_handle_ssl_frontend_client( client => $client, daemon => $daemon );
        1;
    };
    my $error = $@;
    alarm(0);
    return ( $ok, $error );
}

# Control: with the real IO::Socket::INET->new, the refused connect to
# 127.0.0.1:9 returns undef and the handler dies with the backend message,
# as t/17 Test 12 already covers. This proves the harness works.
{
    my $client = _tls_client();
    my ( $ok, $error ) = _run_handler($client);
    ok( !$ok, 'control: frontend client handler dies when the internal TLS backend cannot be reached' );
    like( $error, qr/Unable to connect to internal SSL backend/, 'control: frontend client handler reports backend-connect failures explicitly' );
    close $client or die "Unable to close TLS client: $!";
}

# Sanity: the simulated quirk socket really is unconnected — a bare
# IO::Socket::INET->new() returns a socket object whose connected() is
# false. If this ever changes, the simulation below is no longer faithful.
{
    my $unconnected = IO::Socket::INET->new();
    ok( defined $unconnected, 'quirk socket: an unconnected socket object is created' );
    ok( !$unconnected->connected, 'quirk socket: the simulated socket is not connected' );
}

# The quirk: new() returns an unconnected socket for the backend connect
# only (identified by the daemon's internal host and port); every other
# call delegates to the real constructor. This is what Michael's Mac does
# with Timeout => 5 when the connect is refused.
{
    my $orig_new = \&IO::Socket::INET::new;
    local *IO::Socket::INET::new = sub {
        my ( $class, %args ) = @_;
        if ( ( $args{PeerAddr} // '' ) eq $daemon->internal_sockhost
            && ( $args{PeerPort} // 0 ) == $daemon->internal_sockport )
        {
            return $orig_new->('IO::Socket::INET');
        }
        return $orig_new->( $class, %args );
    };

    my $client = _tls_client();
    my ( $ok, $error ) = _run_handler($client);
    ok( !$ok, 'quirk: frontend client handler dies when new() returns an unconnected backend socket' );
    like( $error, qr/Unable to connect to internal SSL backend/, 'quirk: frontend client handler reports the unconnected backend explicitly' );
    close $client or die "Unable to close TLS client: $!";
}

done_testing();
