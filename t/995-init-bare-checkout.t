use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use File::Temp qw(tempdir);
use Test::More;

my $repo      = getcwd();
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

# _run_init($home, $with_perl5lib)
# Runs `d2 init` in a child with a fresh HOME and returns the child exit
# code and its combined output. With $with_perl5lib false the child gets
# the environment a bare checkout user has: no PERL5LIB, no PERL5OPT, no
# dashboard repo hints. With it true the child inherits the suite
# environment, which is the control case the existing t/05 init test
# already covers.
sub _run_init {
    my ( $home, $with_perl5lib ) = @_;
    local %ENV = %ENV;
    if ( !$with_perl5lib ) {
        delete $ENV{PERL5LIB};
        delete $ENV{PERL5OPT};
        delete $ENV{DEVELOPER_DASHBOARD_REPO_LIB};
        delete $ENV{HARNESS_PERL_SWITCHES};
        delete $ENV{PERL_LOCAL_LIB_ROOT};
        delete $ENV{PERL_MB_OPT};
        delete $ENV{PERL_MM_OPT};
    }
    $ENV{HOME} = $home;
    my ( $stdout, $stderr, $exit ) = capture {
        system $^X, $dashboard, 'init';
        return $? >> 8;
    };
    return ( $exit, $stdout . $stderr );
}

# T2: d2 init works in a bare checkout with no PERL5LIB set. The staged
# helper _dashboard-core does `use Capture::Tiny` before the BEGIN block
# that bootstraps PERL5LIB, so in a bare checkout it dies with
# "Can't locate Capture/Tiny.pm" and exits 2.
{
    my $home = tempdir( CLEANUP => 1 );
    my ( $exit, $output ) = _run_init( $home, 0 );
    is( $exit, 0, 'init: d2 init exits 0 in a bare checkout with no PERL5LIB set' );
    unlike( $output, qr/Can't locate Capture\/Tiny\.pm/, 'init: d2 init does not fail looking for Capture::Tiny in a bare checkout' );
    ok( -f File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' ),
        'init: d2 init creates the config in a bare checkout with no PERL5LIB set' );
    # No assertion on the staged core helper here: init stages it before
    # the failing exec, so its existence says nothing about init working.
}

# Control: init with PERL5LIB set (the suite environment) still works.
{
    my $home = tempdir( CLEANUP => 1 );
    my ( $exit, $output ) = _run_init( $home, 1 );
    is( $exit, 0, 'init: d2 init exits 0 with PERL5LIB set' );
    ok( -f File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' ),
        'init: d2 init creates the config with PERL5LIB set' );
}

done_testing();
