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
    my $start_combined = $stdout . $stderr;
    like( $start_combined, qr/Usage: d2 collector start <name>/, 'collector: d2 collector start with no name prints the usage' );
    unlike( $start_combined, qr/^\d+$/m, 'collector: d2 collector start with no name starts nothing' );
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

# R79, the help text encodes the name rules: `[name]` (optional) for
# log, stop and restart, `<name>` (required) for run and start. Log, run
# and start already read that way, so they are controls; stop and restart
# still read `<name>` today, so those two are failing tests until the
# help is updated with the change.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'help', 'collector' );
    is( $exit, 0, 'collector: d2 help collector exits 0' );
    like( $stdout, qr/d2 collector log \[name\]/, 'collector: help shows d2 collector log [name]' );
    like( $stdout, qr/d2 collector run <name>/, 'collector: help shows d2 collector run <name>' );
    like( $stdout, qr/d2 collector start <name>/, 'collector: help shows d2 collector start <name>' );
    like( $stdout, qr/d2 collector stop \[name\]/, 'collector: help shows d2 collector stop [name]' );
    like( $stdout, qr/d2 collector restart \[name\]/, 'collector: help shows d2 collector restart [name]' );
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

__END__

=head1 NAME

t/997-collector-r79.t - failing tests for the R79 collector form (one form d2 collector <verb>)

=head1 PURPOSE

Pin the R79 collector form: one form only, C<d2 collector
<subcommand>> (run, log, start, stop, restart). Verb-first forms (C<d2
log/restart/stop/logs collector>) go away entirely, with or without a
name; C<d2 log>, C<d2 logs>, C<d2 restart>, C<d2 stop> keep working for
web and with no scope; C<d2 logs> is an alias of C<d2 log>. AC 1: run
<name> required. AC 2: log [name], no-name = ALL. AC 3: start name
REQUIRED. AC 4: stop [name], no-name = ALL, no loop running after. AC 5:
restart [name], no-name = ALL. AC 6: verb-first forms fail. AC 7:
log/logs/restart/stop work no-scope + web. AC 9: housekeeper plus an
example collector end to end. AC 10: no-name log/stop/restart = ALL; run
requires a name. (AC 8, completion, is covered by t/998.) 108 checks,
driven through the real CLI in a child with a temp HOME.

=head1 WHY IT EXISTS

The collector commands had two forms - verb-first (C<d2 log
collector>) and collector-first (C<d2 collector log>) - and the
verb-first form was the old shape R79 removes. Without tests that drive
every verb-first form and assert it fails, and every collector-first
form and assert it works, the old form could survive a refactor and
users would keep two ways to do the same thing. The tests are the R79
acceptance criteria in executable form, written before the implementation
(TDD).

=head1 WHEN TO USE

When a collector subcommand changes, when the dispatch in the private CLI
core changes, when a new collector verb is added, or when a verb-first
form is reported as still working. Also when completion offers collector
names for the wrong action.

=head1 HOW TO USE

Run it directly with C<prove -lv t/997-collector-r79.t> while iterating,
then keep it green under C<prove -lr t> before release. It runs the
checkout CLI in a child with a temp HOME via C<_run_d2>, starts and stops
the example collector, and asserts exit codes, output shapes and the
collector state after each action. The housekeeper plus the example
collector run end to end as AC 9 requires. The verb-first blocks assert
the old forms fail with usage; the no-name blocks assert log/stop/restart
act on ALL collectors.

=head1 WHAT USES IT

It is used by the collector dispatch (the collector block in the private
CLI core), by the full C<prove -lr t> suite, and by anyone changing
collector commands who needs to know the one-form rule still holds.

=head1 EXAMPLES

Example 1:

  prove -lv t/997-collector-r79.t

Run the collector form checks by themselves while changing the collector
dispatch or any collector subcommand.

Example 2:

  prove -lv t/998-collector-complete-r79.t

Run the completion unit checks alongside it to see the same one-form
rule through the completion branches.

Example 3:

  prove -lr t

Run the whole suite after the focused check to keep the collector form
aligned with the rest of the CLI.

=cut
