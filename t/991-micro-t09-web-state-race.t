use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes qw(sleep);

use lib 'lib';

use Developer::Dashboard::Config;
use Developer::Dashboard::Collector;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::RuntimeManager;
use Developer::Dashboard::GoRoutine qw(spawn terminate_process wait_process);

# Micro: reproduce the build #236 t/09 test 93 failure and prove the
# mechanism before any fix. Test 93 expects the parent to read web_state
# status 'running' on Windows after TERM (the handler never runs there,
# so no 'stopped' write happens), but the parent read undef for 30 polls.
# The code reading says the race is in _run_web_child: the startup
# message is written BEFORE _write_web_state, and the parent sends TERM
# the moment it sees the startup line. On Windows the state write runs
# two icacls spawns plus a rename, hundreds of milliseconds, while the
# parent's poll delay is 0-100ms - so TERM (TerminateProcess, instant)
# usually lands mid-write, the child dies, the target state file never
# appears, and the parent reads undef forever. On Unix the write is a
# pair of syscalls (microseconds) and the handler writes 'stopped'
# anyway, so the race is invisible there. Run 1 repeats the immediate
# TERM up to 5 times and records whether the state is missing; run 2
# waits until the 'running' state is visible before TERM and records
# whether the state then survives the kill. If run 1 shows the missing
# state on Windows and run 2 shows 'running', the mechanism is proven
# and the fix is test-only: wait for the 'running' state before TERM.

my $IS_WINDOWS = $^O eq 'MSWin32';
my $repo_lib   = File::Spec->catdir( getcwd(), 'lib' );

# _spawn_perl_fixture and _runtime_fixture_script are copied verbatim
# from t/09-runtime-manager.t so the micro drives the child exactly
# the way the failing test does.
sub _spawn_perl_fixture {
    my ( $script, $options ) = @_;
    die "process fixture script must be a non-empty scalar\n"
      if !defined $script || ref($script) || $script eq '';
    die "process fixture options must be a hash reference\n"
      if defined $options && ref($options) ne 'HASH';
    return spawn(
        [ $^X, '-e', $script ],
        $options || {},
    );
}

sub _runtime_fixture_script {
    my ( $lib, $body ) = @_;
    die "runtime fixture library path must be a non-empty scalar\n"
      if !defined $lib || ref($lib) || $lib eq '';
    die "runtime fixture body must be a non-empty scalar\n"
      if !defined $body || ref($body) || $body eq '';
    return sprintf q{
        use lib q{%s};
        use Developer::Dashboard::PathRegistry;
        use Developer::Dashboard::FileRegistry;
        use Developer::Dashboard::RuntimeManager;
        my $paths = Developer::Dashboard::PathRegistry->new(home => $ENV{HOME});
        my $files = Developer::Dashboard::FileRegistry->new(paths => $paths);
        my $manager = bless { paths => $paths, files => $files }, 'Developer::Dashboard::RuntimeManager';
        %s
    }, $lib, $body;
}

sub _signal_child_script {
    return _runtime_fixture_script( $repo_lib, q{
        {
            package Local::SignalTestDaemon;
            sub new { bless { host => $_[1], port => $_[2] }, $_[0] }
            sub sockhost { $_[0]{host} }
            sub sockport { $_[0]{port} }
            package Local::SignalTestServer;
            sub new { my ($class, %args) = @_; bless \%args, $class }
            sub start_daemon { Local::SignalTestDaemon->new($_[0]{host}, $_[0]{port}) }
            sub serve_daemon { while (1) { select undef, undef, undef, 0.1 } }
        }
        my $signal_manager = Developer::Dashboard::RuntimeManager->new(
            app_builder => sub { my (%args) = @_; Local::SignalTestServer->new(%args) },
            config => bless({}, 'Local::SignalTestConfig'),
            files => $files,
            paths => $paths,
            runner => bless({}, 'Local::SignalTestRunner'),
        );
        $signal_manager->_run_web_child(*STDOUT, '0.0.0.0', 7906, detach => 0, redirect => 0);
    } );
}

