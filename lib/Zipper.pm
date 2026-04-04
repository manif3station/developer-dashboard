package Zipper;

use strict;
use warnings;

our $VERSION = '1.47';

# Backward compatibility facade - delegate to new namespace
require Developer::Dashboard::Zipper;

# Re-export exports
use Exporter 'import';
our @EXPORT_OK = qw(zip unzip _cmdx _cmdp __cmdx acmdx Ajax saved_ajax_file_path load_saved_ajax_code);

# Forward all subroutine calls to Developer::Dashboard::Zipper
our $AUTOLOAD;
sub AUTOLOAD {
    (my $name = $AUTOLOAD) =~ s/.*:://;
    return if $name eq 'DESTROY';
    
    my $real_sub = "Developer::Dashboard::Zipper::$name";
    no strict 'refs';
    return &$real_sub(@_);
}

1;

__END__

=head1 NAME

Zipper - legacy backward compatibility module

=head1 DESCRIPTION

This is a backward compatibility facade. New code should use
Developer::Dashboard::Zipper directly.

=cut
