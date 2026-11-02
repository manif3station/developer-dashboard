#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(EBADF);
use Test::More;

use lib 'lib';

use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;

# Keep the Windows background-start readiness loop instant and hermetic.
$ENV{DEVELOPER_DASHBOARD_RUNTIME_STABILITY_POLLS} = 1;

{
    package Local::Runner;
    sub new           { return bless {}, shift }
    sub running_loops { return () }

    package Local::Server;
    sub new { my ( $class, %args ) = @_; return bless { %args }, $class }
    sub run { return 'foreground-ran' }
    sub _run_ssl_backend_process {
        my ( $self, $daemon ) = @_;
        return $self->{run_ssl_backend}->($daemon);
    }
}

my $original_cwd = getcwd();
my $home         = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";

my $paths  = Developer::Dashboard::PathRegistry->new( home => $home );
my $files  = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );

my $manager = Developer::Dashboard::RuntimeManager->new(
    app_builder => sub { return Local::Server->new(@_) },
    config      => $config,
    files       => $files,
    paths       => $paths,
    runner      => Local::Runner->new,
);

# ---------------------------------------------------------------------------
# _write_startup_pipe_message: the startup pipe writer closes cleanly.
#
# The shipped _close_startup_pipe_writer wrapper exists precisely so this seam
# can be driven from both sides. Every real invocation on this host reports a
# close failure that the caller then classifies via $!, so the "close reported
# success" arm of the guard is only reachable through the documented wrapper
# override. Drive it here so the success arm stays exercised and cannot rot
# into a silent die.
# ---------------------------------------------------------------------------
{
    no warnings 'redefine';
    my @closed;
    local *Developer::Dashboard::RuntimeManager::_close_startup_pipe_writer = sub {
        my ( $self, $writer ) = @_;
        push @closed, $writer;
        return 1;
    };

    my $path = File::Spec->catfile( $home, 'startup-clean-close.txt' );
    open my $writer, '>', $path or die "Unable to open $path: $!";
    my $payload = "ok|4242|0.0.0.0|7890\n";
    ok(
        $manager->_write_startup_pipe_message( $writer, $payload ),
        '_write_startup_pipe_message succeeds when the startup pipe writer closes cleanly'
    );
    is( scalar @closed, 1, '_write_startup_pipe_message closes the startup pipe writer exactly once' );
    close $writer or die "Unable to close $path: $!";

    open my $reader, '<', $path or die "Unable to read $path: $!";
    my $written = do { local $/; <$reader> };
    close $reader or die "Unable to close $path: $!";
    is( $written, $payload, '_write_startup_pipe_message wrote the whole payload before the clean close' );
}

# The counterpart arm of the same guard: the writer reports a close failure and
# the caller tolerates it once it recognizes the expected errno value.
{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_close_startup_pipe_writer = sub {
        $! = EBADF;
        return 0;
    };

    my $path = File::Spec->catfile( $home, 'startup-tolerated-close.txt' );
    open my $writer, '>', $path or die "Unable to open $path: $!";
    ok(
        $manager->_write_startup_pipe_message( $writer, "ok|4243|0.0.0.0|7891\n" ),
        '_write_startup_pipe_message tolerates the expected startup pipe close failure'
    );
    close $writer or die "Unable to close $path: $!";
}

