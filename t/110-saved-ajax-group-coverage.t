#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use Capture::Tiny qw(capture);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(:sys_wait_h);

use lib 'lib';

use Developer::Dashboard::PageRuntime;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::Platform ();

plan skip_all => 'POSIX saved-Ajax process-group units do not run on Windows'
  if Developer::Dashboard::Platform::is_windows();

# Hermetic, isolated runtime: an empty HOME that is also the CWD so any layer
# discovery resolves under the throwaway directory and never the real home.
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";
my $paths   = Developer::Dashboard::PathRegistry->new( home => $home );
my $runtime = Developer::Dashboard::PageRuntime->new( paths => $paths );
isa_ok( $runtime, 'Developer::Dashboard::PageRuntime', 'hermetic page runtime constructs under the temp home' );

# Safety net: any fixture process that outlives a failed assertion is removed
# so a failing run never leaks a sleeping child behind the harness.
my @cleanup_pids;
END {
    for my $pid ( grep { defined $_ && $_ =~ /^\d+$/ && $_ > 0 } @cleanup_pids ) {
        kill 9, $pid if kill 0, $pid;
    }
}

# _fork_reaped_child()
# Forks a child that exits immediately and reaps it, returning a pid that is
# guaranteed dead so kill(0, $pid) fails deterministically.
# Input: none.
# Output: reaped child pid integer.
sub _fork_reaped_child {
    my $pid = fork();
    die "fork failed: $!" if !defined $pid;
    if ( !$pid ) { POSIX::_exit(0); }
    waitpid( $pid, 0 );
    return $pid;
}

# ---- _saved_ajax_launch_command: guard, Windows identity, POSIX wrapper ------
{
    eval { $runtime->_saved_ajax_launch_command(); 1 };
    like( $@, qr/Missing saved ajax command/, '_saved_ajax_launch_command dies without an argv' );

    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is_deeply(
            [ $runtime->_saved_ajax_launch_command( 'cmd.exe', '/c', 'echo hi' ) ],
            [ 'cmd.exe', '/c', 'echo hi' ],
            '_saved_ajax_launch_command keeps the Windows argv unchanged',
        );
    }

    my @wrapped = $runtime->_saved_ajax_launch_command( 'echo', 'hi' );
    is( $wrapped[0], $^X, '_saved_ajax_launch_command wraps POSIX runs with the current perl' );
    is( $wrapped[1], '-MDeveloper::Dashboard::PageRuntime', '_saved_ajax_launch_command loads PageRuntime into the launcher' );
    is( $wrapped[2], '-e', '_saved_ajax_launch_command uses an inline launcher body' );
    like( $wrapped[3], qr/_exec_saved_ajax_command\(\@ARGV\)/, '_saved_ajax_launch_command routes through the process-group exec helper' );
    is_deeply( [ @wrapped[ 4 .. $#wrapped ] ], [ 'echo', 'hi' ], '_saved_ajax_launch_command preserves the original argv after the launcher' );
}

# ---- _own_saved_ajax_process_group: Windows zero, guard, POSIX identity ------
{
    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runtime->_own_saved_ajax_process_group(12345), 0, '_own_saved_ajax_process_group records no group on Windows' );
    }

    eval { $runtime->_own_saved_ajax_process_group(0); 1 };
    like( $@, qr/Missing saved ajax process id/, '_own_saved_ajax_process_group dies for a falsy pid' );

    is( $runtime->_own_saved_ajax_process_group($$), $$, '_own_saved_ajax_process_group mirrors the launcher pid as the group id' );
}

# ---- _exec_saved_ajax_command: guard, setpgid failure, exec failure ----------
{
    eval { Developer::Dashboard::PageRuntime->_exec_saved_ajax_command(); 1 };
    like( $@, qr/Missing saved ajax command/, '_exec_saved_ajax_command dies without a command' );

    {
        local $Developer::Dashboard::PageRuntime::SETPGID = sub { return };
        eval { Developer::Dashboard::PageRuntime->_exec_saved_ajax_command('/bin/true'); 1 };
        like( $@, qr/Unable to isolate saved ajax process/, '_exec_saved_ajax_command dies when process-group isolation fails' );
    }

    my $missing = File::Spec->catfile( $home, 'dd396-no-such-binary' );
    my $exec_error = '';
    {
        # Stub setpgid to success so the in-process call reaches exec without
        # detaching this test from the harness process group; capture swallows
        # perl's mandatory failed-exec warning so the run stays output-clean.
        local $Developer::Dashboard::PageRuntime::SETPGID = sub { return '0 but true' };
        capture {
            eval { Developer::Dashboard::PageRuntime->_exec_saved_ajax_command($missing); 1 };
            $exec_error = $@;
        };
    }
    like( $exec_error, qr/Unable to exec saved ajax command/, '_exec_saved_ajax_command dies when exec cannot start the command' );

    # The real injectable primitive: setpgid(0,0) succeeds in-process (it is a
    # no-op when this test is already its own group leader).
    ok( defined $Developer::Dashboard::PageRuntime::SETPGID->(), 'default SETPGID primitive isolates the calling process successfully' );
}

