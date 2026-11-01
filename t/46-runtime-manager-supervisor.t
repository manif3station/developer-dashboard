#!/usr/bin/env perl

use strict;
use warnings;

use Cwd qw(getcwd);
use Errno qw(EACCES);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes qw(sleep);

use lib 'lib';

use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;
use Developer::Dashboard::GoRoutine ();

{
    package Local::SupervisorRunner;

    sub new { return bless {}, shift }
    sub running_loops { return (); }
}

my $original_cwd = getcwd();
my $repo_lib = File::Spec->catdir( $original_cwd, 'lib' );
my $test_cwd = tempdir( CLEANUP => 1 );
chdir $test_cwd or die "Unable to chdir to $test_cwd: $!";

# _runtime_fixture_script($body)
# Builds Perl source for an isolated runtime-manager process fixture.
# Input: statements to run after a filesystem-backed manager is reconstructed.
# Output: complete child Perl source string for GoRoutine::spawn.
sub _runtime_fixture_script {
    my ($body) = @_;
    die "runtime fixture body must be a non-empty scalar\n"
      if !defined $body || ref($body) || $body eq '';
    return sprintf q{
        use lib q{%s};
        use Developer::Dashboard::PathRegistry;
        use Developer::Dashboard::FileRegistry;
        use Developer::Dashboard::RuntimeManager;
        use Developer::Dashboard::GoRoutine ();
        my $paths = Developer::Dashboard::PathRegistry->new(home => $ENV{HOME});
        my $files = Developer::Dashboard::FileRegistry->new(paths => $paths);
        my $manager = Developer::Dashboard::RuntimeManager->new(
            app_builder => sub { die "unexpected app build in process fixture\n" },
            config => bless({}, 'Local::FixtureConfig'),
            files => $files,
            paths => $paths,
            runner => bless({}, 'Local::FixtureRunner'),
        );
        %s
    }, $repo_lib, $body;
}

# _spawn_perl_fixture($script, $options)
# Starts a Perl child fixture through the native GoRoutine process API.
# Input: child source and optional process options hash reference.
# Output: positive child process identifier.
sub _spawn_perl_fixture {
    my ( $script, $options ) = @_;
    die "process fixture source must be a non-empty scalar\n"
      if !defined $script || ref($script) || $script eq '';
    return Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-e', $script ],
        $options || {},
    );
}

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

my $paths  = Developer::Dashboard::PathRegistry->new( home => $home );
my $files  = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $runner = Local::SupervisorRunner->new;

my $manager = Developer::Dashboard::RuntimeManager->new(
    app_builder => sub { die "app builder should not run in supervisor tests\n" },
    config      => $config,
    files       => $files,
    paths       => $paths,
    runner      => $runner,
);

is(
    $manager->_collector_supervisor_process_title,
    'dashboard collector supervisor',
    'collector supervisor uses the expected process title',
);
like(
    $manager->_collector_supervisor_pidfile,
    qr/collector-supervisor\.pid\z/,
    'collector supervisor pidfile path is stable',
);
like(
    $manager->_collector_supervisor_statefile,
    qr/collector-supervisor\.json\z/,
    'collector supervisor statefile path is stable',
);

is_deeply(
    [ $manager->_normalized_collector_watch_names( [ 'beta', '', 'alpha', 'beta', undef ] ) ],
    [ 'alpha', 'beta' ],
    'collector watchdog target names are normalized, filtered, and sorted',
);

{
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_RESTART_LIMIT} = 7;
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_RESTART_WINDOW_SECONDS} = 42;
    local $ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL} = 0.75;
    is( $manager->_collector_restart_limit, 7, 'collector restart limit respects the environment override' );
    is( $manager->_collector_restart_window_seconds, 42, 'collector restart window respects the environment override' );
    is( $manager->_collector_supervisor_poll_interval, 0.75, 'collector supervisor poll interval respects the environment override' );
}

is( $manager->_collector_restart_limit, 3, 'collector restart limit defaults to three restarts' );
is( $manager->_collector_restart_window_seconds, 300, 'collector restart window defaults to five minutes' );
is( $manager->_collector_supervisor_poll_interval, 5, 'collector supervisor poll interval defaults to five seconds' );

