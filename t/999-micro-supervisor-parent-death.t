use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(getcwd);
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Developer::Dashboard::PathRegistry;
use Encode qw(decode encode);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo = getcwd();

my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

my $IS_WINDOWS = $^O eq 'MSWin32';

# The supervisor polls every 5 seconds by default, so the micro drives it
# fast: a 0.2 second poll and a 2 second parent-death grace. The grace
# variable is the one the fix introduces; without the fix it is inert,
# which is exactly what makes this micro red on the unfixed code: the
# supervisor never exits, whatever the grace says.
$ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_POLL_INTERVAL} = '0.2';
$ENV{DEVELOPER_DASHBOARD_COLLECTOR_SUPERVISOR_PARENT_GRACE_SECONDS} = '2';

# _run, _run_in_home and _find_free_port are copied verbatim from
# t/05-cli-smoke.t so the micro drives the CLI exactly the way the
# failing test does. _run_quiet is the same runner without the
# assertion, for diagnostics that must never trip the FAIL-SAFE
# watchdog themselves.
sub _run {
    my ( $cmd, $quiet ) = @_;
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => {} } );
    if ($quiet) {
        die "command failed ($exit_code): $cmd\n" if $exit_code != 0;
        return decode( 'UTF-8', $stdout . $stderr );
    }
    is( $exit_code, 0, "command succeeded: $cmd" );
    return decode( 'UTF-8', $stdout . $stderr );
}

sub _run_in_home {
    my ( $home, $cmd, $quiet ) = @_;
    die "home directory is required\n" if !defined $home || $home eq '';
    # Scope $HOME to the temp home, the suite's own pattern (t/05
    # localizes $ENV{HOME} to a tempdir): the child d2 must operate IN
    # the temp home, not in the caller's real home.
    local $ENV{HOME} = $home;
    return _run("cd '$home' && $cmd", $quiet);
}

sub _find_free_port {
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Unable to reserve a free local TCP port: $!";
    my $port = $socket->sockport();
    close $socket or die "Unable to release reserved local TCP port $port: $!";
    return $port;
}

# _read_json_file($path)
# Reads one JSON file, returning undef when it is missing or unparsable.
sub _read_json_file {
    my ($path) = @_;
    return if !defined $path || !-f $path;
    open my $fh, '<:raw', $path or return;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { json_decode($raw) };
    return if $@ || !defined $data;
    return $data;
}

# _slurp_file($path)
# Reads one text file, returning undef when it is missing.
sub _slurp_file {
    my ($path) = @_;
    return if !defined $path || !-f $path;
    open my $fh, '<', $path or return;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $raw;
}

# _wait_for_file($path, $timeout)
# Polls until a file exists, returning true when it appears.
sub _wait_for_file {
    my ( $path, $timeout ) = @_;
    my $deadline = time + $timeout;
    while ( time < $deadline ) {
        return 1 if -f $path;
        sleep 0.5;
    }
    return -f $path ? 1 : 0;
}

# _pid_is_alive($pid)
# Returns true when kill 0 reaches the pid.
sub _pid_is_alive {
    my ($pid) = @_;
    return 0 if !defined $pid || $pid !~ /\A\d+\z/ || $pid < 1;
    return kill( 0, $pid ) ? 1 : 0;
}

# _kill_pid($pid)
# TERM then KILL by exact pid only, waiting for the process to go away.
# Never touches a process group: the point of this micro is the
# supervisor's own lifecycle, so only an exact pid kill may clean up
# what the micro itself started.
sub _kill_pid {
    my ($pid) = @_;
    return 1 if !_pid_is_alive($pid);
    kill 'TERM', $pid;
    for ( 1 .. 50 ) {
        return 1 if !_pid_is_alive($pid);
        sleep 0.1;
    }
    kill 'KILL', $pid;
    for ( 1 .. 50 ) {
        return 1 if !_pid_is_alive($pid);
        sleep 0.1;
    }
    return _pid_is_alive($pid) ? 0 : 1;
}

