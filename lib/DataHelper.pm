package DataHelper;

use strict;
use warnings;

our $VERSION = '1.47';

# Backward compatibility facade - delegate to new namespace
require Developer::Dashboard::DataHelper;
use Exporter 'import';
our @EXPORT = qw(j je);

sub j {
    return Developer::Dashboard::DataHelper::j(@_);
}

sub je {
    return Developer::Dashboard::DataHelper::je(@_);
}

1;

__END__

=head1 NAME

DataHelper - legacy backward compatibility module

=head1 DESCRIPTION

This is a backward compatibility facade. New code should use
Developer::Dashboard::DataHelper directly.

=cut

