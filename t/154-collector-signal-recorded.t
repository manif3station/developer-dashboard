#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes ();

use lib 'lib';

use Developer::Dashboard::Collector;
use Developer::Dashboard::CollectorRunner;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::IndicatorStore;
use Developer::Dashboard::PathRegistry;

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME}                           = $home;
local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = tempdir( CLEANUP => 1 );
chdir $home or die "Unable to chdir to $home: $!";

my $paths      = Developer::Dashboard::PathRegistry->new( home => $home );
my $collectors = Developer::Dashboard::Collector->new( paths => $paths );
my $runner     = Developer::Dashboard::CollectorRunner->new(
    collectors => $collectors,
    files      => Developer::Dashboard::FileRegistry->new( paths => $paths ),
    indicators => Developer::Dashboard::IndicatorStore->new( paths => $paths ),
    paths      => $paths,
);

my $name = "signal-probe-$$";
my $pid  = $runner->start_loop( { name => $name, interval => 3600, mode => 'singleton', command => 'true' } );
ok( $pid, 'a supervisor started' );

for ( 1 .. 200 ) { last if $runner->_is_managed_loop( $pid, $name ); Time::HiRes::sleep(0.05) }

kill 'TERM', $pid;

my $said = '';
for ( 1 .. 60 ) {
    $said = join ' ', map { ref $_ ? ( $_->{error} // '' ) : $_ } eval { $collectors->read_log($name) };
    last if $said =~ /SIGTERM/;
    Time::HiRes::sleep(0.1);
}

# A collector that stopped used to leave a 'stopped' state and no pidfile, which
# reads identically whether it shut down in an orderly way, was stopped by a
# watchdog, or was killed by somebody's stray signal. That ambiguity cost hours on
# DD-532, where every investigation began from "it died" instead of "it was told
# to stop". Perl hands the handler the signal name; it was being thrown away.
like( $said, qr/SIGTERM/, 'the loop records WHICH signal stopped it, not merely that it stopped' );
like( $said, qr/received by pid \d+/, 'and which process received it, so the record names a subject' );

done_testing;

__END__

=head1 NAME

t/154-collector-signal-recorded.t - a stopped collector says what stopped it

=head1 PURPOSE

Verify that when a supervisor loop is stopped by a signal, the signal's name and
the receiving pid are written to that collector's log before it shuts down.

=head1 WHY IT EXISTS

A collector that has been signalled leaves a C<stopped> state and no pidfile.
That is byte-identical to an orderly shutdown, to a watchdog stop, and to a stray
kill from somewhere else on the machine. During DD-532 a supervisor was being
stopped during batch test runs and every line of investigation started from the
wrong premise - that it had crashed - because nothing recorded that it had been
told to stop, or by which signal.

Perl passes the signal name to the handler. It was being discarded.

=head1 WHEN TO USE

Whenever the collector's signal handling or shutdown path changes.

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/154-collector-signal-recorded.t

=head1 WHAT USES IT

Nothing; it is a regression test for C<Developer::Dashboard::CollectorRunner>.

=head1 EXAMPLES

The line it guarantees appears in the collector's own log:

    SIGTERM received by pid 1433463

=cut
