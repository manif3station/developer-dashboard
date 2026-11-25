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
my $lib       = File::Spec->catdir( $repo, 'lib' );

my $home = tempdir( CLEANUP => 1 );

# _run_d2(@args)
# Runs the checkout CLI in a child with the temp HOME and returns the
# child exit code, stdout and stderr.
sub _run_d2 {
    my (@args) = @_;
    local $ENV{HOME} = $home;
    my ( $stdout, $stderr, $exit ) = capture {
        system $^X, '-I', $lib, $dashboard, @args;
        return $? >> 8;
    };
    return ( $exit, $stdout, $stderr );
}

# _complete(@words)
# Runs `d2 complete 3 d2 <words>` and returns the candidate list, one
# entry per line of stdout.
sub _complete {
    my (@words) = @_;
    my ( $exit, $stdout, $stderr ) = _run_d2( 'complete', 3, 'd2', @words );
    is( $exit, 0, 'collector: d2 complete exits 0 for ' . join( ' ', @words ) );
    return split /\n/, $stdout;
}

# Setup: init the isolated HOME, then run the built-in housekeeper once so
# its name is persisted and completion has a collector name to offer. In a
# fresh HOME `d2 collector list` is empty until a collector has run, so
# this run is what makes the completion checks deterministic.
{
    my ( $exit, $stdout, $stderr ) = _run_d2('init');
    die "collector: d2 init failed in the test HOME: $stderr" if $exit != 0;
}

# R79, one form only: `d2 collector <subcommand>` for run, log, start,
# stop and restart. These already work today, so they are the controls.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'run', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector run housekeeper exits 0' );
    like( $stdout, qr/housekeeper/, 'collector: d2 collector run housekeeper names the collector' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector log housekeeper exits 0' );
    like( $stdout, qr/housekeeper/, 'collector: d2 collector log housekeeper names the collector' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector start housekeeper exits 0' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector stop housekeeper exits 0' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector restart housekeeper exits 0' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector stop housekeeper exits 0 after restart' );
}

# R79, the verb-first forms go away: `d2 log collector`, `d2 restart
# collector` and `d2 stop collector` must no longer succeed. They all
# exit 0 today, so these are failing tests until the forms are removed.
for my $verb ( qw(restart stop log) ) {
    my ( $exit, $stdout, $stderr ) = _run_d2( $verb, 'collector' );
    isnt( $exit, 0, "collector: d2 $verb collector no longer succeeds" );
}

# R79, `d2 log/restart/stop` keep working for web and with no scope.
# These already work today, so they are the controls.
for my $args ( [ 'restart' ], [ 'restart', 'web' ], [ 'stop' ], [ 'stop', 'web' ], [ 'log' ], [ 'log', 'web' ] ) {
    my ( $exit, $stdout, $stderr ) = _run_d2( @{$args} );
    is( $exit, 0, 'collector: d2 ' . join( ' ', @{$args} ) . ' still exits 0' );
}

# R79, autocomplete offers collector names after every name-taking
# collector action. Today it offers the action list instead, so these
# are failing tests until the name branch exists.
for my $action ( qw(run log start stop restart) ) {
    my @candidates = _complete( 'collector', $action );
    my $offers = grep { $_ eq 'housekeeper' } @candidates;
    ok( $offers, "collector: d2 collector $action <TAB> offers the housekeeper name" );
}

# R79, the verb-first completion branches go away with the forms: after
# `d2 restart/stop/log collector` the collector names must no longer be
# offered. They are offered today, so these are failing tests until the
# branches are removed.
for my $verb ( qw(restart stop log) ) {
    my @candidates = _complete( $verb, 'collector' );
    my $offers = grep { $_ eq 'housekeeper' } @candidates;
    ok( !$offers, "collector: d2 $verb collector <TAB> no longer offers the housekeeper name" );
}

done_testing();