ok(
    $manager->_looks_like_collector_supervisor_process(
        { pid => $$, args => 'dashboard collector supervisor' }
    ),
    'collector supervisor title records are recognized',
);
ok(
    $manager->_looks_like_collector_supervisor_process(
        { pid => $$, args => '_dashboard-core collector-supervisor-foreground' }
    ),
    'collector supervisor helper command lines are recognized',
);
ok(
    $manager->_looks_like_collector_supervisor_process(
        { pid => $$, args => 'perl /tmp/_dashboard-core collector-supervisor-foreground --poll 1' }
    ),
    'collector supervisor perl helper command lines are recognized',
);
ok(
    !$manager->_looks_like_collector_supervisor_process(
        { pid => $$, args => 'dashboard collector start alpha' }
    ),
    'unrelated collector commands are not mistaken for the supervisor',
);

{
    my @signals;
    my @sleeps;
    my $reaped_pid = 0;
    my $cleaned = 0;
    my $running_checks = 0;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::sleep = sub { push @sleeps, $_[0]; return 0 };
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_running = sub { return 4242 };
    local *Developer::Dashboard::RuntimeManager::_pid_is_running = sub {
        $running_checks++;
        return $running_checks <= 22 ? 1 : 0;
    };
    local *Developer::Dashboard::RuntimeManager::_send_signal = sub {
        my ( $self, $signal, @pids ) = @_;
        push @signals, [ $signal, @pids ];
        return scalar @pids;
    };
    local *Developer::Dashboard::RuntimeManager::_reap_child_process = sub {
        my ( $self, $pid ) = @_;
        $reaped_pid = $pid;
        return 1;
    };
    local *Developer::Dashboard::RuntimeManager::_cleanup_collector_supervisor_files = sub {
        $cleaned = 1;
        return 1;
    };
    $manager->_stop_collector_supervisor;
    is_deeply(
        \@signals,
        [
            [ 'TERM', 4242 ],
            [ 'KILL', 4242 ],
        ],
        '_stop_collector_supervisor escalates from TERM to KILL when the supervisor stays alive',
    );
    is( scalar @sleeps, 21, '_stop_collector_supervisor waits through the TERM loop and the post-KILL confirmation loop' );
    is( $reaped_pid, 4242, '_stop_collector_supervisor reaps the stopped supervisor pid after escalation' );
    ok( $cleaned, '_stop_collector_supervisor still cleans up supervisor state files after escalation' );
}

{
    my $state = $manager->_write_collector_supervisor_state(
        {
            pid           => 3210,
            process_name  => $manager->_collector_supervisor_process_title,
            status        => 'running',
            watched_names => [ 'alpha', 'beta' ],
        }
    );
    is( $state->{pid}, 3210, 'collector supervisor state write returns the persisted payload' );
    is_deeply(
        $manager->_collector_supervisor_state,
        {
            pid           => 3210,
            process_name  => $manager->_collector_supervisor_process_title,
            status        => 'running',
            watched_names => [ 'alpha', 'beta' ],
        },
        'collector supervisor state reads back the persisted payload',
    );
    ok( $manager->_cleanup_collector_supervisor_files, 'collector supervisor cleanup returns a true value' );
    ok( !-f $manager->_collector_supervisor_statefile, 'collector supervisor cleanup removes the state file' );
}