# _one_run($home, $wait_for_running)
# Spawns one signal child in a fresh home, sends TERM either the moment
# the startup line appears or once the 'running' state is visible, and
# reports what the parent reads afterwards.
# Input: fresh temp home and whether to wait for the running state.
# Output: hashref with startup_seen, wait_status, state_status (undef
# when web_state returns nothing) and state_dir entries.
sub _one_run {
    my ( $home, $wait_for_running ) = @_;
    diag "before - building manager for home $home";
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = File::Spec->catdir( $home, 'state' );
    my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
    my $files = Developer::Dashboard::FileRegistry->new( paths => $paths );
    my $manager = Developer::Dashboard::RuntimeManager->new(
        app_builder => sub { die "app builder should not run here\n" },
        config      => bless( {}, 'Local::SignalTestConfig' ),
        files       => $files,
        paths       => $paths,
        runner      => bless( {}, 'Local::SignalTestRunner' ),
    );
    diag 'after - manager built';
    my $startup_path = "$home/web-child-startup.txt";
    diag 'before - spawning the signal child';
    my $pid = _spawn_perl_fixture(
        _signal_child_script(),
        {
            env => {
                HOME                           => $home,
                DEVELOPER_DASHBOARD_STATE_ROOT => $ENV{DEVELOPER_DASHBOARD_STATE_ROOT},
            },
            stdout => $startup_path,
            stderr => "$home/web-child-startup.err",
        },
    );
    diag "after - spawned child pid=$pid";
    diag 'before - polling for the startup line';
    my $startup_line = '';
    for ( 1 .. 30 ) {
        if ( -f $startup_path ) {
            open my $fh, '<', $startup_path or die "Unable to read $startup_path: $!";
            $startup_line = <$fh> // '';
            close $fh or die "Unable to close $startup_path: $!";
            last if $startup_line ne '';
        }
        sleep 0.1;
    }
    diag "after - startup_line=[$startup_line]";
    my $startup_seen = $startup_line =~ /^ok\|/ ? 1 : 0;
    my $settled = 0;
    if ( $startup_seen && $wait_for_running ) {
        diag 'before - waiting for the running state to be visible';
        for ( 1 .. 100 ) {
            my $state = $manager->web_state;
            if ( ref($state) eq 'HASH' && ( $state->{status} || '' ) eq 'running' ) {
                $settled = 1;
                last;
            }
            sleep 0.1;
        }
        diag "after - settled=$settled";
    }
    diag 'before - sending TERM';
    my $term_ok = terminate_process( $pid, 'TERM' );
    diag "after - terminate_process returned $term_ok";
    diag 'before - waiting for the child';
    my $wait_status = wait_process($pid);
    diag "after - wait_process returned $wait_status";
    diag 'before - reading web_state after the kill';
    my $state = $manager->web_state;
    my $status = ref($state) eq 'HASH' ? $state->{status} : undef;
    diag 'after - web_state status=[' . ( defined $status ? $status : 'undef' ) . ']';
    my $state_file = $files->web_state;
    my $state_dir  = File::Spec->catdir( $home, 'state' );
    my @entries;
    if ( opendir my $dh, $state_dir ) {
        @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
    }
    diag "after - state file exists=" . ( -f $state_file ? 1 : 0 ) . " state dir entries=[" . join( ',', @entries ) . ']';
    return {
        startup_seen => $startup_seen,
        settled      => $settled,
        term_ok      => $term_ok,
        wait_status  => $wait_status,
        status       => $status,
        state_exists => -f $state_file ? 1 : 0,
        entries      => \@entries,
    };
}

plan tests => 5;

