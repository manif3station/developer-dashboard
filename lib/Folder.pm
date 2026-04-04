package Folder;

use strict;
use warnings;

our $VERSION = '1.47';

# Simple re-export via require and @ISA
require Developer::Dashboard::Folder;

our @ISA = qw(Developer::Dashboard::Folder);

1;

__END__

=head1 NAME

Folder - legacy backward compatibility module

=head1 DESCRIPTION

This is a backward compatibility facade. New code should use
Developer::Dashboard::Folder directly.

=cut
