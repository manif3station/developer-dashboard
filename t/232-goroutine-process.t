use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use Developer::Dashboard::GoRoutine ();

ok defined(&Developer::Dashboard::GoRoutine::spawn),
  'GoRoutine exports a native process spawn operation';
if ( !defined &Developer::Dashboard::GoRoutine::spawn ) {
    done_testing();
    exit 0;
}
ok defined(&Developer::Dashboard::GoRoutine::process_exited),
  'GoRoutine exposes non-reaping child completion inspection';
my $invalid_process = eval { Developer::Dashboard::GoRoutine::process_exited(0); 1 };
ok( !$invalid_process, 'process_exited rejects the reserved zero process id' );
like( $@, qr/invalid GoRoutine child process identifier/, 'invalid process id failure is explicit' );

my $dir = tempdir( CLEANUP => 1 );
my $stdout = File::Spec->catfile( $dir, 'stdout.txt' );
my $stderr = File::Spec->catfile( $dir, 'stderr.txt' );
my $child = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'select undef, undef, undef, 0.2; print "child-output\n"; exit 7;' ],
    { cwd => $dir, stdout => $stdout, stderr => $stderr },
);
ok defined($child) && $child > 0, 'spawn returns a positive process identifier';
is( Developer::Dashboard::GoRoutine::process_running($child), 1,
  'new child is reported as running' );
is( Developer::Dashboard::GoRoutine::wait_process($child), 7,
  'wait_process returns the child non-zero exit status' );
is( Developer::Dashboard::GoRoutine::process_running($child), 0,
  'reaped child is reported as not running' );
open my $out, '<', $stdout or die "Unable to read child stdout '$stdout': $!";
is( scalar(<$out>), "child-output\n", 'child stdout is redirected to the requested file' );
close $out or die "Unable to close child stdout file '$stdout': $!";

my $completed_child = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'exit 9;' ],
    { cwd => $dir, stdout => $stdout, stderr => $stderr },
);
my $completed_deadline = time() + 2;
while ( !Developer::Dashboard::GoRoutine::process_exited($completed_child)
    && time() < $completed_deadline )
{
    select undef, undef, undef, 0.01;
}
ok( Developer::Dashboard::GoRoutine::process_exited($completed_child),
  'process_exited observes a completed child without reaping it' );
is( Developer::Dashboard::GoRoutine::process_running($completed_child), 1,
  'completed unreaped child retains process existence until wait_process' );
is( Developer::Dashboard::GoRoutine::wait_process($completed_child), 9,
  'completed child remains available for wait_process after liveness inspection' );

my $env_output = File::Spec->catfile( $dir, 'environment.txt' );
{
    local $ENV{DASHBOARD_GOROUTINE_INHERITED_VALUE} = 'inherited-value';
    my $env_child = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-e', 'print join q{|}, @ENV{qw(DASHBOARD_GOROUTINE_INHERITED_VALUE DASHBOARD_GOROUTINE_CHILD_VALUE)};' ],
        {
            cwd    => $dir,
            stdout => $env_output,
            stderr => $stderr,
            env    => { DASHBOARD_GOROUTINE_CHILD_VALUE => 'explicit-child-value' },
        },
    );
    is( Developer::Dashboard::GoRoutine::wait_process($env_child), 0,
      'environment override child exits successfully' );
}
open my $env_fh, '<', $env_output
  or die "Unable to read child environment output '$env_output': $!";
is( scalar(<$env_fh>), 'inherited-value|explicit-child-value',
  'spawn inherits the environment and merges explicit child overrides' );
close $env_fh or die "Unable to close child environment output '$env_output': $!";

my $stdin_path = File::Spec->catfile( $dir, 'stdin.txt' );
open my $stdin_fh, '>', $stdin_path
  or die "Unable to create child stdin fixture '$stdin_path': $!";
print {$stdin_fh} "provided-on-stdin\n"
  or die "Unable to write child stdin fixture '$stdin_path': $!";
close $stdin_fh or die "Unable to close child stdin fixture '$stdin_path': $!";
my $stdin_output = File::Spec->catfile( $dir, 'stdin-output.txt' );
my $stdin_child = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'print scalar <STDIN>;' ],
    { cwd => $dir, stdin => $stdin_path, stdout => $stdin_output, stderr => $stderr },
);
is( Developer::Dashboard::GoRoutine::wait_process($stdin_child), 0,
  'stdin child exits successfully' );
open my $stdin_result_fh, '<', $stdin_output
  or die "Unable to read child stdin result '$stdin_output': $!";
is( scalar(<$stdin_result_fh>), "provided-on-stdin\n",
  'spawn redirects the requested standard input' );
close $stdin_result_fh or die "Unable to close child stdin result '$stdin_output': $!";

my $argv_output = File::Spec->catfile( $dir, 'argv.txt' );
my $argv_child = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'print join q{|}, @ARGV;', 'literal;not-shell', '$(no-shell)' ],
    { cwd => $dir, stdout => $argv_output, stderr => $stderr },
);
is( Developer::Dashboard::GoRoutine::wait_process($argv_child), 0,
  'literal argv child exits successfully' );
