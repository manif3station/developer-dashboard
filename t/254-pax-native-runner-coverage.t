#!/usr/bin/env perl

use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::NativeRunner;

my $root = tempdir(CLEANUP => 1);
my $runner = Developer::Dashboard::Pax::NativeRunner->new;
isa_ok( $runner, 'Developer::Dashboard::Pax::NativeRunner', 'constructor creates a runner' );

my $sum = _script($root, 'sum.pl', 'print (($ARGV[0] // 0) + ($ARGV[1] // 0), "\n");');
my $sum_result = $runner->run_i64_binary(path => $sum, left => 7, right => -2);
is( $sum_result->{status}, 'ok', 'executable with a zero exit status succeeds' );
is( $sum_result->{exit}, 0, 'successful result records exit zero' );
is( $sum_result->{stdout}, '5', 'runner trims the final newline from stdout' );
is( $sum_result->{stderr}, '', 'empty stderr is returned as an empty string' );
is( $sum_result->{value}, 5, 'integer stdout is converted to a numeric result' );

my $defaults = $runner->run_i64_binary(path => $sum);
is( $defaults->{stdout}, '0', 'undefined operands default to zero' );
is( $defaults->{value}, 0, 'default integer output converts to zero' );

my $textual = _script($root, 'text.pl', 'print "ready\n"; print STDERR "notice\n";');
my $text_result = $runner->run_i64_binary(path => $textual, left => 1, right => 2);
is( $text_result->{status}, 'ok', 'text output can still be a successful native process' );
is( $text_result->{stdout}, 'ready', 'text stdout is retained' );
is( $text_result->{stderr}, "notice\n", 'stderr is retained without altering child output' );
ok( !defined $text_result->{value}, 'non-integer stdout has no numeric value' );

my $failed = _script($root, 'failed.pl', 'print "bad result\n"; print STDERR "native error\n"; exit 7;');
my $failed_result = $runner->run_i64_binary(path => $failed, left => 3, right => 4);
is( $failed_result->{status}, 'error', 'nonzero process exit is an error' );
is( $failed_result->{exit}, 7, 'error result retains the subprocess exit code' );
is( $failed_result->{stdout}, 'bad result', 'failed process stdout remains available for diagnosis' );
is( $failed_result->{stderr}, "native error\n", 'failed process stderr remains available for diagnosis' );
ok( !defined $failed_result->{value}, 'non-integer failed output is not converted' );

my $silent = _script($root, 'silent.pl', 'exit 0;');
my $silent_result = $runner->run_i64_binary(path => $silent);
ok( defined $silent_result->{stdout}, 'empty stdout is a defined empty child-stream result' );
is( $silent_result->{stdout}, '', 'EOF without stdout maps to an empty string' );
ok( defined $silent_result->{stderr}, 'empty stderr is a defined empty child-stream result' );
is( $silent_result->{stderr}, '', 'EOF without stderr maps to an empty string' );
ok( !defined $silent_result->{value}, 'empty stdout has no numeric value' );

my $missing = $runner->run_i64_binary(path => undef);
is( $missing->{status}, 'error', 'undefined executable path returns an error result' );
is( $missing->{reason}, 'native executable missing or not executable', 'missing-path error is actionable' );

my $not_executable = _script($root, 'not-executable.pl', 'print "should not run";');
chmod 0600, $not_executable or die "cannot make fixture non-executable: $!";
my $invalid = $runner->run_i64_binary(path => $not_executable);
is( $invalid->{status}, 'error', 'non-executable path returns an error result' );
is( $invalid->{reason}, 'native executable missing or not executable', 'non-executable error matches missing-path error' );

my $before = 23 << 8;
local $? = $before;
$runner->run_i64_binary(path => $sum, left => 1, right => 2);
is( $?, $before, 'native subprocess exit status does not leak into caller state' );

done_testing();

sub _script {
    my ( $directory, $name, $body ) = @_;
    my $path = "$directory/$name";
    open my $handle, '>', $path or die "cannot create executable fixture $path: $!";
    print {$handle} "#!/usr/bin/env perl\nuse strict;\nuse warnings;\n$body\n";
    close $handle or die "cannot close executable fixture $path: $!";
    chmod 0700, $path or die "cannot make executable fixture runnable $path: $!";
    return $path;
}

__END__

=head1 NAME

t/254-pax-native-runner-coverage.t - tests subprocess runner outcomes

=head1 PURPOSE

Exercises the process-launch contract of
C<Developer::Dashboard::Pax::NativeRunner> with isolated executable fixtures,
covering successful and failed exits, missing executables, default operands,
stdout/stderr parsing, numeric conversion, and caller exit-status isolation.

=head1 WHY IT EXISTS

The native runner crosses the process boundary between the Perl application and
compiled artifacts. These tests use small temporary Perl executables so the
actual open, read, wait, and exit-status paths are covered without relying on a
compiler or persistent files.

=head1 WHEN TO USE

Run this test when changing executable validation, subprocess arguments,
captured output, exit handling, or numeric result conversion.

=head1 HOW TO USE

Run inside the development Docker service:

  d2 docker compose --project-name problem20 -f .developer-dashboard/config/docker/d2/compose.yml -f .developer-dashboard/config/docker/d2/development.compose.yml exec -T dev prove -lv t/254-pax-native-runner-coverage.t

=head1 WHAT USES IT

C<RuntimeDispatcher> invokes the runner for native integer regions, and the PAX
benchmark and standalone dispatch paths consume its structured process result.

=head1 EXAMPLES

Example 1: provide an executable and two integers to receive a numeric result.

Example 2: run a process that exits nonzero and inspect its exit code, stdout,
and stderr without losing the caller's previous Perl C<$?> value.

=cut
