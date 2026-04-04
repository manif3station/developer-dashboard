package File;

use strict;
use warnings;

our $VERSION = '1.47';

# Backward compatibility facade - delegate to new namespace
require Developer::Dashboard::File;

# Re-export through @ISA
our @ISA = qw(Developer::Dashboard::File);

1;

__END__

=head1 NAME

File - legacy backward compatibility module

=head1 DESCRIPTION

This is a backward compatibility facade. New code should use
Developer::Dashboard::File directly.

=cut

