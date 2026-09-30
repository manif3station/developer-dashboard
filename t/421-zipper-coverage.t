#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';

use Developer::Dashboard::Zipper;

my $rendered = eval { Developer::Dashboard::Zipper::_render_ajax_code_template( '[% IF %]', { a => 1 } ) };
is( $rendered, undef, 'a malformed Ajax code template does not render' );
like( $@, qr/Unable to render Ajax code template/, 'the template renderer reports the parse failure' );

done_testing;

__END__

=pod

=head1 NAME

t/421-zipper-coverage.t - covers the Ajax code template render failure in Developer::Dashboard::Zipper

=head1 PURPOSE

Feeds _render_ajax_code_template a syntactically invalid Template Toolkit
string so the process() failure path dies with the documented message.

=cut
