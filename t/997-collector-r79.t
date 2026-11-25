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

use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;

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

# _pid_of($stdout)
# The start/stop/restart commands print the loop pid on stdout, or nothing
# when no loop was running. Returns the pid, or undef.
sub _pid_of {
    my ($stdout) = @_;
    my ($pid) = $stdout =~ /(\d+)/;
    return defined $pid ? $pid + 0 : undef;
}

# _wait_for_alive($pid)
# Polls until the pid answers kill 0, or the wait runs out. A loop takes a
# moment to appear after its start command returns, so a single kill 0
# would flake.
sub _wait_for_alive {
    my ($pid) = @_;
    return 0 if !defined $pid;
    for ( 1 .. 25 ) {
        return 1 if kill 0, $pid;
        select undef, undef, undef, 0.2;
    }
    return 0;
}

# _wait_for_gone($pid)
# Polls until the pid stops answering kill 0, or the wait runs out. A stop
# takes a moment to bring the loop down, so a single kill 0 would flake.
sub _wait_for_gone {
    my ($pid) = @_;
    return 1 if !defined $pid;
    for ( 1 .. 25 ) {
        return 1 if !kill 0, $pid;
        select undef, undef, undef, 0.2;
    }
    return 0;
}

# Setup: init the isolated HOME, then define the example collector and run
# the built-in housekeeper once so its name is persisted. In a fresh HOME
# `d2 collector list` is empty until a collector has run, so the housekeeper
# run is what makes the completion checks deterministic. There is no CLI way
# to define a collector, so the example collector is set up through the
# config directly (the t/120 pattern: save_global with a collectors list).
{
    my ( $exit, $stdout, $stderr ) = _run_d2('init');
    die "collector: d2 init failed in the test HOME: $stderr" if $exit != 0;

    my $paths  = Developer::Dashboard::PathRegistry->new( home => $home );
    my $files  = Developer::Dashboard::FileRegistry->new( paths => $paths );
    my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
    $config->save_global(
        {
            collectors => [
                { name => 'example', command => 'echo example-ok' },
            ],
        }
    );
}

# R79 AC 1, one form only: `d2 collector run <name>` runs the named
# collector once, exit 0. Name is REQUIRED: with no name the command
# prints the usage and runs nothing. The exit code of the usage error is
# deliberately not pinned - that is the implementer's choice.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'run', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector run housekeeper exits 0' );
    like( $stdout, qr/housekeeper/, 'collector: d2 collector run housekeeper names the collector' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'run', 'example' );
    is( $exit, 0, 'collector: d2 collector run example exits 0' );
    like( $stdout, qr/example-ok/, 'collector: d2 collector run example runs the example collector' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'run' );
    my $combined = $stdout . $stderr;
    like( $combined, qr/Usage: d2 collector run <name>/, 'collector: d2 collector run with no name prints the usage' );
    unlike( $combined, qr/"exit_code"/, 'collector: d2 collector run with no name runs nothing' );
}