# Run 1: immediate TERM, exactly like the t/09 block. Repeat up to 5
# times; the race needs only one hit to prove it exists.
my @run1_status;
my $run1_hits = 0;
my $run1_seen = 0;
for my $attempt ( 1 .. 5 ) {
    diag "run 1 attempt $attempt: before - fresh home";
    my $home = tempdir( CLEANUP => 1 );
    my $r = _one_run( $home, 0 );
    diag "run 1 attempt $attempt: after - startup_seen=$r->{startup_seen} wait=$r->{wait_status} status=[" . ( defined $r->{status} ? $r->{status} : 'undef' ) . ']';
    next if !$r->{startup_seen};
    $run1_seen++;
    push @run1_status, $r->{status};
    if ( $IS_WINDOWS && !defined $r->{status} ) { $run1_hits++; last; }
    if ( !$IS_WINDOWS && defined $r->{status} && $r->{status} eq 'stopped' ) { $run1_hits++; last; }
}
diag "run 1: after - $run1_seen attempts with startup, $run1_hits hit the expected shape";
if ($IS_WINDOWS) {
    ok( $run1_hits > 0, 'run 1: immediate TERM leaves web_state missing on Windows (race reproduced)' );
}
else {
    ok( $run1_hits > 0, 'run 1: immediate TERM leaves web_state stopped on Unix (handler ran)' );
}

# Run 2: wait for the 'running' state before TERM.
diag 'run 2: before - fresh home';
my $home2 = tempdir( CLEANUP => 1 );
my $r2 = _one_run( $home2, 1 );
diag "run 2: after - startup_seen=$r2->{startup_seen} settled=$r2->{settled} wait=$r2->{wait_status} status=[" . ( defined $r2->{status} ? $r2->{status} : 'undef' ) . ']';
ok( $r2->{startup_seen}, 'run 2: child reported startup' );
ok( $r2->{settled}, 'run 2: the running state became visible before TERM' );
my $expected_wait = $IS_WINDOWS ? 143 : 0;
is( $r2->{wait_status}, $expected_wait, 'run 2: wait status follows the platform TERM shape' );
if ($IS_WINDOWS) {
    is( $r2->{status}, 'running', 'run 2: waiting for the state makes web_state running on Windows' );
}
else {
    is( $r2->{status}, 'stopped', 'run 2: waiting for the state still leaves web_state stopped on Unix' );
}

__END__

=head1 NAME

t/991-micro-t09-web-state-race.t - reproduce the build #236 t/09 test 93 failure

=head1 PURPOSE

Prove, by measurement, why the parent reads web_state undef on Windows
after TERM in t/09 test 93. The code reading says the race is in
_run_web_child: the startup message is written before _write_web_state,
and the parent sends TERM the moment it sees the startup line. On
Windows the state write runs two icacls spawns plus a rename, hundreds
of milliseconds, while the parent's poll delay is 0-100ms, so TERM
(TerminateProcess, instant) usually lands mid-write, the child dies,
the target state file never appears, and the parent reads undef
forever. On Unix the write is syscalls and the handler writes
'stopped' anyway. Run 1 repeats the immediate TERM and records whether
the state is missing; run 2 waits until the 'running' state is visible
before TERM and records whether the state then survives. If run 1
shows the missing state on Windows and run 2 shows 'running', the
mechanism is proven and the fix is test-only: wait for the 'running'
state before TERM in the t/09 block.

=head1 WHY IT EXISTS

Build #236 (t/09 solo at 5715de85) fixed test 92 but failed the
Windows leg at test 93: got undef, expected 'running'. Three legs
passed all 486 tests. Before any fix is attempted, the mechanism must
be proven: is the state write racing the parent's TERM, or does the
state go somewhere the parent never reads?

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/991-micro-t09-web-state-race.t)
on the loop branch, or locally with prove after make. Remove the file
in a cleanup commit when the t/09 fix is verified.

=head1 HOW TO USE

Commit it to windows/loop6-combined, push, then trigger a solo with
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined
t/991-micro-t09-web-state-race.t 1. Read the diag lines in the console:
per-attempt startup, wait status and web_state status for run 1, and
the settle flag and final status for run 2.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a diagnostic micro for
the t/09 test 93 failure in build #236, in the testing-v1 loop.

=head1 EXAMPLES

If the mechanism is as the code reading says, every leg passes with
diag lines like "run 1: immediate TERM leaves web_state missing" on
Windows (at least one attempt undef) and "run 2: the running state
became visible before TERM" plus a final status of 'running' on
Windows, 'stopped' on Unix. If run 1 never shows the missing state on
Windows, the race is rarer than the code reading suggests and the
investigation must look at the write path itself.

=cut
