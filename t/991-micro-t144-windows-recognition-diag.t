#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes ();

use lib 'lib';
use lib 't/lib';
use Developer::Dashboard::Collector;
use Developer::Dashboard::CollectorRunner;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::IndicatorStore;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::GoRoutine ();

# Hermetic runtime, same shape as t/144: the temp home is also the
# working directory, so collector roots resolve from it.
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";

my $paths  = Developer::Dashboard::PathRegistry->new( home => $home, app_name => 'dashboard-test' );
my $runner = Developer::Dashboard::CollectorRunner->new(
    collectors => Developer::Dashboard::Collector->new( paths => $paths ),
    files      => Developer::Dashboard::FileRegistry->new( paths => $paths ),
    indicators => Developer::Dashboard::IndicatorStore->new( paths => $paths ),
    paths      => $paths,
);

# spawn_fixture_child($title_delay, $title[, $loop_name])
# Same stand-in as t/144: a perl -e child that sets $0 to the title and
# sleeps, with the loop name as a pre-exec environment marker.
sub spawn_fixture_child {
    my ( $title_delay, $title, $loop_name ) = @_;
    my $script = q{
        my ($delay, $process_title) = @ARGV;
        Time::HiRes::sleep($delay) if $delay;
        $0 = $process_title if length $process_title;
        Time::HiRes::sleep(30);
        exit 0;
    };
    return Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-MTime::HiRes', '-e', $script, $title_delay, ( defined $title ? $title : '' ) ],
        defined $loop_name ? { env => { DEVELOPER_DASHBOARD_LOOP_NAME => $loop_name } } : {},
    );
}

# write_bare_pidfile($name, $pid)
# A pidfile and nothing else, so no loop state exists to confirm identity.
sub write_bare_pidfile {
    my ( $name, $pid ) = @_;
    my $pidfile = $runner->_pidfile($name);
    open my $fh, '>', $pidfile or die "Unable to write $pidfile: $!";
    print {$fh} "$pid\n";
    close $fh or die "Unable to close $pidfile: $!";
    return $pidfile;
}

# reap_fixture_child($pid)
# Removes a fixture child unconditionally.
sub reap_fixture_child {
    my ($pid) = @_;
    Developer::Dashboard::GoRoutine::terminate_process( $pid, 'KILL' );
    Developer::Dashboard::GoRoutine::wait_process($pid);
    return 1;
}

# The exact t/144 titled fixture: title adopted at once, NAME marker in
# the spawn environ, bare pidfile, no loop state, no runtime identity.
my $titled  = spawn_fixture_child( 0, $runner->_process_title('fixture.titled'), 'fixture.titled' );
my $pidfile = write_bare_pidfile( 'fixture.titled', $titled );
ok( $titled > 0, 'titled fixture child spawned' );
ok( -f $pidfile, 'bare pidfile written for the titled fixture' );

# The fixture has no runtime identity, so the runtime gate must answer 0.
is( $runner->_loop_runtime_matches( $titled, 'fixture.titled' ), 0, 'titled fixture carries no runtime identity' );

# Probe _is_managed_loop repeatedly. Each call is its own test whose name
# carries the result and the title state the call saw, so the values are
# visible in the console on every leg. The calls are recorded, not
# asserted: the predicate's expected value is platform-dependent (on
# Linux the NAME marker is readable before $0 and the exact title after
# it, so it answers 1 throughout; on Windows the marker is unreadable
# and the title is the full CIM command line, so it should answer 0),
# and asserting a single value would fail the fast Linux legs first and
# let the fail-safe kill the slow Windows leg before it prints its
# values. The Windows column is the diagnostic: any 1 there shows the
# predicate flipping for the fixture t/144 test 8 waits on.
for my $i ( 1 .. 20 ) {
    my $managed = $runner->_is_managed_loop( $titled, 'fixture.titled' ) ? 1 : 0;
    my $title   = $runner->_read_process_title($titled);
    my $state   = !defined $title ? 'undef'
      : $title eq '' ? 'empty'
      : $title =~ /\bcollector-loop-foreground\b/ ? 'helper'
      : $title =~ /d2 collector: fixture\.titled/ ? 'len' . length($title) . '-has-title'
      : 'len' . length($title) . '-other';
    ok( 1, "call $i: is_managed_loop=$managed title=$state" );
}

# Cleanup: the fixture child must not survive the micro.
reap_fixture_child($titled);
ok( !kill( 0, $titled ), 'titled fixture child is gone after reap' );
unlink $pidfile;

done_testing;

__END__

=pod

=head1 NAME

t/991-micro-t144-windows-recognition-diag.t - diagnose why t/144 test 8 passes but test 9 fails on Windows

=head1 PURPOSE

t/144 fails on Windows (tests 9 and 10) at the tip and at the base, so it
is pre-existing, but test 8 flips: it failed at the base (solo 265) and
passed at the tip (solo 263), for the same fixture and the same code
path. This micro reproduces the t/144 titled fixture and probes
_is_managed_loop twenty times, recording the result and the title state
each call saw, to show whether the predicate is deterministic on
Windows or flips between calls.

=head1 WHY IT EXISTS

The t/144 titled fixture has no runtime identity, no loop state, an
unreadable NAME marker on Windows, and a title that is the full CIM
command line rather than the managed title, so _is_managed_loop should
answer 0 on every call. If it ever answers 1, the Windows fallback
applied, which only happens when the title read comes back undef or
empty - a flaky CIM query. That flip is the only mechanism that lets
t/144's 30-second wait_for_managed_loop poll succeed (test 8) while a
single running_loops probe fails (test 9) for the same child.

=head1 WHEN TO USE

Run it as a Jenkins solo while the t/144 Windows failure is being
adjudicated. Remove it in a cleanup commit once the verdict is recorded;
it is a diagnostic, not a permanent test.

=head1 HOW TO USE

No setup: the micro builds a temp home, spawns the titled fixture,
writes a bare pidfile, and probes _is_managed_loop twenty times. Each
probe is a test whose name carries the result and the title state, so
the values are visible in the solo console on every leg. The probes are
recorded, not asserted: the expected value is platform-dependent, and
asserting one value would fail the fast legs first and let the fail-safe
kill the slow Windows leg before it prints its values.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a diagnostic micro for the
t/144 Windows verdict in the testing-v1 loop, to be removed once the
verdict is recorded.

=head1 EXAMPLES

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/991-micro-t144-windows-recognition-diag.t 1

Solo the micro on Jenkins; a flip (any is_managed_loop=1) confirms the
Windows predicate is non-deterministic for this fixture, while twenty
zeros show it is deterministic and test 8's pass needs another
explanation.

=cut
