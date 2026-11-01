use strict;
use warnings;

use File::Temp qw(tempdir);
use Test::More;

use Developer::Dashboard::GoRoutine ();

my $dir = tempdir( CLEANUP => 1 );
sub run_child {
    my ( $name, $source, $expected ) = @_;
    my $output = "$dir/$name.txt";
    my $script = "use strict; use warnings; use Developer::Dashboard::GoRoutine;\n$source";
    my $child = Developer::Dashboard::GoRoutine::spawn(
        [ $^X, '-e', $script ],
        { stdout => $output, stderr => $output },
    );
    is( Developer::Dashboard::GoRoutine::wait_process($child), 0,
        "$name child exits successfully" );
    open my $fh, '<', $output or die "Unable to read child output '$output': $!";
    my @lines = <$fh>;
    close $fh or die "Unable to close child output '$output': $!";
    is_deeply( \@lines, $expected, "$name drains the expected worker output" );
}

run_child(
    'automatic-shutdown',
    q{go sub { select undef, undef, undef, 0.12; print "worker-finished\n"; };
      print "main-finished\n";},
    [ "main-finished\n", "worker-finished\n" ],
);

run_child(
    'explicit-exit',
    q{go sub { select undef, undef, undef, 0.12; print "exit-worker-finished\n"; };
      print "main-exit\n"; exit 0;},
    [ "main-exit\n", "exit-worker-finished\n" ],
);

run_child(
    'nested-shutdown',
    q{go sub {
          select undef, undef, undef, 0.05;
          go sub { select undef, undef, undef, 0.05; print "nested-finished\n"; };
      };
      print "nested-main-finished\n";},
    [ "nested-main-finished\n", "nested-finished\n" ],
);

done_testing;

__END__

=head1 NAME

240-goroutine-shutdown.t - verify automatic worker draining at Perl shutdown

=head1 DESCRIPTION

This test starts child Perl interpreters using C<Developer::Dashboard::GoRoutine>.
They launch delayed workers and reach normal shutdown, explicit C<exit>, or
nested worker completion without calling C<wait_all>. The parent verifies that
each child drains its workers before returning.

=head1 PURPOSE

Confirm the GoRoutine XS extension registers a root-interpreter shutdown drain,
including nested routines and explicit normal C<exit>, without requiring
application code to add an C<END> block.

=head1 WHY IT EXISTS

Detached work must not be silently abandoned when a Perl program exits. The
test checks that normal, explicit, and nested shutdown paths drain workers
without every caller having to remember a separate wait operation.

=head1 WHEN TO USE

Run after rebuilding the distribution XS in the dev Docker container. This is
the regression test for GoRoutine 0.03 automatic shutdown behaviour.

=head1 HOW TO USE

  d2 docker compose exec dev prove -lv t/240-goroutine-shutdown.t

All test output is captured in a temporary directory. The child is launched
through the native GoRoutine process helper so the test does not call Perl
C<fork>.

=head1 WHAT USES IT

The test harness verifies GoRoutine's shutdown contract for programs that use
detached asynchronous callbacks and nested worker routines.

=head1 EXAMPLES

  go sub { print "worker complete\n" };
  exit 0; # Normal exit drains the worker without an explicit wait_all().

=cut
