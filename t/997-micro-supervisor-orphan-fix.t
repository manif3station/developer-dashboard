#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes ();

use lib 'lib';

use Developer::Dashboard::Config;
use Developer::Dashboard::Collector;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;
use Developer::Dashboard::GoRoutine ();

# Keep runtime readiness polling instant and hermetic.
$ENV{DEVELOPER_DASHBOARD_RUNTIME_STABILITY_POLLS}    = 1;
$ENV{DEVELOPER_DASHBOARD_RUNTIME_CONFIRMATION_POLLS} = 1;

{
    package Local::Runner;
    sub new {
        my ( $class, %args ) = @_;
        return bless { loops => [], stopped => [], %args }, $class;
    }
    sub running_loops { return @{ $_[0]{loops} } }
    sub stop_loop {
        my ( $s, $name ) = @_;
        push @{ $s->{stopped} }, $name;
        $s->{loops} = [ grep { $_->{name} ne $name } @{ $s->{loops} } ];
        return 1;
    }

    package Local::Server;
    sub new { my ( $c, %a ) = @_; return bless { %a }, $c }
    sub run { return 'foreground-ran' }
    sub start_daemon { return bless {}, 'Local::Daemon' }
    sub serve_daemon { return 1 }

    package Local::Daemon;
    sub new      { return bless {}, shift }
    sub sockhost { return '0.0.0.0' }
    sub sockport { return 7890 }
}

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME}                        = $home;
local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

my $paths           = Developer::Dashboard::PathRegistry->new( home => $home );
my $files           = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config          = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $collector_store = Developer::Dashboard::Collector->new( paths => $paths );
$config->save_global(
    {
        collectors => [
            { name => 'alpha.collector', command => 'true', cwd => 'home', interval => 1 },
        ],
    }
);

sub build_manager {
    my (%over) = @_;
    return Developer::Dashboard::RuntimeManager->new(
        app_builder => $over{app_builder} || sub { return Local::Server->new(@_) },
        config      => $over{config} || $config,
        files       => $files,
        paths       => $paths,
        runner      => $over{runner} || Local::Runner->new,
        ( exists $over{collectors} ? ( collectors => $over{collectors} ) : () ),
    );
}

my $RM = 'Developer::Dashboard::RuntimeManager';

# Runs one supervisor loop pass set in-process with a stubbed shutdown and
# a counting sleep, and returns the caught error plus the shutdown calls.
# The loop never returns on its own: either the stubbed shutdown fires
# (the behaviour under test) or the sleep cap stops it (the loop stayed
# alive, which is the expected outcome for the live-parent cases).
sub run_supervisor_loop {
    my (%args) = @_;
    my $runner = $args{runner} || Local::Runner->new;
    my $manager = build_manager( runner => $runner );
    my @shutdown_status;
    my $sleep_calls = 0;
    my $cap = $args{sleep_cap} || 400;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_state = sub {
        return { watched_names => ['alpha.collector'] };
    };
    local *Developer::Dashboard::RuntimeManager::_supervise_collectors_once = sub { return {} };
    local *Developer::Dashboard::RuntimeManager::_reap_any_child_processes = sub { return 0 };
    local *Developer::Dashboard::RuntimeManager::_write_collector_supervisor_state = sub { return $_[1] };
    local *Developer::Dashboard::RuntimeManager::_close_inherited_fds = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::web_state = $args{web_state} || sub { return undef };
    local *Developer::Dashboard::RuntimeManager::_shutdown_collector_supervisor = sub {
        push @shutdown_status, $_[1];
        die "__SUPERVISOR_SHUTDOWN__\n";
    };
    local *Developer::Dashboard::RuntimeManager::sleep = sub {
        $sleep_calls++;
        Time::HiRes::sleep(0.005);
        die "__STOP__\n" if $sleep_calls >= $cap;
        return 0;
    };
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS} = $args{quiesce} if defined $args{quiesce};
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_PARENT_GRACE_SECONDS} = $args{grace} if defined $args{grace};
    my $err = eval { $manager->_run_collector_supervisor_child( daemonize => 0, redirect => 0 ); 1 } ? '' : $@;
    return {
        err       => $err,
        shutdowns => \@shutdown_status,
        sleeps    => $sleep_calls,
        runner    => $runner,
    };
}

# --- _collector_supervisor_quiesce_seconds defaults and env override -----
{
    my $manager = build_manager();
    is( $manager->_collector_supervisor_quiesce_seconds, 600, 'quiesce period defaults to 600 seconds' );
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS} = 42;
    is( $manager->_collector_supervisor_quiesce_seconds, 42, 'quiesce period honours its env override' );
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_QUIESCE_SECONDS} = 'bogus';
    is( $manager->_collector_supervisor_quiesce_seconds, 600, 'quiesce period falls back to the default for a bogus env value' );
}

# --- quiesce: no web, no live loops, supervisor exits 'quiesced' -----------
{
    my $result = run_supervisor_loop( quiesce => 0.5, grace => 0.5 );
    like( $result->{err}, qr/__SUPERVISOR_SHUTDOWN__/, 'supervisor with no web and no live loops shuts down' );
    is_deeply( $result->{shutdowns}, ['quiesced'], 'supervisor with no web and no live loops exits quiesced' );
    ok( $result->{sleeps} >= 10, 'quiesce waits out its period instead of exiting at once' );
}

