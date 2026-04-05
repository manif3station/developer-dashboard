use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use Developer::Dashboard::PageRuntime;

{
    package Local::FakePaths;

    sub new {
        my ( $class, %args ) = @_;
        return bless { root => $args{root} }, $class;
    }

    sub runtime_root {
        my ($self) = @_;
        return $self->{root};
    }
}

my $root    = tempdir( CLEANUP => 1 );
my $paths   = Local::FakePaths->new( root => $root );
my $runtime = Developer::Dashboard::PageRuntime->new( paths => $paths );
my $lib_dir = File::Spec->catdir( $root, 'local', 'lib', 'perl5' );

{
    local $ENV{PERL5LIB} = 'alpha:beta';
    my %env = $runtime->_saved_ajax_env(
        path   => '/tmp/example.pl',
        page   => 'sql-dashboard',
        type   => 'json',
        params => { one => 1 },
    );
    is( $env{PERL5LIB}, 'alpha:beta', 'saved ajax env leaves PERL5LIB unchanged when the runtime local lib does not exist' );
}

make_path($lib_dir);
{
    local $ENV{PERL5LIB} = 'alpha:beta';
    my %env = $runtime->_saved_ajax_env(
        path   => '/tmp/example.pl',
        page   => 'sql-dashboard',
        type   => 'json',
        params => { one => 1 },
    );
    is(
        $env{PERL5LIB},
        join( ':', $lib_dir, 'alpha', 'beta' ),
        'saved ajax env prepends the runtime local lib when it exists',
    );
}

{
    local $ENV{PERL5LIB} = join( ':', $lib_dir, 'alpha' );
    my %env = $runtime->_saved_ajax_env(
        path   => '/tmp/example.pl',
        page   => 'sql-dashboard',
        type   => 'json',
        params => { one => 1 },
    );
    is(
        $env{PERL5LIB},
        join( ':', $lib_dir, 'alpha' ),
        'saved ajax env does not duplicate the runtime local lib in PERL5LIB',
    );
}

{
    my $dashboard = File::Spec->catfile( File::Spec->curdir, 'bin', 'dashboard' );
    open my $fh, '<', $dashboard or die "Unable to read $dashboard: $!";
    my $source = do { local $/; <$fh> };
    close $fh or die "Unable to close $dashboard: $!";
    unlike( $source, qr/Developer::Dashboard::CPANManager/, 'dashboard script keeps runtime-local cpan support script-local instead of introducing a dedicated CPAN manager module' );
}

done_testing;

__END__

=head1 NAME

28-runtime-cpan-env.t - verify runtime-local Perl module exposure without a dedicated CPAN manager module

=head1 DESCRIPTION

This test verifies that saved Ajax workers inherit the runtime-local
C<.developer-dashboard/local/lib/perl5> path directly from the active runtime
root and that the dashboard script no longer depends on a dedicated
C<Developer::Dashboard::CPANManager> module.

=cut
