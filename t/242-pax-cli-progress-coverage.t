use strict;
use warnings;

use Test::More;
use lib 'lib';
use Developer::Dashboard::Pax::CLI::Progress;

my $output = '';
open my $stream, '>', \$output or die "Unable to open scalar output: $!";

my $progress = Developer::Dashboard::Pax::CLI::Progress->new(
    tasks => [
        { id => 'resolve', label => 'Resolve inputs' },
        { id => 'compile' },
    ],
    stream => $stream,
);
is( $progress->{title}, 'pax progress', 'new supplies the default title' );
is( $progress->{tasks}{compile}{label}, 'compile', 'new uses the task id when its label is false' );
like( $output, qr/^pax progress\n\[ \] Resolve inputs\n\[ \] compile\n\z/, 'new renders pending tasks in their declared order' );
ok( $progress->finish, 'finish is a no-op success for a static board' );
$output = '';
close $stream or die "Unable to close scalar output: $!";
open $stream, '>', \$output or die "Unable to reopen scalar output: $!";

my $invalid_error = eval { Developer::Dashboard::Pax::CLI::Progress->new( tasks => {} ); 1 } ? '' : $@;
like( $invalid_error, qr/Progress tasks must be an array reference/, 'new rejects a non-array task list' );
my $missing_id_error = eval { Developer::Dashboard::Pax::CLI::Progress->new( tasks => [ {} ] ); 1 } ? '' : $@;
like( $missing_id_error, qr/Progress task missing id/, 'new rejects a task without an id' );
my $false_labels = Developer::Dashboard::Pax::CLI::Progress->new(
    tasks => [
        { id => 'empty-label', label => '' },
        { id => 'zero-label',  label => '0' },
    ],
    stream => $stream,
);
is( $false_labels->{tasks}{'empty-label'}{label}, 'empty-label', 'new falls back to the task id for an empty label' );
is( $false_labels->{tasks}{'zero-label'}{label}, 'zero-label', 'new preserves false-string label fallback behavior for zero' );
my $default_output = '';
{
    local *STDERR;
    open STDERR, '>', \$default_output or die "Unable to open captured STDERR: $!";
    my $empty = Developer::Dashboard::Pax::CLI::Progress->new;
    is_deeply( $empty->{order}, [], 'new defaults to an empty task list' );
    is( $empty->{stream}, \*STDERR, 'new defaults its output stream to STDERR' );
}
like( $default_output, qr/^pax progress\n\z/, 'new writes its default board title to STDERR' );