# --- quiesce reset: a live watched loop keeps the supervisor alive ---------
{
    my $runner = Local::Runner->new( loops => [ { name => 'alpha.collector' } ] );
    my $result = run_supervisor_loop( runner => $runner, quiesce => 0.5, grace => 0.5 );
    like( $result->{err}, qr/__STOP__/, 'supervisor with a live watched loop runs until the sleep cap' );
    is_deeply( $result->{shutdowns}, [], 'supervisor with a live watched loop never quiesces' );
}

# --- adopt-dead: a dead web pid is adopted and exits 'parent-gone' ---------
{
    my $result = run_supervisor_loop(
        quiesce   => 0.5,
        grace     => 0.5,
        web_state => sub { return { pid => 999999999, status => 'running' } },
    );
    like( $result->{err}, qr/__SUPERVISOR_SHUTDOWN__/, 'supervisor with a dead web pid shuts down' );
    is_deeply( $result->{shutdowns}, ['parent-gone'], 'supervisor with a dead web pid exits parent-gone' );
    ok( $result->{sleeps} >= 10, 'adopt-dead waits out the grace period instead of exiting at once' );
    is_deeply( $result->{runner}{stopped}, ['alpha.collector'], 'adopt-dead stops the watched loop on the way out' );
}

# --- live web: adoption keeps the supervisor alive --------------------------
{
    my $result = run_supervisor_loop(
        quiesce   => 0.5,
        grace     => 0.5,
        web_state => sub { return { pid => $$, status => 'running' } },
    );
    like( $result->{err}, qr/__STOP__/, 'supervisor with a live web pid runs until the sleep cap' );
    is_deeply( $result->{shutdowns}, [], 'supervisor with a live web pid never exits' );
}

# --- worker guard: a live starman worker is never adopted as a parent -----
{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_shutdown_collector_supervisor = sub {
        die "__SUPERVISOR_SHUTDOWN__\n";
    };
    my $manager = build_manager();

    local *Developer::Dashboard::RuntimeManager::web_state = sub { return { pid => $$, status => 'running' } };
    local *Developer::Dashboard::RuntimeManager::_read_process_title = sub { return 'starman worker 127.0.0.1:7890' };
    my $parent = {};
    my $err = eval { $manager->_check_collector_supervisor_parent( ['alpha.collector'], $parent ); 1 } ? '' : $@;
    is( $err, '', 'supervisor with a live worker web pid does not shut down' );
    is( $parent->{pid}, undef, 'supervisor never adopts a live starman worker as its parent' );

    local *Developer::Dashboard::RuntimeManager::_read_process_title = sub { return 'starman master 127.0.0.1:7890' };
    $parent = {};
    $err = eval { $manager->_check_collector_supervisor_parent( ['alpha.collector'], $parent ); 1 } ? '' : $@;
    is( $err, '', 'supervisor with a live master web pid does not shut down' );
    is( $parent->{pid}, $$, 'supervisor adopts a live starman master as its parent' );

    # A live adopted parent still decides when web.json names a worker.
    local *Developer::Dashboard::RuntimeManager::web_state = sub { return { pid => getppid(), status => 'running' } };
    local *Developer::Dashboard::RuntimeManager::_read_process_title = sub { return 'starman worker 127.0.0.1:7890' };
    $parent = { pid => $$ };
    $err = eval { $manager->_check_collector_supervisor_parent( ['alpha.collector'], $parent ); 1 } ? '' : $@;
    is( $err, '', 'supervisor with a live adopted parent does not shut down when web.json names a worker' );
    is( $parent->{pid}, $$, 'supervisor keeps its live adopted parent when web.json names a worker' );
}

done_testing();

__END__

=head1 NAME

t/997-micro-supervisor-orphan-fix.t - micro-probe for the supervisor orphan fix

=head1 DESCRIPTION

Verifies the three supervisor-orphan changes in
C<Developer::Dashboard::RuntimeManager>: dead-pid adoption, the quiesce
timeout, and refusing to adopt a live starman worker as a supervisor
parent.

=head1 PURPOSE

Prove the new supervisor behaviour directly, in-process, before the fix is
solo-verified on Jenkins: a supervisor with no web and no live loops exits
C<quiesced>; a live watched loop resets the quiesce timer; a dead web pid
is adopted and exits C<parent-gone> after the grace period, stopping the
watched loop; a live web pid keeps the supervisor alive; a live starman
worker is never adopted as a parent, and a live adopted parent still
decides when web.json names a worker.

=head1 WHY IT EXISTS

No existing test exercises the supervisor parent adoption or the quiesce
path directly: the loop tests in t/100 and t/119 stub the supervisor loop
to a single pass, and t/05 only covers the healthy serve path. The Pi
accumulated 19 orphaned supervisors because the adoption required a live
web pid, a supervisor with no web never exited, and supervisors could
adopt starman workers that never die. This micro proves each of the three
holes is closed, with short env timeouts so it runs in seconds.

=head1 WHEN TO USE

Use this file when changing the supervisor parent adoption or the quiesce
timeout; and when verifying the orphan fix before its Jenkins solo. Remove it in the cleanup commit
once the solo has verified the fix on all four legs.

=head1 HOW TO USE

Run C<prove -lv t/997-micro-supervisor-orphan-fix.t> while iterating on
the supervisor fix. Keep it green under C<prove -lr t> until the cleanup
commit removes it.

=head1 WHAT USES IT

Developers verifying the supervisor orphan fix, and the Jenkins solo that
runs this file on all four legs before the fix is committed.

=head1 EXAMPLES

Example 1:

  prove -lv t/997-micro-supervisor-orphan-fix.t

Run the supervisor orphan fix checks alone.

Example 2:

  prove -lr t

Run them as part of the full repository suite before release.

=cut
