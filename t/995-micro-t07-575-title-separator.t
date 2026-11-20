use strict;
use warnings;
use utf8;

use IPC::Open3 qw(open3);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Developer::Dashboard::CollectorRunner;

plan tests => 12;

# Micro-probe for round 38, Jenkins build #358: t/07-core-units.t test 575
# ('_read_process_title falls back to ps output when proc cmdline is
# unavailable', t/07 line 4174) failed ONLY on the Windows leg of the full
# run, while the same test passed in solo #341 (t/07 862/862 on all legs).
# The failing diagnostic was, verbatim:
#   '"C:\Strawberry\perl\bin\perl.exe" t\07-core-units.t'
#   doesn't match '(?^:t\/07-core-units\.t|prove)'
# The job passes the solo file literally (target = TEST_FILE), but the full
# run passes 't/' and prove enumerates the directory, so the spawned perl's
# command line carries the path exactly as prove handed it over: forward
# slashes in a solo, backslashes from directory enumeration on Windows.
# This micro proves that chain without fixing anything: it reads the real
# _read_process_title fallback output in both shapes and checks the exact
# t/07 regex against each, with the titles printed verbatim.

my $runner = bless {}, 'Developer::Dashboard::CollectorRunner';

# The exact regex from t/07 line 4174, copied verbatim.
my $t07_regex = qr/t\/07-core-units\.t|prove/;

# The exact round-38 failing title, and its forward-slash twin.
my $title_backslash = q{"C:\Strawberry\perl\bin\perl.exe" t\07-core-units.t};
my $title_forward   = q{"C:\Strawberry\perl\bin\perl.exe" t/07-core-units.t};

diag 'HEARTBEAT: phase A starting - own title, stubbed proc file (exact t/07 shape)';

my $stubbed_title;
{
    no warnings 'redefine';
    local *Developer::Dashboard::CollectorRunner::_read_proc_file = sub { return };
    $stubbed_title = $runner->_read_process_title($$);
}
diag "PHASE A stubbed own title: [$stubbed_title]" if defined $stubbed_title;
ok( defined $stubbed_title && $stubbed_title ne '', 'phase A: stubbed _read_process_title returns a non-empty title' );
like(
    $stubbed_title,
    qr{t[/\\]995-micro-t07-575-title-separator\.t},
    'phase A: stubbed title names this micro file',
);
diag "PHASE A stubbed title matches t/07 regex: "
  . ( ( defined $stubbed_title && $stubbed_title =~ $t07_regex ) ? 'yes' : 'no' );
diag "PHASE A stubbed title contains prove: "
  . ( ( defined $stubbed_title && $stubbed_title =~ /prove/ ) ? 'yes' : 'no' );

diag 'HEARTBEAT: phase A2 starting - literal titles against the t/07 regex';
diag "PHASE A2 forward-slash literal: [$title_forward]";
diag "PHASE A2 backslash literal: [$title_backslash]";
ok( $title_forward =~ $t07_regex, 'phase A2: forward-slash title matches the t/07 regex' );
ok( $title_backslash !~ $t07_regex, 'phase A2: backslash title does NOT match the t/07 regex' );
ok(
    $title_forward !~ /prove/ && $title_backslash !~ /prove/,
    'phase A2: neither literal title contains prove',
);

diag 'HEARTBEAT: phase A3 starting - own title, unstubbed (real proc/ps/CIM path)';
my $plain_title = $runner->_read_process_title($$);
diag "PHASE A3 unstubbed own title: [$plain_title]" if defined $plain_title;
ok( defined $plain_title && $plain_title ne '', 'phase A3: unstubbed _read_process_title returns a non-empty title' );
like(
    $plain_title,
    qr{t[/\\]995-micro-t07-575-title-separator\.t},
    'phase A3: unstubbed title names this micro file',
);

diag 'HEARTBEAT: phase B starting - spawned children, verbatim token echo';