my $dynamic = Developer::Dashboard::Pax::CLI::Progress->new(
    title   => 'Build',
    tasks   => [ { id => 'unit', label => 'Compile unit' } ],
    stream  => $stream,
    dynamic => 1,
    color   => 1,
);
my $callback = $dynamic->callback;
ok( ref($callback) eq 'CODE', 'callback returns a callable update handler' );
ok( $callback->({}), 'callback ignores events with no task id' );
ok( $dynamic->update(), 'update ignores a missing event' );
ok( $dynamic->update([]), 'update ignores a non-hash event' );
ok( $dynamic->update({ status => 'done' }), 'update ignores an event without a task id' );
ok( $dynamic->update({ task_id => 'unknown', status => 'done' }), 'update ignores an unknown task id' );
ok( $dynamic->update({ task_id => 'unit' }), 'update preserves a known task when optional status and label are absent' );
ok( $dynamic->update({ task_id => 'unit', status => 'running', label => 'Compiling' }), 'update applies a running status and label' );
like( $output, qr/\e\[33m->\e\[0m Compiling/, 'render colorizes the running status and redraws a dynamic board' );
ok( $dynamic->update({ task_id => 'unit', status => '', label => '' }), 'update accepts empty optional values without replacing existing task data' );
like( $dynamic->render_text, qr/\e\[33m->\e\[0m Compiling/, 'render_text retains status and label when update values are empty' );
ok( $dynamic->update({ task_id => 'unit', status => 'done' }), 'update transitions the task to done' );
like( $output, qr/\e\[32m\[OK\]\e\[0m Compiling/, 'render colorizes completed task status' );
ok( $dynamic->update({ task_id => 'unit', status => 'failed', label => 'Compile failed' }), 'update transitions the task to failed' );
like( $output, qr/\e\[31m\[X\]\e\[0m Compile failed/, 'render colorizes failed task status and updated label' );
is( $dynamic->_status_prefix('other'), '[ ]', '_status_prefix uses the pending marker for unknown status' );
is( $dynamic->_status_prefix(undef), '[ ]', '_status_prefix uses the pending marker for an undefined status' );
is( $dynamic->_colorize( '[ ]', 'other' ), '[ ]', '_colorize leaves unknown status text unchanged' );
is( $dynamic->_colorize( '[ ]', undef ), '[ ]', '_colorize leaves an undefined status uncolored' );
ok( $dynamic->finish, 'finish adds a trailing line after a rendered dynamic board' );
like( $output, qr/Compile failed\n\n\z/, 'finish leaves the terminal on a fresh line' );

$output = '';
close $stream or die "Unable to close scalar output: $!";
open $stream, '>', \$output or die "Unable to reopen scalar output: $!";
my $plain = Developer::Dashboard::Pax::CLI::Progress->new(
    tasks => [
        { id => 'running', status => 'running' },
        { id => 'done', status => 'done' },
        { id => 'failed', status => 'failed' },
        { id => 'pending', status => 'pending' },
    ],
    stream => $stream,
    color  => 0,
);
for my $status (qw(running done failed)) {
    ok( $plain->update({ task_id => $status, status => $status }), "update sets the $status state" );
}
like( $plain->render_text, qr/^pax progress\n-> running\n\[OK\] done\n\[X\] failed\n\[ \] pending\n\z/, 'render_text maps all task states without ANSI color when disabled' );
is( $plain->_colorize( 'marker', 'done' ), 'marker', '_colorize preserves marker text when color is disabled' );
$plain->{order} = ['missing-task-record'];
is( $plain->render_text, "pax progress\n", 'render_text skips a task whose record is absent from the lookup table' );

$output = '';
close $stream or die "Unable to close scalar output: $!";
open $stream, '>', \$output or die "Unable to reopen scalar output: $!";
my $unrendered = bless { dynamic => 1, rendered => 0, stream => $stream }, 'Developer::Dashboard::Pax::CLI::Progress';
ok( $unrendered->finish, 'finish does not print a newline before a dynamic board has rendered' );
is( $output, '', 'finish leaves an unrendered board stream untouched' );

done_testing;

__END__

=head1 NAME

242-pax-cli-progress-coverage.t - focused coverage tests for PAX CLI progress rendering

=head1 PURPOSE

This test exercises the public constructor, update callback, rendering, color,
dynamic redraw, and finish behavior of C<Developer::Dashboard::Pax::CLI::Progress>.

=head1 WHY IT EXISTS

C<pax build> reports ordered work phases to stderr while preserving its stdout
result for callers. This test keeps that terminal behavior and its input
validation measurable independently from the larger build integration suite.

=head1 WHEN TO USE

Use this test when changing task status handling, output formatting, ANSI color,
dynamic redraw behavior, or the progress stream lifecycle.

=head1 HOW TO USE

Run C<prove -lv t/242-pax-cli-progress-coverage.t> for the focused regression
loop, then run C<script/coverage-gate> to verify repository-wide coverage.

=head1 WHAT USES IT

The PAX CLI progress renderer is used by long-running C<pax build> operations;
the focused test is also run by the repository test and coverage gates.

=head1 EXAMPLES

Example 1: run the behavioral checks directly:

  prove -lv t/242-pax-cli-progress-coverage.t

Example 2: collect focused coverage in a clean temporary database:

  HARNESS_PERL_SWITCHES='-MDevel::Cover=-db,/tmp/pax-progress-cover' prove -lv t/242-pax-cli-progress-coverage.t

Example 3: verify all production library coverage after focused changes:

  script/coverage-gate

=cut