# ---- _terminate_saved_ajax_process: ownership-condition fallbacks ------------
{
    is( $runtime->_terminate_saved_ajax_process(0), 1, '_terminate_saved_ajax_process returns for a falsy pid' );

    my $dead = _fork_reaped_child();

    {
        local $Developer::Dashboard::Platform::OS_NAME = 'MSWin32';
        is( $runtime->_terminate_saved_ajax_process( $dead, $dead ), 1, '_terminate_saved_ajax_process ignores the recorded group on Windows' );
    }
    is( $runtime->_terminate_saved_ajax_process($dead), 1, '_terminate_saved_ajax_process falls back to direct-pid cleanup without a group' );
    is( $runtime->_terminate_saved_ajax_process( $dead, 'not-a-pid' ), 1, '_terminate_saved_ajax_process rejects a non-numeric group id' );
    is( $runtime->_terminate_saved_ajax_process( $dead, 0 ), 1, '_terminate_saved_ajax_process rejects the zero group recorded by Windows launches' );
    is( $runtime->_terminate_saved_ajax_process( $dead, $dead ), 1, '_terminate_saved_ajax_process completes for an owned group whose pid is already reaped' );
}

# ---- _terminate_saved_ajax_process: live owned group with a descendant -------
{
    my $marker = File::Spec->catfile( $home, "dd396-group-grandchild-$$.txt" );
    pipe my $ready_r, my $ready_w or die "pipe: $!";
    my $leader = fork();
    die "fork failed: $!" if !defined $leader;
    if ( !$leader ) {
        close $ready_r;
        POSIX::setpgid( 0, 0 ) or POSIX::_exit(97);
        my $grandchild = fork();
        POSIX::_exit(98) if !defined $grandchild;
        if ( !$grandchild ) {
            $SIG{TERM} = 'IGNORE';
            open my $marker_fh, '>', $marker or POSIX::_exit(91);
            print {$marker_fh} "$$\n";
            close $marker_fh or POSIX::_exit(92);
            select undef, undef, undef, 30;
            POSIX::_exit(0);
        }
        for ( 1 .. 200 ) {
            last if -s $marker;
            select undef, undef, undef, 0.02;
        }
        syswrite $ready_w, 'up';
        select undef, undef, undef, 30;
        POSIX::_exit(0);
    }
    push @cleanup_pids, $leader;
    close $ready_w;
    my $ready = '';
    sysread $ready_r, $ready, 2;
    close $ready_r;
    is( $ready, 'up', 'group fixture reports the leader ready after its grandchild started' );

    my $grandchild_pid;
    if ( open my $marker_fh, '<', $marker ) {
        my $line = <$marker_fh> // '';
        close $marker_fh;
        $line =~ s/\s+//g;
        $grandchild_pid = $line =~ /^\d+$/ ? $line + 0 : undef;
    }
    push @cleanup_pids, $grandchild_pid;
    ok( defined $grandchild_pid && kill( 0, $grandchild_pid ), 'group fixture grandchild is alive before termination' );

    is( $runtime->_terminate_saved_ajax_process( $leader, $leader ), 1, '_terminate_saved_ajax_process terminates a live owned process group' );
    waitpid( $leader, 0 );
    ok( !kill( 0, $leader ), '_terminate_saved_ajax_process leaves the group leader dead' );

    my $grandchild_gone = 0;
    for ( 1 .. 100 ) {
        if ( !kill 0, $grandchild_pid ) { $grandchild_gone = 1; last; }
        select undef, undef, undef, 0.05;
    }
    ok( $grandchild_gone, '_terminate_saved_ajax_process kills the TERM-ignoring descendant through the group signal' );
    unlink $marker if -e $marker;
}

done_testing;

__END__

=head1 NAME

110-saved-ajax-group-coverage.t - saved-Ajax POSIX process-group unit coverage

=head1 DESCRIPTION

This test drives every branch and condition of the saved-Ajax process-group
helpers in C<Developer::Dashboard::PageRuntime>: the launch-command wrapper,
the group-ownership recorder, the child-side exec launcher, and the
group-aware terminator, including the live owned-group path that must kill a
TERM-ignoring descendant.

=for comment FULL-POD-DOC START

=head1 PURPOSE

Give the DD-396 process-group cleanup code direct unit coverage on all four
Devel::Cover metrics, complementing the end-to-end disconnect acceptance test
with deterministic per-branch checks.

=head1 WHY IT EXISTS

The acceptance scenario only exercises the healthy POSIX path. The Windows
fallbacks, the argument guards, the setpgid failure path, and the
already-reaped-group path need direct calls with controlled inputs, and the
injectable C<$SETPGID> primitive needs both its stubbed and real forms driven.

=head1 WHEN TO USE

Run this test whenever the saved-Ajax launch wrapper, process-group ownership,
or termination escalation logic changes.

=head1 HOW TO USE

Run C<prove -lv t/110-saved-ajax-group-coverage.t> directly, or include it in
the repository-wide suite and coverage gates.

=head1 WHAT USES IT

Developers, the Perl test harness, and the all-metric coverage gate use this
file to hold the saved-Ajax lifecycle helpers at full coverage.

=head1 EXAMPLES

  prove -lv t/110-saved-ajax-group-coverage.t

Run the focused process-group unit checks.

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lv t/110-saved-ajax-group-coverage.t

Collect the per-branch coverage these units exist to provide.

=for comment FULL-POD-DOC END

=cut