# Spawn a child perl that sleeps, carrying a t/07-style path token as a
# plain argument, then read its title through the real fallback. The token
# is never executed (the -e script ignores @ARGV); it only rides in the
# command line, exactly as prove's file argument rides in a test child's.
sub _spawn_and_read_title {
    my ($token) = @_;
    my $pid = open3( my $in, my $out, my $err, $^X, '-e', 'sleep 30', $token );
    close $in;
    my $title;
    for my $attempt ( 1 .. 10 ) {
        $title = $runner->_read_process_title($pid);
        last if defined $title && $title =~ /\Q$token\E/;
        sleep 0.2;
    }
    kill 9, $pid;
    waitpid( $pid, 0 );
    close $out;
    close $err;
    return $title;
}

my $child_forward_title = _spawn_and_read_title('t/07-core-units.t');
diag "PHASE B forward-slash child title: [$child_forward_title]" if defined $child_forward_title;
ok(
    defined $child_forward_title && $child_forward_title =~ m{t/07-core-units\.t},
    'phase B: forward-slash child title carries the token verbatim',
);

my $child_backslash_title = _spawn_and_read_title('t\07-core-units.t');
diag "PHASE B backslash child title: [$child_backslash_title]" if defined $child_backslash_title;
ok(
    defined $child_backslash_title && $child_backslash_title =~ m{t\\07-core-units\.t},
    'phase B: backslash child title carries the token verbatim',
);
ok(
    defined $child_backslash_title && $child_backslash_title !~ $t07_regex,
    'phase B: backslash child title does NOT match the t/07 regex (round-38 shape)',
);
ok(
    defined $child_forward_title && $child_forward_title =~ $t07_regex,
    'phase B: forward-slash child title DOES match the t/07 regex (solo shape)',
);
ok(
    ( defined $child_forward_title && $child_forward_title !~ /prove/ )
      && ( defined $child_backslash_title && $child_backslash_title !~ /prove/ ),
    'phase B: neither child title contains prove',
);

diag 'HEARTBEAT: probe done - all evidence collected';

=head1 NAME

995-micro-t07-575-title-separator.t - micro-probe for the round-38 Windows t/07 test 575 failure

=head1 DESCRIPTION

This micro proves the mechanism behind the round-38 failure of t/07 test 575
('_read_process_title falls back to ps output when proc cmdline is
unavailable'). In the full run the Windows fallback title is
'"C:\Strawberry\perl\bin\perl.exe" t\07-core-units.t', which cannot match the
test's Unix-shaped regex, while in a solo the same test passes because prove
is handed the file literally with forward slashes. It reads the real fallback
output in both shapes and checks the exact t/07 regex against each.

=for comment FULL-POD-DOC START

=head1 PURPOSE

This micro is the executable evidence for the t/07 test 575 mechanism. Read
it when you need to know whether the failure is a test-side regex shape, a
product-side title shape, or a harness invocation difference, instead of
guessing from the one-line diagnostic.

=head1 WHY IT EXISTS

It exists because the failure is new (the test passed in solo #341) and the
difference between a solo and a full run is the one variable that changed:
the job passes the solo file literally, while the full run passes 't/' and
prove enumerates the directory. A micro that reproduces both title shapes on
all four legs settles which side of that difference the fix belongs on.

=head1 WHEN TO USE

Use this file while deciding the t/07 test 575 fix, and delete it in the
cleanup commit once the fix is solo-verified, like every other probe micro.

=head1 HOW TO USE

Run it as a Jenkins solo with TEST_FILE=t/995-micro-t07-575-title-separator.t,
then read the verbatim titles in the console output. Do not run it by hand
outside Jenkins.

=head1 WHAT USES IT

The loop owner uses it to choose between a test-side regex fix and a
product-side title normalisation for t/07 test 575. Nothing else uses it.

=head1 EXAMPLES

Example 1:

  python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined t/995-micro-t07-575-title-separator.t 1

Trigger the probe solo and read the titles it prints per leg.

Example 2:

  grep -n "PHASE B" ~/workspace/goals/developer-dashboard-pr-73-windows-support/hidden_files/jenkins-build-<n>-console.txt

Read the spawned-child titles per leg from the saved console.

=for comment FULL-POD-DOC END

=cut
