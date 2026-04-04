package Runtime::Result;

use strict;
use warnings;

our $VERSION = '1.47';

# Backward compatibility facade - delegate to new namespace
require Developer::Dashboard::Runtime::Result;

# Delegate all method calls to the new namespace
sub current {
    return Developer::Dashboard::Runtime::Result::current(@_);
}

sub names {
    return Developer::Dashboard::Runtime::Result::names(@_);
}

sub has {
    return Developer::Dashboard::Runtime::Result::has(@_);
}

sub entry {
    return Developer::Dashboard::Runtime::Result::entry(@_);
}

sub stdout {
    return Developer::Dashboard::Runtime::Result::stdout(@_);
}

sub stderr {
    return Developer::Dashboard::Runtime::Result::stderr(@_);
}

sub exit_code {
    return Developer::Dashboard::Runtime::Result::exit_code(@_);
}

sub last_name {
    return Developer::Dashboard::Runtime::Result::last_name(@_);
}

sub last_entry {
    return Developer::Dashboard::Runtime::Result::last_entry(@_);
}

sub report {
    return Developer::Dashboard::Runtime::Result::report(@_);
}

sub _command_name {
    return Developer::Dashboard::Runtime::Result::_command_name(@_);
}

1;

__END__

=head1 NAME

Runtime::Result - backward compatibility facade for Developer::Dashboard::Runtime::Result

=head1 DESCRIPTION

This module provides backward compatibility. New code should use
Developer::Dashboard::Runtime::Result directly.

=cut