{
    my $rename_attempt = 0;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::is_windows = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::_rename_path = sub {
        my ( undef, $source, $target ) = @_;
        $rename_attempt++;
        if ( $rename_attempt == 1 ) {
            $! = EACCES;
            return 0;
        }
        return CORE::rename( $source, $target );
    };
    local *Developer::Dashboard::RuntimeManager::_replace_path_via_powershell = sub {
        my ( undef, $source, $target ) = @_;
        return ( CORE::rename( $source, $target ) ? 1 : 0, $! );
    };
    my $state = $manager->_write_collector_supervisor_state(
        {
            pid           => 6543,
            process_name  => $manager->_collector_supervisor_process_title,
            status        => 'running',
            watched_names => ['gamma'],
        }
    );
    is( $state->{pid}, 6543, '_write_collector_supervisor_state returns the payload after the Windows PowerShell replacement fallback' );
    is_deeply(
        $manager->_collector_supervisor_state,
        {
            pid           => 6543,
            process_name  => $manager->_collector_supervisor_process_title,
            status        => 'running',
            watched_names => ['gamma'],
        },
        '_write_collector_supervisor_state persists the payload after the Windows PowerShell replacement fallback',
    );
    ok( $manager->_cleanup_collector_supervisor_files, 'collector supervisor cleanup still works after the Windows replacement fallback path' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_read_process_env_marker = sub { return '1' };
    ok( $manager->_is_collector_supervisor($$), 'collector supervisor marker environment wins process detection' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_read_process_env_marker = sub { return undef };
    local *Developer::Dashboard::RuntimeManager::_read_process_title = sub {
        return 'dashboard collector supervisor';
    };
    ok( $manager->_is_collector_supervisor($$), 'collector supervisor title fallback detects the process' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_read_process_env_marker = sub { return undef };
    local *Developer::Dashboard::RuntimeManager::_read_process_title = sub {
        return 'perl /tmp/_dashboard-core collector-supervisor-foreground';
    };
    ok( $manager->_is_collector_supervisor($$), 'collector supervisor helper-shape fallback detects the process' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_read_process_env_marker = sub { return undef };
    local *Developer::Dashboard::RuntimeManager::_read_process_title = sub {
        return 'dashboard collector start alpha';
    };
    ok( !$manager->_is_collector_supervisor($$), 'collector supervisor detection rejects unrelated processes' );
}

{
    open my $fh, '>', $manager->_collector_supervisor_pidfile or die $!;
    print {$fh} "$$\n";
    close $fh;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_same_pid_namespace = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::_is_collector_supervisor = sub { return 1 };
    is(
        $manager->_collector_supervisor_running,
        $$,
        'collector supervisor running returns the live managed pid from the pidfile',
    );
}

{
    open my $fh, '>', $manager->_collector_supervisor_pidfile or die $!;
    print {$fh} "999999\n";
    close $fh;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_is_collector_supervisor = sub { return 0 };
    ok( !defined $manager->_collector_supervisor_running, 'collector supervisor running clears stale pidfiles' );
    ok( !-f $manager->_collector_supervisor_pidfile, 'collector supervisor running removes stale pidfiles after cleanup' );
}

{
    my $stopped = 0;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_stop_collector_supervisor = sub {
        $stopped++;
        return;
    };
    ok( !defined $manager->_set_collector_supervisor_targets( [] ), 'empty collector supervisor targets stop the watchdog' );
    is( $stopped, 1, 'empty collector supervisor targets delegate to the watchdog stop path' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_running = sub { return 7654 };
    my $pid = $manager->_set_collector_supervisor_targets( [ 'beta', 'alpha' ] );
    is( $pid, 7654, 'collector supervisor target updates keep an already-running supervisor' );
    is_deeply(
        $manager->_collector_supervisor_state->{watched_names},
        [ 'alpha', 'beta' ],
        'collector supervisor target updates persist the normalized watch list',
    );
    is(
        $manager->_collector_supervisor_state->{status},
        'running',
        'collector supervisor target updates mark existing watchdogs as running',
    );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_running = sub { return undef };
    local *Developer::Dashboard::RuntimeManager::_start_collector_supervisor = sub { return 8844 };
    is(
        $manager->_set_collector_supervisor_targets( [ 'gamma', 'alpha' ] ),
        8844,
        'collector supervisor target updates start a watchdog when one is not already running',
    );
    is(
        $manager->_collector_supervisor_state->{status},
        'starting',
        'collector supervisor target updates mark new watchdogs as starting before launch',
    );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_state = sub {
        return { watched_names => [ 'alpha', 'beta' ] };
    };
    local *Developer::Dashboard::RuntimeManager::_set_collector_supervisor_targets = sub {
        my ( undef, $names ) = @_;
        return join ',', @{$names};
    };
    is(
        $manager->_merge_collector_supervisor_targets( [ 'beta', 'alpha' ] ),
        'alpha,beta',
        'collector supervisor merges new watched names into the existing set',
    );
    is(
        $manager->_remove_collector_supervisor_targets( ['alpha'] ),
        'beta',
        'collector supervisor removes requested names from the watched set',
    );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::is_windows = sub { 1 };
    local *Developer::Dashboard::RuntimeManager::_current_perl_command = sub { return 'perl.exe' };
    local *Developer::Dashboard::RuntimeManager::_dashboard_core_helper_path = sub {
        my ( undef, $command ) = @_;
        return "C:/dd/$command";
    };
    is_deeply(
        [ $manager->_background_collector_supervisor_command ],
        [ 'perl.exe', $manager->_perl_library_args, 'C:/dd/collector-supervisor-foreground', 'collector-supervisor-foreground' ],
        'collector supervisor Windows helper command uses the private foreground entrypoint',
    );
}

{
    my ( $spawned_argv, $spawned_options );
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::is_windows = sub { 1 };
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_running = sub { return undef };
    local *Developer::Dashboard::RuntimeManager::_current_perl_command = sub { return 'perl.exe' };
    local *Developer::Dashboard::RuntimeManager::_dashboard_core_helper_path = sub {
        my ( undef, $command ) = @_;
        return "C:/dd/$command";
    };
    local *Developer::Dashboard::GoRoutine::spawn = sub {
        ( $spawned_argv, $spawned_options ) = @_;
        return 5566;
    };
    $manager->_write_collector_supervisor_state(
        {
            watched_names => ['alpha'],
        }
    );
    is( $manager->_start_collector_supervisor, 5566, 'collector supervisor starts through the Windows detached helper path' );
    is_deeply(
        $spawned_argv,
        [ 'perl.exe', $manager->_perl_library_args, 'C:/dd/collector-supervisor-foreground', 'collector-supervisor-foreground' ],
        'collector supervisor start launches the expected helper command without a shell',
    );
    is_deeply(
        $spawned_options,
        {
            stdin  => File::Spec->devnull(),
            stdout => $files->collector_log,
            stderr => $files->collector_log . '.stderr',
        },
        'collector supervisor start redirects helper standard streams',
    );
    is( $manager->_collector_supervisor_state->{pid}, 5566, 'collector supervisor Windows start persists the supervisor pid' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_running = sub { return 6677 };
    $manager->_write_collector_supervisor_state(
        {
            watched_names => ['alpha'],
        }
    );
    is( $manager->_start_collector_supervisor, 6677, 'collector supervisor start returns an already-running watchdog pid without relaunching it' );
}

{
    my $child_pid;
    no warnings 'redefine';
    my ( $spawned_argv, $spawned_options );
    local *Developer::Dashboard::RuntimeManager::is_windows = sub { 0 };
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_running = sub { return undef };
    local *Developer::Dashboard::RuntimeManager::_current_perl_command = sub { return 'perl' };
    local *Developer::Dashboard::RuntimeManager::_dashboard_core_helper_path = sub {
        my ( undef, $command ) = @_;
        return "/tmp/$command";
    };
    local *Developer::Dashboard::GoRoutine::spawn = sub {
        ( $spawned_argv, $spawned_options ) = @_;
        return 6677;
    };
    $manager->_write_collector_supervisor_state(
        {
            watched_names => ['alpha'],
        }
    );
    $child_pid = $manager->_start_collector_supervisor;
    is( $child_pid, 6677, 'collector supervisor starts through the GoRoutine process path on Unix' );
    is_deeply(
        $spawned_argv,
        [ 'perl', $manager->_perl_library_args, '/tmp/collector-supervisor-foreground', 'collector-supervisor-foreground' ],
        'collector supervisor launches the private foreground helper on Unix',
    );
    is( $spawned_options->{stdout}, $files->collector_log, 'Unix supervisor output is redirected to the collector log' );
}

{
    my @events;
    my $reap_calls = 0;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_state = sub {
        return { watched_names => ['alpha'] };
    };
    local *Developer::Dashboard::RuntimeManager::_supervise_collectors_once = sub {
        $SIG{CHLD}->() if ref( $SIG{CHLD} ) eq 'CODE';
        die "watchdog boom\n";
    };
    local *Developer::Dashboard::RuntimeManager::_reap_any_child_processes = sub {
        $reap_calls++;
        return 0;
    };
    local *Developer::Dashboard::RuntimeManager::_write_collector_supervisor_state = sub {
        my ( undef, $state ) = @_;
        push @events, { %{$state} };
        return $state;
    };
    local *Developer::Dashboard::RuntimeManager::sleep = sub { die "loop-finished\n" };
    my $error = eval {
        $manager->_run_collector_supervisor_child( daemonize => 0, redirect => 0 );
        return '';
    } || $@;
    like( $error, qr/loop-finished/, 'collector supervisor child loop can be broken cleanly in tests after one pass' );
    ok(
        ( scalar grep { ( $_->{status} || '' ) eq 'error' && ( $_->{error} || '' ) =~ /watchdog boom/ } @events ),
        'collector supervisor child records watchdog errors in supervisor state',
    );
    ok( $reap_calls >= 2, 'collector supervisor child reaps exited children during the loop and from the CHLD handler' );
}

{
    my $marker = File::Spec->catfile( $home, 'collector-supervisor-defaults.marker' );
    my $child_script = _runtime_fixture_script(q{
        no warnings 'redefine';
        local *Developer::Dashboard::RuntimeManager::_collector_supervisor_state = sub {
            return { watched_names => ['alpha'] };
        };
        local *Developer::Dashboard::RuntimeManager::_detach_web_process_session = sub {
            open my $fh, '>>', $ENV{DASHBOARD_SUPERVISOR_MARKER} or die $!;
            print {$fh} "detached\n";
            close $fh;
            return 1;
        };
        local *Developer::Dashboard::RuntimeManager::_supervise_collectors_once = sub { return {} };
        local *Developer::Dashboard::RuntimeManager::_shutdown_collector_supervisor = sub {
            my ( undef, $status ) = @_;
            open my $fh, '>>', $ENV{DASHBOARD_SUPERVISOR_MARKER} or die $!;
            print {$fh} "shutdown:$status\n";
            close $fh;
            exit 0;
        };
        local *Developer::Dashboard::RuntimeManager::sleep = sub {
            Developer::Dashboard::GoRoutine::terminate_process( $$, 'TERM' );
            return 0;
        };
        $manager->_run_collector_supervisor_child;
        exit 1;
    });
    my $child = _spawn_perl_fixture(
        $child_script,
        {
            env => { HOME => $home, DASHBOARD_SUPERVISOR_MARKER => $marker },
            stdout => "$home/collector-supervisor-defaults.out",
            stderr => "$home/collector-supervisor-defaults.err",
        },
    );
    is( Developer::Dashboard::GoRoutine::wait_process($child), 0,
        'collector supervisor child default daemonize and redirect path exits cleanly after TERM' );
    open my $fh, '<', $marker or die "Unable to read $marker: $!";
    my @marker_lines = <$fh>;
    close $fh;
    ok(
        ( scalar grep { $_ eq "detached\n" } @marker_lines ),
        'collector supervisor child default path detaches the process session before entering the loop',
    );
    ok(
        ( scalar grep { $_ eq "shutdown:stopped\n" } @marker_lines ),
        'collector supervisor child TERM handler invokes the shutdown closure through the local signal binding',
    );
}

{
    my $shutdown_status = '';
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_collector_supervisor_state = sub {
        return { watched_names => [] };
    };
    local *Developer::Dashboard::RuntimeManager::_shutdown_collector_supervisor = sub {
        my ( undef, $status ) = @_;
        $shutdown_status = $status;
        die "shutdown-$status\n";
    };
    my $error = eval {
        $manager->_run_collector_supervisor_child( daemonize => 0, redirect => 0 );
        return '';
    } || $@;
    like( $error, qr/shutdown-stopped/, 'collector supervisor child exits through shutdown when no targets remain' );
    is( $shutdown_status, 'stopped', 'collector supervisor child requests a stopped shutdown when the watch list is empty' );
}

{
    my $child_script = _runtime_fixture_script(q{
        $manager->_write_collector_supervisor_state(
            {
                watched_names => ['alpha'],
            }
        );
        open my $fh, '>', $manager->_collector_supervisor_pidfile or die $!;
        print {$fh} "$$\n";
        close $fh;
        $manager->_shutdown_collector_supervisor('stopped');
    });
    my $child = _spawn_perl_fixture(
        $child_script,
        {
            env => { HOME => $home },
            stdout => "$home/collector-supervisor-shutdown.out",
            stderr => "$home/collector-supervisor-shutdown.err",
        },
    );
    is( Developer::Dashboard::GoRoutine::wait_process($child), 0,
        'collector supervisor shutdown exits cleanly through GoRoutine' );
    ok( !-f $manager->_collector_supervisor_pidfile, 'collector supervisor shutdown removes the pidfile' );
    ok( !-f $manager->_collector_supervisor_statefile, 'collector supervisor shutdown removes the statefile' );
}

{
    my $child = _spawn_perl_fixture(q{$SIG{TERM} = sub { exit 0 }; while (1) { select undef, undef, undef, 0.1 }},
        { env => { HOME => $home }, stdout => "$home/collector-supervisor-stop.out", stderr => "$home/collector-supervisor-stop.err" });
    sleep 0.2;
    open my $fh, '>', $manager->_collector_supervisor_pidfile or die $!;
    print {$fh} "$child\n";
    close $fh;
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_same_pid_namespace = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::_is_collector_supervisor = sub {
        my ( undef, $pid ) = @_;
        return $pid == $child ? 1 : 0;
    };
    is( $manager->_stop_collector_supervisor, $child, 'collector supervisor stop returns the managed child pid' );
    ok( !Developer::Dashboard::GoRoutine::process_running($child),
        'collector supervisor stop reaps the GoRoutine-spawned child instead of leaving it running' );
    ok( !-f $manager->_collector_supervisor_pidfile, 'collector supervisor stop removes the pidfile after shutdown' );
}

{
    my $child = _spawn_perl_fixture('exit 0;',
        { env => { HOME => $home }, stdout => "$home/collector-supervisor-reap.out", stderr => "$home/collector-supervisor-reap.err" });
    my $reaped = 0;
    for ( 1 .. 20 ) {
        $reaped = $manager->_reap_any_child_processes;
        last if $reaped;
        select undef, undef, undef, 0.05;
    }
    is( $reaped, 1, 'collector supervisor reap helper reaps one exited direct child' );
    ok( !Developer::Dashboard::GoRoutine::process_running($child),
        'collector supervisor reap helper leaves no GoRoutine child running after reaping it' );
}

END {
    chdir $original_cwd if defined $original_cwd && length $original_cwd;
}

done_testing;

__END__

=pod

=head1 NAME

t/46-runtime-manager-supervisor.t - coverage and regression tests for the collector watchdog supervisor

=head1 WHAT IT IS

This test file exercises the collector watchdog supervisor helpers inside
L<Developer::Dashboard::RuntimeManager>.

=head1 WHAT IT IS FOR

It verifies the state-file, pidfile, process-identification, detached-launch,
shutdown, and watchdog-loop behaviour added for collector self-healing.

=head1 PURPOSE

Test file in the Developer Dashboard codebase. This file verifies collector
watchdog supervisor behaviour, detached lifecycle handling, and coverage for
the RuntimeManager resilience path.
Open this file when you need the implementation, regression coverage, or
runtime entrypoint for that responsibility rather than guessing which part of
the tree owns it.

=head1 WHY IT EXISTS

The collector watchdog is meant to keep managed collectors alive, restart them
after unexpected exits, and escalate to human attention when repeated crashes
continue. These tests keep that resilience path covered so the implementation
does not silently regress.

=head1 WHEN TO USE

This test runs as part of the normal repository test suite and should also be
run when changing collector lifecycle code, watchdog state handling, or
detached helper startup paths.

=head1 HOW TO USE

Run it directly during focused debugging:

  perl -Ilib t/46-runtime-manager-supervisor.t

Run it through the standard harness:

  prove -lv t/46-runtime-manager-supervisor.t

Run it under coverage with the rest of the suite:

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t

=head1 WHAT USES IT

The repository test harness, coverage gates, release metadata checks, and
maintainers changing the runtime manager use this file to prove the watchdog
behaviour still matches the expected contract.

=head1 EXAMPLES

Example: verify only the watchdog supervisor coverage after editing its state
helpers.

  prove -lv t/46-runtime-manager-supervisor.t

Example: rerun the runtime-manager focused suite after changing collector
restart policy.

  prove -lv t/09-runtime-manager.t t/46-runtime-manager-supervisor.t

Example: confirm the full repository still keeps watchdog code covered.

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t

=cut