# R79 AC 2 and AC 10, one or all logs: `d2 collector log [name]` prints
# one or all collector logs, exit 0. No name means ALL - observable here
# because two collectors have logs by now, not just the housekeeper.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector log housekeeper exits 0' );
    like( $stdout, qr/housekeeper/, 'collector: d2 collector log housekeeper names the collector' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example' );
    is( $exit, 0, 'collector: d2 collector log example exits 0' );
    like( $stdout, qr/example-ok/, 'collector: d2 collector log example shows the example log' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log' );
    is( $exit, 0, 'collector: d2 collector log with no name exits 0' );
    like( $stdout, qr/housekeeper/, 'collector: d2 collector log with no name shows the housekeeper log' );
    like( $stdout, qr/example-ok/, 'collector: d2 collector log with no name shows the example log' );
}

# R79 AC 3, start: `d2 collector start <name>` starts one collector loop,
# exit 0. The name is REQUIRED - the code dies with the usage without one
# and there is no all-start in this form - so the no-name case is a
# control that prints the usage, with the exit code deliberately not pinned.
# Liveness is checked on the printed pid, not just the exit code.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector start housekeeper exits 0' );
    my $pid = _pid_of($stdout);
    ok( defined $pid, 'collector: d2 collector start housekeeper prints a pid' );
    ok( _wait_for_alive($pid), 'collector: the housekeeper loop is running after start' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector stop housekeeper exits 0' );
    ok( _wait_for_gone($pid), 'collector: no housekeeper loop is running after stop' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector: d2 collector start example exits 0' );
    my $example_pid = _pid_of($stdout);
    ok( defined $example_pid, 'collector: d2 collector start example prints a pid' );
    ok( _wait_for_alive($example_pid), 'collector: the example loop is running after start' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector: d2 collector stop example exits 0' );
    ok( _wait_for_gone($example_pid), 'collector: no example loop is running after stop' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start' );
    like( $stdout . $stderr, qr/Usage: d2 collector start <name>/, 'collector: d2 collector start with no name prints the usage' );
}

# R79 AC 4 and AC 10, stop one or all: `d2 collector stop [name]` stops
# one or all collectors, exit 0. No name means ALL. Today stop dies
# without a name, so the no-name test is a failing test until the change
# lands. Liveness is checked on the printed pids, not just the exit code.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector start housekeeper exits 0 for the no-name stop' );
    my $housekeeper_pid = _pid_of($stdout);
    ok( _wait_for_alive($housekeeper_pid), 'collector: the housekeeper loop is running before the no-name stop' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector: d2 collector start example exits 0 for the no-name stop' );
    my $example_pid = _pid_of($stdout);
    ok( _wait_for_alive($example_pid), 'collector: the example loop is running before the no-name stop' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop' );
    is( $exit, 0, 'collector: d2 collector stop with no name exits 0' );
    ok( _wait_for_gone($housekeeper_pid), 'collector: no housekeeper loop is running after the no-name stop' );
    ok( _wait_for_gone($example_pid), 'collector: no example loop is running after the no-name stop' );
}

# R79 AC 5 and AC 10, restart one or all: `d2 collector restart [name]`
# restarts one or all collectors, exit 0. No name means ALL. A restart
# genuinely replaces the loop, so the new pid differs from the old one and
# the old pid is gone. Today restart dies without a name, so the no-name
# test is a failing test until the change lands. For the no-name case the
# proof is the old pids being gone plus a stop by name printing a pid for
# each collector, which only happens when a loop is actually running.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector start housekeeper exits 0 for the named restart' );
    my $old_pid = _pid_of($stdout);
    ok( _wait_for_alive($old_pid), 'collector: the housekeeper loop is running before the named restart' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector restart housekeeper exits 0' );
    my $new_pid = _pid_of($stdout);
    ok( defined $new_pid, 'collector: d2 collector restart housekeeper prints a pid' );
    isnt( $new_pid, $old_pid, 'collector: the restart replaces the housekeeper loop with a new pid' );
    ok( _wait_for_alive($new_pid), 'collector: the new housekeeper loop is running after restart' );
    ok( _wait_for_gone($old_pid), 'collector: the old housekeeper loop is gone after restart' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector stop housekeeper exits 0 after the named restart' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector: d2 collector start example exits 0 for the named restart' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart', 'example' );
    is( $exit, 0, 'collector: d2 collector restart example exits 0' );
    my $example_pid = _pid_of($stdout);
    ok( _wait_for_alive($example_pid), 'collector: the new example loop is running after restart' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector: d2 collector stop example exits 0 after the named restart' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector start housekeeper exits 0 for the no-name restart' );
    my $housekeeper_pid = _pid_of($stdout);
    ok( _wait_for_alive($housekeeper_pid), 'collector: the housekeeper loop is running before the no-name restart' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector: d2 collector start example exits 0 for the no-name restart' );
    my $example_restart_pid = _pid_of($stdout);
    ok( _wait_for_alive($example_restart_pid), 'collector: the example loop is running before the no-name restart' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart' );
    is( $exit, 0, 'collector: d2 collector restart with no name exits 0' );
    ok( _wait_for_gone($housekeeper_pid), 'collector: the old housekeeper loop is gone after the no-name restart' );
    ok( _wait_for_gone($example_restart_pid), 'collector: the old example loop is gone after the no-name restart' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'housekeeper' );
    is( $exit, 0, 'collector: d2 collector stop housekeeper exits 0 after the no-name restart' );
    ok( defined _pid_of($stdout), 'collector: stopping the housekeeper after the no-name restart prints a pid, so its loop was running' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector: d2 collector stop example exits 0 after the no-name restart' );
    ok( defined _pid_of($stdout), 'collector: stopping the example after the no-name restart prints a pid, so its loop was running' );
}

# R79 AC 6, the verb-first forms go away: `d2 restart collector`,
# `d2 stop collector`, `d2 log collector` and `d2 logs collector` must no
# longer succeed, with or without a name. They all exit 0 today, so these
# are failing tests until the forms are removed. The exact error text is
# deliberately not pinned - that is the implementer's choice.
for my $verb ( qw(restart stop log logs) ) {
    my ( $exit, $stdout, $stderr ) = _run_d2( $verb, 'collector' );
    isnt( $exit, 0, "collector: d2 $verb collector no longer succeeds" );
}
for my $verb ( qw(restart stop log logs) ) {
    my ( $exit, $stdout, $stderr ) = _run_d2( $verb, 'collector', 'housekeeper' );
    isnt( $exit, 0, "collector: d2 $verb collector housekeeper no longer succeeds" );
}

# R79 AC 7, `d2 log/logs/restart/stop` keep working for web and with no
# scope. These already work today, so they are the controls. The no-scope
# stop comes after the no-scope restart, so nothing is left running.
for my $args ( [ 'restart' ], [ 'restart', 'web' ], [ 'stop' ], [ 'stop', 'web' ], [ 'log' ], [ 'log', 'web' ], [ 'logs' ], [ 'logs', 'web' ] ) {
    my ( $exit, $stdout, $stderr ) = _run_d2( @{$args} );
    is( $exit, 0, 'collector: d2 ' . join( ' ', @{$args} ) . ' still exits 0' );
}

# R79 AC 8, autocomplete offers collector names after every name-taking
# collector action. Today it offers the action list instead, so these are
# failing tests until the name branch exists. The example collector is
# offered too, not just the housekeeper.
for my $action ( qw(run log start stop restart) ) {
    my @candidates = _complete( 'collector', $action );
    my $offers_housekeeper = grep { $_ eq 'housekeeper' } @candidates;
    ok( $offers_housekeeper, "collector: d2 collector $action <TAB> offers the housekeeper name" );
    my $offers_example = grep { $_ eq 'example' } @candidates;
    ok( $offers_example, "collector: d2 collector $action <TAB> offers the example name" );
}

# R79 AC 8, prefix filtering: typing a partial name offers the collector
# whose name starts with it. Today the action list is offered instead, so
# the partial name matches nothing.
{
    my @candidates = _complete( 'collector', 'run', 'hou' );
    my $offers = grep { $_ eq 'housekeeper' } @candidates;
    ok( $offers, 'collector: d2 collector run hou<TAB> offers the housekeeper name' );
    @candidates = _complete( 'collector', 'run', 'exa' );
    $offers = grep { $_ eq 'example' } @candidates;
    ok( $offers, 'collector: d2 collector run exa<TAB> offers the example name' );
}

# R79 AC 6 and AC 8, the verb-first completion branches go away with the
# forms: after `d2 restart/stop/log/logs collector` the collector names
# must no longer be offered. They are offered today, so these are failing
# tests until the branches are removed.
for my $verb ( qw(restart stop log logs) ) {
    my @candidates = _complete( $verb, 'collector' );
    my $offers_housekeeper = grep { $_ eq 'housekeeper' } @candidates;
    ok( !$offers_housekeeper, "collector: d2 $verb collector <TAB> no longer offers the housekeeper name" );
    my $offers_example = grep { $_ eq 'example' } @candidates;
    ok( !$offers_example, "collector: d2 $verb collector <TAB> no longer offers the example name" );
}

done_testing();