# _wait_for_pid_gone($pid, $timeout)
# Polls until a pid goes away, diagging every 2 seconds so the
# FAIL-SAFE watchdog never sees a silent test. Returns true when the
# pid is gone before the deadline.
sub _wait_for_pid_gone {
    my ( $pid, $timeout ) = @_;
    return 1 if !_pid_is_alive($pid);
    my $start     = time;
    my $last_diag = 0;
    while ( time - $start < $timeout ) {
        return 1 if !_pid_is_alive($pid);
        if ( time - $last_diag >= 2 ) {
            diag( sprintf 'micro: waiting for pid %d to exit, %.1fs elapsed', $pid, time - $start );
            $last_diag = time;
        }
        sleep 0.5;
    }
    return _pid_is_alive($pid) ? 0 : 1;
}

# _serve_home($home, $collector_name)
# Inits one temp home, writes a one-collector config, and starts serve.
# Returns the decoded serve JSON (with the web pid). Copied from the
# t/995 orphan investigator micro.
sub _serve_home {
    my ( $home, $collector_name ) = @_;
    _run_in_home( $home, "$perl -I'$lib' '$dashboard' init" );
    my $config_file = File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' );
    # Belt and braces (t/05 line 190 does the same): init is expected
    # to create this directory, but the open must not die with ENOENT
    # if a platform's init does not.
    make_path( File::Spec->catdir( $home, '.developer-dashboard', 'config' ) );
    open my $fh, '>:raw', $config_file or die "Unable to write $config_file: $!";
    my $config_json = json_encode(
        {
            collectors => [
                {
                    name     => $collector_name,
                    command  => q{perl -MTime::HiRes=time -e 'printf qq{%.6f\n}, time'},
                    cwd      => 'home',
                    interval => 1,
                },
            ],
        }
    );
    $config_json = encode( 'UTF-8', $config_json ) if utf8::is_utf8($config_json);
    print {$fh} $config_json;
    close $fh;
    my $port = _find_free_port();
    my $serve_json = json_decode( _run_in_home( $home, "$perl -I'$lib' '$dashboard' serve --host 127.0.0.1 --port $port" ) );
    ok( $serve_json->{pid}, "micro: d2 serve returns a managed web pid in $home" );
    return $serve_json;
}

# _state_root_for_home($home)
# Returns the hashed temp-state root for one runtime home, through the
# product's own PathRegistry, so the micro reads exactly the directory
# the supervisor writes its pidfile and state into.
sub _state_root_for_home {
    my ($home) = @_;
    my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
    return $paths->state_root;
}

# _collect_managed_pids($state_root)
# Reads every pid the runtime tracks in one state root: the supervisor
# pidfile plus every collector loop pidfile. Returns a hash reference
# of label => pid.
sub _collect_managed_pids {
    my ($state_root) = @_;
    my %pids;
    my $sup_pidfile = File::Spec->catfile( $state_root, 'collector-supervisor.pid' );
    if ( my $raw = _slurp_file($sup_pidfile) ) {
        chomp $raw;
        $pids{supervisor} = $raw + 0 if $raw =~ /\A\d+\z/;
    }
    my $collectors_root = File::Spec->catdir( $state_root, 'collectors' );
    if ( -d $collectors_root ) {
        opendir my $dh, $collectors_root or die "Unable to read $collectors_root: $!";
        while ( my $entry = readdir $dh ) {
            my ($loop_name) = $entry =~ /^(.*)\.pid\z/;
            next if !defined $loop_name;
            my $raw = _slurp_file( File::Spec->catfile( $collectors_root, $entry ) );
            next if !defined $raw;
            chomp $raw;
            # NOTE: capture the name above first. `$1` after the
            # `if $raw =~ ...` modifier would be the modifier match's
            # (empty) captures, not the entry's name.
            $pids{"loop:$loop_name"} = $raw + 0 if $raw =~ /\A\d+\z/;
        }
        closedir $dh;
    }
    return \%pids;
}

my $home       = tempdir( CLEANUP => 0 );
my $serve_json = _serve_home( $home, 'micro-tick' );
my $web_pid    = $serve_json->{pid};
my $state_root = _state_root_for_home($home);
my $sup_pidfile = File::Spec->catfile( $state_root, 'collector-supervisor.pid' );

ok( _wait_for_file( $sup_pidfile, 60 ), 'micro: supervisor pidfile appears after serve' );
my $pids     = _collect_managed_pids($state_root);
my $sup_pid  = $pids->{supervisor};
my $loop_pid = $pids->{'loop:micro-tick'};
ok( defined $sup_pid,  'micro: supervisor pid recorded' );
ok( _pid_is_alive($sup_pid),  'micro: supervisor alive after serve' );
ok( defined $loop_pid, 'micro: micro-tick loop pid recorded' );
ok( _pid_is_alive($loop_pid), 'micro: micro-tick loop alive after serve' );
ok( _pid_is_alive($web_pid),  'micro: web pid alive after serve' );

