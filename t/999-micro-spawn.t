use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use Developer::Dashboard::GoRoutine ();

# Micro-repro for the t/232 Windows spawn failures (Jenkins build #121).
# Diagnostic only, not part of the suite: every check prints the raw
# observed value with diag, so the console shows what the child actually
# did. The first child records its own account (print result, $!) in a
# file it opens itself, so a broken stdio handle cannot hide the evidence.

my $dir = tempdir( CLEANUP => 1 );
my $stdout = File::Spec->catfile( $dir, 'stdout.txt' );
my $stderr = File::Spec->catfile( $dir, 'stderr.txt' );

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

# H1: redirected stdout. The child prints, then writes print()'s return
# value and $! to its own diag file before exiting 7.
my $diag_a = File::Spec->catfile( $dir, 'diag-a.txt' );
my $script_a
    = 'open my $d, \'>\', \'' . $diag_a . '\' or die "diag open: $!"; '
    . 'my $ok = print "child-output\n"; '
    . 'print {$d} "print-ok=" . ($ok ? 1 : 0) . " err=" . $! . "\n"; '
    . 'close $d or die "diag close: $!"; '
    . 'exit 7;';
my $child_a = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', $script_a ],
    { cwd => $dir, stdout => $stdout, stderr => $stderr },
);
ok defined($child_a) && $child_a > 0, 'probe: spawn returns a pid';
is( Developer::Dashboard::GoRoutine::wait_process($child_a), 7,
    'probe: stdout child exits 7' );
my $out_a = _slurp($stdout);
diag 'probe: stdout file content: ' . ( defined $out_a ? $out_a : '<undef>' );
is( $out_a, "child-output\n", 'probe: child stdout reaches the redirect file' );
my $diag_a_content = _slurp($diag_a);
diag 'probe: child self-report: ' . ( defined $diag_a_content ? $diag_a_content : '<undef>' );
like( $diag_a_content // '', qr/^print-ok=1/m,
    'probe: child print() to redirected stdout succeeded' );

# H3: environment merge. The native Windows spawn ignores the env option,
# so the child should still see the override if the wrapper merges it.
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
        'probe: env child exits 0' );
}
my $env_content = _slurp($env_output);
diag 'probe: env output file content: ' . ( defined $env_content ? $env_content : '<undef>' );
is( $env_content, 'inherited-value|explicit-child-value',
    'probe: child sees inherited env plus explicit override' );

# H2: completed-child retention. A child that exits at once must still
# exist until wait_process collects it, and wait must report its real code.
my $completed = Developer::Dashboard::GoRoutine::spawn(
    [ $^X, '-e', 'exit 9;' ],
    { cwd => $dir, stdout => $stdout, stderr => $stderr },
);
my $deadline = time() + 2;
while ( !Developer::Dashboard::GoRoutine::process_exited($completed)
    && time() < $deadline )
{
    select undef, undef, undef, 0.01;
}
ok( Developer::Dashboard::GoRoutine::process_exited($completed),
    'probe: process_exited sees the completed child' );
my $running = Developer::Dashboard::GoRoutine::process_running($completed);
diag "probe: process_running(completed unreaped child) = $running";
is( $running, 1, 'probe: completed unreaped child still exists' );
my $code = Developer::Dashboard::GoRoutine::wait_process($completed);
diag "probe: wait_process(completed child) = $code";
is( $code, 9, 'probe: wait_process returns the real exit code 9' );

done_testing;
