package Developer::Dashboard::Web::Server;

use strict;
use warnings;

use HTTP::Daemon;
use HTTP::Status qw(status_message);

# new(%args)
# Constructs the local HTTP server wrapper.
# Input: app object plus optional host and port.
# Output: Developer::Dashboard::Web::Server object.
sub new {
    my ( $class, %args ) = @_;
    my $app  = $args{app}  || die 'Missing web app';
    my $host = $args{host} || '0.0.0.0';
    my $port = $args{port} || 7890;

    return bless {
        app  => $app,
        host => $host,
        port => $port,
    }, $class;
}

# run()
# Starts the HTTP daemon and serves requests until the daemon exits.
# Input: none.
# Output: true value when the server loop completes.
sub run {
    my ($self) = @_;

    my $daemon = $self->start_daemon;
    print "Developer Dashboard listening on ", $self->listening_url($daemon), "\n";
    return $self->serve_daemon($daemon);
}

# start_daemon()
# Creates the underlying HTTP::Daemon listener.
# Input: none.
# Output: HTTP::Daemon object.
sub start_daemon {
    my ($self) = @_;
    my $daemon = HTTP::Daemon->new(
        LocalAddr => $self->{host},
        LocalPort => $self->{port},
        ReuseAddr => 1,
        Listen    => 10,
    );
    die "Unable to start server on $self->{host}:$self->{port}: $!" if !$daemon;
    return $daemon;
}

# listening_url($daemon)
# Builds the public listening URL for a daemon instance.
# Input: HTTP::Daemon object.
# Output: URL string.
sub listening_url {
    my ( $self, $daemon ) = @_;
    return sprintf 'http://%s:%s/', $daemon->sockhost, $daemon->sockport;
}

# serve_daemon($daemon)
# Bridges HTTP requests from the daemon into the web application.
# Input: HTTP::Daemon object.
# Output: true value when the accept loop completes.
sub serve_daemon {
    my ( $self, $daemon ) = @_;
    while ( my $conn = $daemon->accept ) {
        while ( my $req = $conn->get_request ) {
            my $uri = $req->uri;
            my ( $code, $type, $body, $headers ) = eval {
                @{ $self->{app}->handle(
                    path        => $uri->path,
                    query       => scalar( $uri->query // '' ),
                    method      => $req->method,
                    body        => scalar( $req->content // '' ),
                    remote_addr => $conn->peerhost,
                    headers     => {
                        host   => scalar( $req->header('Host') // '' ),
                        cookie => scalar( $req->header('Cookie') // '' ),
                    },
                ) };
            };

            if ($@) {
                $code = 500;
                $type = 'text/plain; charset=utf-8';
                $body = $@;
                $headers = {};
            }

            my %base_headers = (
                'Content-Type'            => $type,
                'X-Frame-Options'        => 'DENY',
                'X-Content-Type-Options' => 'nosniff',
                'Referrer-Policy'        => 'no-referrer',
                'Cache-Control'          => 'no-store',
                'Content-Security-Policy' => q{default-src 'self' 'unsafe-inline' data:; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'},
                %{ $headers || {} },
            );

            if ( ref($body) eq 'HASH' && ref( $body->{stream} ) eq 'CODE' ) {
                $self->_send_streaming_response(
                    conn    => $conn,
                    code    => $code,
                    headers => \%base_headers,
                    stream  => $body->{stream},
                );
                last;
            }

            my $response = HTTP::Response->new($code);
            for my $name ( sort keys %base_headers ) {
                $response->header( $name => $base_headers{$name} );
            }
            $response->header( 'Content-Length' => length($body) );
            $response->content($body);
            $conn->send_response($response);
        }
        $conn->close;
        undef $conn;
    }
    return 1;
}

# _send_streaming_response(%args)
# Sends a live streaming HTTP response body to one client connection.
# Input: client connection, status code, header hash, and stream callback.
# Output: true value after the response body has been written.
sub _send_streaming_response {
    my ( $self, %args ) = @_;
    my $conn    = $args{conn}    || die 'Missing connection';
    my $code    = $args{code}    || 200;
    my $headers = $args{headers} || {};
    my $stream  = $args{stream}  || die 'Missing stream callback';

    $conn->send_basic_header( $code, status_message($code) || '' );
    for my $name ( sort keys %{$headers} ) {
        $conn->print( $name . ': ' . $headers->{$name} . "\015\012" );
    }
    $conn->print("Connection: close\015\012\015\012");

    my $writer = sub {
        my ($chunk) = @_;
        return 1 if !defined $chunk || $chunk eq '';
        $conn->print($chunk);
        return 1;
    };

    eval { $stream->($writer); 1 } or $writer->($@);
    return 1;
}

1;

__END__

=head1 NAME

Developer::Dashboard::Web::Server - HTTP server bridge for Developer Dashboard

=head1 SYNOPSIS

  my $server = Developer::Dashboard::Web::Server->new(app => $app);
  $server->run;

=head1 DESCRIPTION

This module owns the local HTTP listener and adapts HTTP::Daemon requests to
the web application contract used by Developer Dashboard.

=head1 METHODS

=head2 new, run, start_daemon, listening_url, serve_daemon

Construct and run the local web server.

=cut
