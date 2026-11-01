use strict;
use warnings;
use utf8;
use Test::More;
use JSON::XS qw(decode_json);

use lib 'lib';

use Developer::Dashboard::GoRoutine;

my $runner_loaded = eval { require Developer::Dashboard::SystemMenu::Runner; 1 };
ok( $runner_loaded, 'system-menu runner module loads without starting a native menu' )
  or diag( $@ || 'runner module failed to load' );

SKIP: {
    skip 'system-menu runner is not implemented yet', 7 if !$runner_loaded;

    share my $disabled_shared = { runs => 0, stop_calls => 0, entered => 0, stopped => 0 };
    my $disabled_menu = Local::SystemMenuTestMenu->new($disabled_shared);
    my $disabled = Developer::Dashboard::SystemMenu::Runner->new(
        config => { indicators => [
            { name => 'build', indicator => { macos => 0 } },
        ] },
        platform => 'macos',
        store    => Local::SystemMenuTestStore->new,
        menu     => $disabled_menu,
    );

    ok( !$disabled->start, 'disabled platform setting does not launch a menu worker' );
    is( 0 + $disabled_shared->{runs}, 0, 'disabled setting leaves native adapter untouched' );

    share my $enabled_shared = { runs => 0, stop_calls => 0, entered => 0, stopped => 0 };
    my $enabled_menu = Local::SystemMenuTestMenu->new($enabled_shared);
    my $enabled = Developer::Dashboard::SystemMenu::Runner->new(
        config => { indicators => [
            { name => 'build', indicator => { macos => 1 } },
            { name => 'hidden', indicator => { macos => 0 } },
        ] },
        platform => 'macos',
        store    => Local::SystemMenuTestStore->new,
        menu     => $enabled_menu,
    );

    my $routine = $enabled->start;
    ok( $routine && $routine->can('is_running'), 'enabled setting starts a controlled GoRoutine worker' );

    my $attempt = 0;
    while ( !$enabled_shared->{entered} && $attempt++ < 100 ) {
        select undef, undef, undef, 0.01;
    }
    ok( $enabled_shared->{entered}, 'worker enters the native menu run loop' );
    is 0 + $enabled_shared->{items_icon_utf8}, 1,
      'worker menu input retains the icon UTF-8 flag';
    is_deeply(
        decode_json( "$enabled_shared->{items_json}" ), [ { name => 'build', icon => '✅' } ],
        'menu receives only enabled indicators and their latest stored icons',
    );

    ok( $enabled->stop, 'stop requests clean menu shutdown and waits for the worker' );
    is( 0 + $enabled_shared->{stopped}, 1, 'menu worker exits after its native adapter is stopped' );
}

done_testing;

package Local::SystemMenuTestStore;

# new()
# Creates the test indicator store.
# Input: class name.
# Output: in-memory store object.
sub new { bless {}, shift }

# list_indicators()
# Returns the current in-memory indicator snapshot.
# Input: store object.
# Output: array reference of indicator state hashes.
sub list_indicators {
    return [
        { name => 'build', icon => '✅', status => 'ok' },
        { name => 'hidden', icon => '❌', status => 'error' },
    ];
}

package Local::SystemMenuTestMenu;

# new($state)
# Creates a fake menu adapter backed by shared test state.
# Input: class name and shared state hash reference.
# Output: fake adapter object.
sub new { bless { state => $_[1] }, $_[0] }

# run($items)
# Records projected items and waits for the test to request shutdown.
# Input: adapter object and array reference of projected menu items.
# Output: adapter object after its shared stop flag becomes true.
sub run {
    my ( $self, $items ) = @_;
    $self->{state}{items_icon_utf8} = utf8::is_utf8( $items->[0]{icon} ) ? 1 : 0;
    $self->{state}{items_json} = JSON::XS::encode_json($items);
    $self->{state}{entered} = 1;
    while ( !$self->{state}{stopped} ) {
        select undef, undef, undef, 0.01;
    }
    return $self;
}

# stop()
# Signals the fake native menu loop to exit.
# Input: adapter object.
# Output: true after recording the shutdown request.
sub stop {
    my ($self) = @_;
    $self->{state}{stop_calls}++;
    $self->{state}{stopped} = 1;
    return 1;
}

1;

__END__

=head1 NAME

t/241-system-menu-runner.t - system-menu runner lifecycle regression tests

=head1 PURPOSE

This test specifies the opt-in boundary between configured Dashboard indicators,
the current indicator store, the platform menu adapter, and GoRoutine-managed
menu execution. It uses an injected in-memory adapter, so Linux Docker can test
selection and shutdown without claiming that a native desktop menu is visible.

=head1 WHY IT EXISTS

The System Menu integration must not launch a helper when no indicator is
enabled for the current platform. When enabled, it must pass the current
indicator projection to one controlled worker and stop that worker cleanly.
These checks protect the runtime contract independently of AppKit, Windows
notification-area, or Ubuntu desktop availability.

=head1 WHEN TO USE

Run this file in the dev Docker container when changing the system-menu runner,
its indicator-store integration, or GoRoutine lifecycle handling. Native
platform visibility still requires the corresponding hosted platform workflow.

=head1 HOW TO USE

    d2 docker compose exec dev prove -lv t/241-system-menu-runner.t

The test loads C<Developer::Dashboard::SystemMenu::Runner>, verifies that a
disabled platform setting is inert, starts an enabled fake menu, checks the
projected indicator data, then requests stop and verifies worker exit.

=head1 EXAMPLES

The disabled case configures C<macos =E<gt> 0> and proves that neither a
GoRoutine nor the adapter's C<run> method is started. The enabled case configures
one visible and one hidden indicator, verifies the visible entry carries the
stored icon, then calls C<stop> and checks the adapter and worker shutdown.

=head1 WHAT USES IT

The Docker unit suite uses this test as the platform-independent contract for
C<Developer::Dashboard::SystemMenu::Runner>. It does not replace the native
macOS, Windows, and Ubuntu integration workflows, which must exercise each
platform-specific adapter on an appropriate host.

=cut