# ---------------------------------------------------------------------------
# _start_web_windows_background: both live sides of the persisted-pid choice.
#
# The confirmed listener pid wins when it is a usable process id, and the
# spawned background pid is the fallback when listener discovery yields a
# falsy pid for the port.
# ---------------------------------------------------------------------------
{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_windows_background_web_command = sub {
        return ( 'perl.exe', 'dashboard', 'serve' );
    };
    local *Developer::Dashboard::RuntimeManager::_spawn_windows_background_command = sub { return 7100 };
    local *Developer::Dashboard::RuntimeManager::_port_accepting_connections       = sub { return 1 };

    {
        local *Developer::Dashboard::RuntimeManager::_listener_pids_for_port = sub { return (7301) };
        is(
            $manager->_start_web_windows_background( host => '127.0.0.1', port => 7890, workers => 2, ssl => 1 ),
            7301,
            '_start_web_windows_background persists the confirmed listener pid'
        );
        my $state = $manager->web_state;
        is( $state->{pid},     7301,        'the persisted Windows web state keeps the confirmed listener pid' );
        is( $state->{workers}, 2,           'the persisted Windows web state keeps the requested worker count' );
        is( $state->{ssl},     1,           'the persisted Windows web state keeps the requested ssl flag' );
        is( $state->{host},    '127.0.0.1', 'the persisted Windows web state keeps the requested host' );
        my $pidfile = $files->read('web_pid');
        chomp $pidfile if defined $pidfile;
        is( $pidfile, '7301', 'the Windows web pid file records the confirmed listener pid' );
    }

    {
        local *Developer::Dashboard::RuntimeManager::_listener_pids_for_port = sub { return (0) };
        is(
            $manager->_start_web_windows_background( host => '127.0.0.1', port => 7890 ),
            7100,
            '_start_web_windows_background falls back to the spawned pid when the listener pid is falsy'
        );
        my $state = $manager->web_state;
        is( $state->{pid},     7100, 'the persisted Windows web state falls back to the spawned pid' );
        is( $state->{workers}, 1,    'the persisted Windows web state defaults the worker count' );
        is( $state->{ssl},     0,    'the persisted Windows web state defaults the ssl flag' );
        my $pidfile = $files->read('web_pid');
        chomp $pidfile if defined $pidfile;
        is( $pidfile, '7100', 'the Windows web pid file records the spawned fallback pid' );
    }
}

# ---------------------------------------------------------------------------
# serve_ssl_backend_foreground: validate the isolated backend inputs and default
# its worker count before building the backend server.
# ---------------------------------------------------------------------------
{
    my $err = eval { $manager->serve_ssl_backend_foreground( port => 7890 ); 1 } ? '' : $@;
    like( $err, qr/Missing SSL backend host/, 'serve_ssl_backend_foreground requires an internal host' );

    $err = eval { $manager->serve_ssl_backend_foreground( host => '127.0.0.1' ); 1 } ? '' : $@;
    like( $err, qr/Missing SSL backend port/, 'serve_ssl_backend_foreground requires an internal port' );

    $err = eval { $manager->serve_ssl_backend_foreground( host => '127.0.0.1', port => 0 ); 1 } ? '' : $@;
    like( $err, qr/SSL backend port must be a positive integer/, 'serve_ssl_backend_foreground rejects a zero internal port' );

    $err = eval { $manager->serve_ssl_backend_foreground( host => '127.0.0.1', port => 7890, workers => 0 ); 1 } ? '' : $@;
    like( $err, qr/Worker count must be a positive integer/, 'serve_ssl_backend_foreground rejects a zero worker count' );

    no warnings 'redefine';
    no strict 'refs';
    require Developer::Dashboard::Web::Server::Daemon;
    my %built;
    my $server = bless {
        run_ssl_backend => sub { return 23 },
    }, 'Local::Server';
    local *{'Developer::Dashboard::Web::Server::Daemon::new'} = sub {
        my ( $class, %args ) = @_;
        $built{daemon} = \%args;
        return bless \%args, 'Local::SSLServer::Daemon';
    };
    local $manager->{app_builder} = sub {
        my %args = @_;
        $built{server} = \%args;
        return $server;
    };

    is(
        $manager->serve_ssl_backend_foreground( host => '127.0.0.1', port => 7890 ),
        23,
        'serve_ssl_backend_foreground returns the backend runner status',
    );
    is( $built{server}{workers}, 1, 'serve_ssl_backend_foreground defaults the worker count' );
    is( $built{server}{ssl}, 1, 'serve_ssl_backend_foreground always builds the isolated server with SSL enabled' );
    is( $built{daemon}{internal_port}, 7890, 'serve_ssl_backend_foreground passes the internal listener port to its daemon' );
}

