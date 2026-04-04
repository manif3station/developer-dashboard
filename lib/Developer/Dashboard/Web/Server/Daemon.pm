package Developer::Dashboard::Web::Server::Daemon;

use strict;
use warnings;

our $VERSION = '1.52';

# new(%args)
# Constructs the lightweight daemon descriptor used by RuntimeManager.
# Input: resolved host and port values.
# Output: daemon descriptor object.
sub new {
    my ( $class, %args ) = @_;
    return bless {
        host          => $args{host},
        port          => $args{port},
        internal_host => $args{internal_host},
        internal_port => $args{internal_port},
    }, $class;
}

# sockhost()
# Returns the resolved listen host for the daemon descriptor.
# Input: none.
# Output: host string.
sub sockhost {
    return $_[0]{host};
}

# sockport()
# Returns the resolved listen port for the daemon descriptor.
# Input: none.
# Output: port integer.
sub sockport {
    return $_[0]{port};
}

# internal_sockhost()
# Returns the resolved internal backend host when the daemon fronts an SSL proxy.
# Input: none.
# Output: host string or undef.
sub internal_sockhost {
    return $_[0]{internal_host};
}

# internal_sockport()
# Returns the resolved internal backend port when the daemon fronts an SSL proxy.
# Input: none.
# Output: port integer or undef.
sub internal_sockport {
    return $_[0]{internal_port};
}

1;

__END__

=head1 NAME

Developer::Dashboard::Web::Server::Daemon - Lightweight daemon descriptor for the PSGI server wrapper

=head1 SYNOPSIS

  my $daemon = Developer::Dashboard::Web::Server::Daemon->new(
      host => '127.0.0.1',
      port => 17891,
  );

=head1 DESCRIPTION

This module stores the resolved listen host and port that the runtime manager
and PSGI server wrapper use when reserving and starting the dashboard web
listener.

=head1 METHODS

=head2 new, sockhost, sockport, internal_sockhost, internal_sockport

Construct and query the lightweight daemon descriptor.

=cut