# CONTROL (parent alive keeps running): the web stays alive for 5
# seconds, longer than the 2 second grace, and the supervisor must
# still be alive at the end of it. Without this control a fix that
# kills the supervisor unconditionally would pass the death half.
sleep 5;
ok( _pid_is_alive($sup_pid), 'micro: supervisor still alive while its serve parent lives' );

# Kill the serve parent by exact pid (the web), then the supervisor
# must exit on its own within 60 seconds, and take its watched loop
# with it. The micro never kills the supervisor or the loop itself:
# if they survive, they are the evidence, left alive and diagged.
ok( _kill_pid($web_pid), 'micro: web pid killed' );
ok( _wait_for_pid_gone( $sup_pid, 60 ),  'micro: supervisor exits after its serve parent dies' );
ok( _wait_for_pid_gone( $loop_pid, 60 ), 'micro: watched loop exits with the supervisor' );
ok( !-f $sup_pidfile, 'micro: supervisor pidfile removed on exit' );

if ( _pid_is_alive($sup_pid) || _pid_is_alive($loop_pid) ) {
    my @evidence;
    push @evidence, "supervisor:$sup_pid" if _pid_is_alive($sup_pid);
    push @evidence, "loop:$loop_pid"     if _pid_is_alive($loop_pid);
    diag( 'micro: EVIDENCE left running - state root ' . $state_root . ' pids ' . join( ' ', @evidence ) );
}
remove_tree($home);

done_testing();

__END__

=head1 NAME

t/999-micro-supervisor-parent-death.t - reproduce the collector supervisor surviving its serve parent's death

=head1 PURPOSE

Prove that the collector supervisor exits on its own, taking its
watched loops with it, once the serve (web) process it belongs to has
died. The supervisor detaches into its own session, so a fail-fast
group kill cannot reach it, and it has no parent-death detection: its
only self-exit is an empty target set, which nothing ever writes. This
micro kills the web by exact pid and watches the supervisor go away by
itself. It never kills the supervisor or the loop: if they survive,
they are the evidence, left alive and diagged, per the standing rule.

=head1 WHY IT EXISTS

The orphan investigation (19 Nov 2026) proved the supervisor survives
a fail-fast kill and is then adopted by fresh runs, so orphaned
supervisors and loops accumulate until a timing test breaks (round 25
failed on ARM64 t/05 test 360 with 19 orphaned supervisors on the Pi).
Fix C scoped loop adoption to the current runtime; fix A is the other
half, the supervisor exiting when its serve parent dies. This micro is
the red test for fix A: it fails on the unfixed code (the supervisor
never exits) and passes once the fix is in.

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/999-micro-supervisor-parent-death.t)
while fix A is being developed. It is a micro, not a permanent suite
test: remove it from the branch in a cleanup commit when the
investigation ends. Never run it by hand against a live home: it starts
a real serve in a throwaway home and kills the web it started.

=head1 HOW TO USE

No setup: the test builds its own throwaway home, starts serve with one
micro-tick collector, and drives the whole lifecycle through the CLI.
It sets a 0.2 second supervisor poll and a 2 second parent-death grace
through the environment so the verdict arrives in seconds instead of
minutes. Fourteen assertions: the init and serve commands succeed,
serve returns a web pid, the supervisor pidfile appears, the supervisor
and loop pids are recorded and alive, the web is alive, the supervisor
is still alive after 5 seconds with the web alive (the control), the
web is killed, the supervisor exits within 60 seconds, the loop exits
with it, and the supervisor pidfile is removed on exit.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a throwaway micro for the
fix A investigation, in the testing-v1 loop. The fail-fast and fail-safe
in the Jenkins job terminate the run when it fails; no separate monitor
watches for orphans.

=head1 EXAMPLES

On the unfixed code the test fails on the supervisor-exit assertion:
the supervisor is still alive 60 seconds after the web died, and the
diag line records the evidence pids and state root. On the fixed code
it passes with fourteen assertions: the supervisor exits about 2 seconds
after the web dies and stops its watched loop on the way out.

=cut