open my $argv_fh, '<', $argv_output
  or die "Unable to read child argv output '$argv_output': $!";
is( scalar(<$argv_fh>), 'literal;not-shell|$(no-shell)',
  'spawn passes arguments literally without shell evaluation' );
close $argv_fh or die "Unable to close child argv output '$argv_output': $!";

SKIP: {
    skip 'process-group assertion uses POSIX getpgrp', 2 if $^O eq 'MSWin32';
    my $group_output = File::Spec->catfile( $dir, 'process-group.txt' );
    my $group_child = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-MPOSIX', '-e', 'print POSIX::getpgrp();' ],
        { cwd => $dir, stdout => $group_output, stderr => $stderr, process_group => 1 },
    );
    is( Developer::Dashboard::GoRoutine::wait_process($group_child), 0,
      'process-group child exits successfully' );
    open my $group_fh, '<', $group_output
      or die "Unable to read child process group '$group_output': $!";
    is( scalar(<$group_fh>), "$group_child",
      'requested child process group is independently addressable by its process id' );
    close $group_fh or die "Unable to close child process group file '$group_output': $!";
}

my $long_child = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'sleep 30;' ],
    { cwd => $dir, stdout => $stdout, stderr => $stderr },
);
ok( !Developer::Dashboard::GoRoutine::process_exited($long_child),
  'process_exited leaves a running child available for later wait' );
ok( Developer::Dashboard::GoRoutine::terminate_process( $long_child, 'TERM' ),
  'terminate_process signals a running child' );
my $exit_deadline = time() + 2;
while ( !Developer::Dashboard::GoRoutine::process_exited($long_child) && time() < $exit_deadline ) {
    select undef, undef, undef, 0.01;
}
ok( Developer::Dashboard::GoRoutine::process_exited($long_child),
  'process_exited observes termination without reaping the child' );
my $terminated = Developer::Dashboard::GoRoutine::wait_process($long_child);
ok( $terminated >= 128, 'terminated child returns a signal-derived exit status' );

SKIP: {
    skip 'named POSIX signal handling is unavailable on Windows', 4 if $^O eq 'MSWin32';
    for my $signal_name (qw(HUP INT)) {
        my $signal_child = Developer::Dashboard::GoRoutine::spawn(
            [ $^X, '-e', "\$SIG{$signal_name} = sub { exit 0 }; sleep 30;" ],
            { cwd => $dir, stdout => $stdout, stderr => $stderr },
        );
        select undef, undef, undef, 0.05;
        ok( Developer::Dashboard::GoRoutine::terminate_process( $signal_child, $signal_name ),
            "terminate_process sends $signal_name to a running child" );
        is( Developer::Dashboard::GoRoutine::wait_process($signal_child), 0,
            "child handles $signal_name and exits cleanly" );
    }
}

done_testing;

__END__

=head1 NAME

232-goroutine-process.t - verify process spawning managed by GoRoutine XS

=head1 DESCRIPTION

This test specifies the process-lifecycle API required to remove direct Perl
C<fork> calls without replacing operating-system processes with threads.
GoRoutine workers provide asynchronous Perl callbacks; this module's native
spawn operations provide external process identifiers, wait status, signals,
working directory and redirected output.

=head1 PURPOSE

The existing runtime needs detached and supervised OS processes for background
commands, collectors and the web backend. A native thread alone does not
provide process identity or survive the parent process exiting. These tests
ensure the GoRoutine distribution-owned XS API can launch and supervise a
real child before production process call sites are migrated.

=head1 WHY IT EXISTS

Thread callbacks cannot replace process IDs, independent process lifetimes, or
operating-system exit and signal status. This test establishes those native
process primitives before the runtime switches its existing launch sites.

=head1 WHEN TO USE

Run this test after building the shared Dashboard XS extension in the dev
Docker container. It is a contract test for spawn, PID reporting, process
status, exit results, signal termination, working directory and standard
output redirection.

=head1 HOW TO USE

Build the shared XS extension in Docker, then run this test using the checkout's
library paths:

  d2 docker compose exec dev make
  d2 docker compose exec dev prove -blv t/232-goroutine-process.t

The test launches Perl children that verify redirected stdin/stdout, literal
argument handling, inherited and overridden environment, process-group
creation, explicit exit status, liveness, non-reaping completion inspection,
termination, and reaping. All scratch
files are created under a temporary directory and removed by C<File::Temp>
after the test. POSIX HUP and INT delivery is also covered; Windows uses its
supported process-termination semantics.

=head1 WHAT USES IT

The distribution test harness runs this contract alongside the remaining
production-call-site migration. Runtime modules use the API only where its
operating-system process contract matches the required behavior.

=head1 EXAMPLES

  my $pid = Developer::Dashboard::GoRoutine::spawn(
      [ $^X, '-e', 'print "finished\n"' ],
      { stdout => '/tmp/child.log', stderr => '/tmp/child.err' },
  );
  my $status = Developer::Dashboard::GoRoutine::wait_process($pid);

=cut
