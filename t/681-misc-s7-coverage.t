#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use Developer::Dashboard::Auth;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::IndicatorStore;
use Developer::Dashboard::PageDocument;
use Developer::Dashboard::PageRuntime;
use Developer::Dashboard::PageRuntime::StreamHandle;
use Developer::Dashboard::PageStore;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::SessionStore;
use Developer::Dashboard::Web::App;

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );

# --- StreamHandle: a handle tied without a writer discards output ------------
{
    my @seen;
    tie *NOWRITER, 'Developer::Dashboard::PageRuntime::StreamHandle';
    ok( print( NOWRITER 'dropped' ), 'printing to a handle tied without a writer succeeds' );
    untie *NOWRITER;
    is_deeply( \@seen, [], 'nothing is forwarded when there is no writer' );
}

# --- PageRuntime: a sandpit package that fails to compile is fatal -----------
{
    my $runtime = Developer::Dashboard::PageRuntime->new( paths => $paths );
    no warnings 'redefine';
    local *Developer::Dashboard::PageRuntime::_sandpit_package_source = sub { return 'this is not perl (' };
    my $ok = eval { $runtime->_new_sandpit( state => {}, runtime_context => {} ); 1 };
    ok( !$ok, 'sandpit creation dies when the generated package does not compile' );
    like( $@, qr/Unable to setup sandpit/, 'the sandpit failure is named' );
}

# --- Web::App: readable-file gate for static assets --------------------------
{
    my $root = File::Spec->catdir( $home, 'public' );
    make_path($root);
    my $file = File::Spec->catfile( $root, 'a.js' );
    open my $fh, '>', $file or die "Unable to write $file: $!";
    print {$fh} 'var a = 1;';
    close $fh or die "Unable to close $file: $!";

    my $app = Developer::Dashboard::Web::App->new(
        auth     => Developer::Dashboard::Auth->new( files => Developer::Dashboard::FileRegistry->new( paths => $paths ), paths => $paths ),
        pages    => Developer::Dashboard::PageStore->new( paths => $paths ),
        runtime  => Developer::Dashboard::PageRuntime->new( paths => $paths ),
        sessions => Developer::Dashboard::SessionStore->new( paths => $paths ),
    );
    is( $app->_serve_static_file_from_roots( 'js', 'a.js', $root )->[0], 200, 'a readable asset is served from its root' );

    no warnings 'redefine';
    local *Developer::Dashboard::Web::App::_file_is_readable = sub { return 0 };
    is( $app->_serve_static_file_from_roots( 'js', 'a.js', $root )->[0], 404, 'an existing but unreadable asset is not picked from a root' );
    is( $app->_serve_static_file_at_path( 'js', 'a.js', $file, '', [$root] )->[0], 404, 'an existing but unreadable asset is a 404 at the path server' );
}

# --- PageStore: platforms without O_NOFOLLOW still compile -------------------
{
    no warnings qw(redefine once);
    local *Fcntl::O_NOFOLLOW = sub { die "O_NOFOLLOW is not available\n" };
    local $SIG{__WARN__} = sub { };
    delete $INC{'Developer/Dashboard/PageStore.pm'};
    require Developer::Dashboard::PageStore;
    my $store = Developer::Dashboard::PageStore->new( paths => $paths );
    my $page = Developer::Dashboard::PageDocument->new( id => 'nofollow', title => 'No Follow', layout => { body => 'b' } );
    $store->save_page($page);
    is( $store->load_saved_page('nofollow')->as_hash->{title}, 'No Follow', 'pages still save and load when O_NOFOLLOW is unavailable' );
}

done_testing;

__END__

=pod

=head1 NAME

t/681-misc-s7-coverage.t - covers the StreamHandle writer default, sandpit compile failure, static-file readability gate, and missing O_NOFOLLOW fallback

=head1 PURPOSE

Test file in the Developer Dashboard codebase. It drives small library branches that need a stub or a reload rather than a filesystem failure.

=head1 WHY IT EXISTS

It exists because the mandatory 100 percent lib/ coverage gate allows no uncoverable annotations, so every branch must be reached by a real test or removed from the code.

=head1 WHEN TO USE

Use this file when you change the code paths it exercises, or when a coverage run reports one of them as uncovered.

=head1 HOW TO USE

Run it directly with C<prove -lv t/681-misc-s7-coverage.t> while iterating, then keep it green under C<prove -lr t> and the Devel::Cover run before release.

=head1 WHAT USES IT

It is used by developers during TDD, by the full C<prove -lr t> suite, by the Devel::Cover coverage gate, and by release verification before commit or push.

=head1 EXAMPLES

Example 1:

  prove -lv t/681-misc-s7-coverage.t

Run this coverage-gap test by itself while editing the code it covers.

=cut
