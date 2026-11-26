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

__END__

=head1 NAME

t/995-init-bare-checkout.t - failing tests for the bare-checkout init fix (T2)

=head1 PURPOSE

Pin that C<d2 init> works in a bare checkout with no PERL5LIB set. The
staged helper used Capture::Tiny before bootstrapping PERL5LIB, so init
failed for a user with a fresh checkout and no PERL5LIB. The test runs
C<d2 init> in a child with a fresh HOME and no PERL5LIB, no PERL5OPT and
no dashboard repo hints, and asserts it exits 0 and creates the config;
the control case (PERL5LIB set, the suite environment) still works. This
box's system perl does not have Capture::Tiny in site_perl, so the bare
case passing proves the fix.

=head1 WHY IT EXISTS

C<perl bin/d2 init> failed in a bare checkout with no PERL5LIB (T2), and
the failure only showed up for a real user, not in the suite, because the
suite always runs with PERL5LIB set. Without a test that reproduces the
bare environment, the fix could regress silently and the next
bare-checkout user would hit the same failure. The test is the
discriminating check: it fails before the PerlEnv fix and passes after
it.

=head1 WHEN TO USE

When C<d2 init> fails for a new user, when the PERL5LIB bootstrap in
PerlEnv changes, or when the staged helper's module loading changes.
Also when the init path gains a new dependency that might be needed
before the bootstrap.

=head1 HOW TO USE

Run it directly with C<prove -lv t/995-init-bare-checkout.t> while
iterating, then keep it green under C<prove -lr t> before release. It
runs C<d2 init> in a child process with a fresh temp HOME and a stripped
environment (no PERL5LIB, no PERL5OPT, no repo hints) via the
C<_run_init> helper, and asserts the exit code and that the config file
is created. The control block runs the same init with PERL5LIB set,
which the existing t/05 init test already covers. The child environment
is built with a localised C<%ENV>, so the parent suite environment is
untouched.

=head1 WHAT USES IT

It is used by the init path (PerlEnv's C<perl5lib_list>, which adds the
checkout's C<local/lib/perl5>), by the full C<prove -lr t> suite, and by
anyone changing the staged helper bootstrap who needs to know a bare
checkout still initialises.

=head1 EXAMPLES

Example 1:

  prove -lv t/995-init-bare-checkout.t

Run the bare-checkout init check by itself while changing the PERL5LIB
bootstrap or the staged helper loading.

Example 2:

  env -u PERL5LIB perl -Ilib bin/d2 init

Reproduce the bare environment by hand: init with no PERL5LIB set, the
way a fresh checkout user runs it.

Example 3:

  prove -lr t

Run the whole suite after the focused check to keep the init contract
aligned with the rest of the CLI.

=cut