# ---------------------------------------------------------------------------
# _start_web_background: use the spawned child pid when listener discovery
# returns a false pid even though the port has become ready.
# ---------------------------------------------------------------------------
{
    no warnings 'redefine';
    require Developer::Dashboard::GoRoutine;
    local *Developer::Dashboard::RuntimeManager::_cleanup_web_files = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::_background_web_command = sub { return ('perl', 'web-foreground') };
    local *Developer::Dashboard::RuntimeManager::_runtime_stability_polls = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::_listener_pids_for_port = sub { return (0) };
    local *Developer::Dashboard::RuntimeManager::_port_accepting_connections = sub { return 1 };
    local *Developer::Dashboard::GoRoutine::spawn = sub { return 7400 };

    is(
        $manager->_start_web_background( host => '127.0.0.1', port => 7891 ),
        7400,
        '_start_web_background falls back to the spawned pid when the ready listener pid is false',
    );
    is( $manager->web_state->{pid}, 7400, '_start_web_background persists the spawned fallback pid' );
}

# ---------------------------------------------------------------------------
# _is_managed_web: a stale/non-running state must not validate an opaque server
# title as a managed Starman listener.
# ---------------------------------------------------------------------------
{
    no warnings 'redefine';
    local *Developer::Dashboard::RuntimeManager::_same_pid_namespace = sub { return 1 };
    local *Developer::Dashboard::RuntimeManager::_read_process_env_marker = sub { return undef };
    local *Developer::Dashboard::RuntimeManager::_read_process_title = sub { return 'starman master' };
    local *Developer::Dashboard::RuntimeManager::_read_settled_web_state = sub {
        return ( { pid => $$, port => 7890, status => '' }, 0 );
    };
    local *Developer::Dashboard::RuntimeManager::_listener_pids_for_port = sub { return ($$) };
    ok( !$manager->_is_managed_web($$), '_is_managed_web rejects a saved state without running status' );
}

chdir $original_cwd or die "Unable to chdir to $original_cwd: $!";

done_testing;

__END__

=pod

=head1 NAME

t/119-runtimemanager-coverage-3.t - runtime manager startup-pipe and Windows background-start coverage

=head1 PURPOSE

This test closes runtime lifecycle decision points: the arm of the startup-pipe
writer guard taken when the pipe handle closes cleanly; both sides of the
Windows background-start process-id choice; SSL backend argument validation and
worker defaults; the spawned-pid fallback for a ready web listener; and rejection
of stale state when validating an opaque Starman title.

=head1 WHY IT EXISTS

These decisions are invisible to the rest of the suite. The startup-pipe close
wrapper always reports a failure that the caller classifies through the errno
value on this host, so the success arm was never executed and a future edit
could have turned it into an unconditional die without any test noticing. The
Windows background start similarly only ever ran with a usable listener pid in
the rest of the suite, leaving its documented fallback to the spawned pid
unproven. SSL helper argument guards, the ready-listener fallback, and the
persisted-state validation protect distinct startup and process-ownership paths.
This file keeps these choices executable and measurable by the coverage gate.

=head1 WHEN TO USE

Use this file when changing how the background web child reports startup back
to its parent, how the startup pipe writer is closed and its errno classified,
how the Windows background start resolves and persists the web service process
id, worker count, and ssl flag; how the isolated TLS backend validates its
arguments; or how runtime state is used to identify a managed Starman process.

=head1 HOW TO USE

Run C<prove -lv t/119-runtimemanager-coverage-3.t> while iterating on the
runtime manager. Keep it green under C<prove -lr t> and inside the coverage
gate before release.

=head1 WHAT USES IT

Developers changing the runtime lifecycle manager, the repository test suite,
and the branch/condition coverage gate all rely on this file.

=head1 EXAMPLES

Example 1:

  prove -lv t/119-runtimemanager-coverage-3.t

Run the runtime-manager startup-pipe, SSL-backend, listener-fallback, and
Windows background-start checks alone.

Example 2:

  prove -lr t

Run them as part of the full repository suite before release.

=cut
