package Developer::Dashboard::SystemMenu::Runner;

use strict;
use warnings;

our $VERSION = '6.28';

use Developer::Dashboard::GoRoutine qw(go);
use Developer::Dashboard::SystemMenu;

# new(%args)
# Builds a platform-specific menu runner using the current indicator store.
# Input: config hash reference, store object, platform name, and optional menu
#        adapter object for tests or specialized integrations.
# Output: runner object; invalid dependencies are rejected with an error.
sub new {
    my ( $class, %args ) = @_;
    die "config must be a hash reference\n" if ref( $args{config} ) ne 'HASH';
    die "store must provide list_indicators\n"
      if !ref( $args{store} ) || !$args{store}->can('list_indicators');
    die "platform must be a non-empty string\n"
      if !defined $args{platform} || ref( $args{platform} ) || $args{platform} eq '';
    die "menu must provide run and stop\n"
      if defined $args{menu}
      && ( !ref( $args{menu} ) || !$args{menu}->can('run') || !$args{menu}->can('stop') );

    return bless {
        config   => $args{config},
        store    => $args{store},
        platform => $args{platform},
        menu     => $args{menu},
        routine  => undef,
    }, $class;
}

# start()
# Starts the native menu worker only when the current platform has visible
# configured indicators.
# Input: runner object.
# Output: GoRoutine handle when started, or undef when the menu is disabled.
sub start {
    my ($self) = @_;
    die "system menu runner is already active\n" if $self->{routine};

    my $states = [ $self->{store}->list_indicators ];
    my $items = Developer::Dashboard::SystemMenu->items_for_platform(
        config     => $self->{config},
        indicators => $states,
        platform   => $self->{platform},
    );
    return if !@{$items};

    my $menu = $self->{menu} || $self->_native_menu;
    my $routine = go sub { $menu->run($items) };
    $self->{menu}    = $menu;
    $self->{routine} = $routine;
    return $routine;
}

# stop()
# Requests native menu shutdown and waits until its GoRoutine worker exits.
# Input: runner object.
# Output: true after clean shutdown; dies if the adapter or worker fails.
sub stop {
    my ($self) = @_;
    my $routine = $self->{routine} or return 0;
    my $stopped = $self->{menu}->stop;
    die "native system menu refused shutdown\n" if !$stopped;

    while ( $routine->is_running ) {
        select undef, undef, undef, 0.01;
    }

    my $status = $routine->status;
    die "native system menu worker ended with status '$status'\n"
      if $status ne 'done' && $status ne 'exited';
    $self->{routine} = undef;
    return 1;
}

# run_with($callback)
# Runs one foreground service while the configured native menu worker is active,
# then stops and joins that worker on normal return or exception.
# Input: runner object and a code reference for the foreground service.
# Output: the service callback's scalar return value; propagates service or
#        shutdown errors without leaving an active menu worker.
sub run_with {
    my ( $self, $callback ) = @_;
    die "foreground callback must be a code reference\n" if ref($callback) ne 'CODE';

    my ( $result, $run_ok, $run_error );
    $run_ok = eval {
        $self->start;
        $result = $callback->();
        1;
    };
    $run_error = $@;

    my ( $stop_ok, $stop_error );
    $stop_ok = eval { $self->stop; 1 };
    $stop_error = $@;

    die "$run_error\nSystem menu shutdown also failed: $stop_error"
      if !$run_ok && !$stop_ok;
    die $run_error if !$run_ok;
    die $stop_error if !$stop_ok;
    return $result;
}

# _native_menu()
# Lazily loads the native adapter so disabled indicators never initialize UI.
# Input: runner object.
# Output: native Developer::Dashboard::System::Menu singleton.
sub _native_menu {
    my ($self) = @_;
    require Developer::Dashboard::System::Menu;
    return Developer::Dashboard::System::Menu::menu();
}

1;

__END__

=head1 NAME

Developer::Dashboard::SystemMenu::Runner - opt-in native indicator menu lifecycle

=head1 PURPOSE

This module maps the configured Dashboard indicators for one operating system
and runs the native System Menu adapter on a controlled GoRoutine worker. It
keeps the blocking native event loop out of the command's main execution path.

=head1 WHY IT EXISTS

System Menu's C<run> method owns a blocking native event loop. Running that loop
directly would prevent the Dashboard process from continuing its normal work.
This runner starts no native adapter when the current platform has no enabled
indicator, and it retains one explicit stop-and-wait lifecycle for enabled
menus.

=head1 WHEN TO USE

Use this runner from the private C<web-foreground> runtime after configuration
layers and current indicator state have been loaded. Do not instantiate it
from lightweight CLI commands. Native desktop visibility and shutdown still
require hosted checks on each supported operating system.

=head1 HOW TO USE

    my $runner = Developer::Dashboard::SystemMenu::Runner->new(
        config   => $config,
        store    => $indicator_store,
        platform => 'macos',
    );
    my $worker = $runner->start;
    # ... normal Dashboard runtime ...
    $runner->stop if $worker;

C<start> returns undef and does not load the native adapter when there are no
visible configured indicators. When enabled, it projects current states in
configuration order and passes them to the adapter's C<run> method in a
GoRoutine. C<stop> asks the native adapter to exit, waits for the worker, and
raises an error unless the worker ended normally.

C<run_with($callback)> owns the common foreground-service lifecycle. It starts
the menu, invokes the callback, then requests and waits for menu shutdown after
either a normal callback return or an exception. The callback must be a code
reference. Its scalar result is returned unchanged; service errors are
re-thrown, and shutdown errors remain visible (including alongside a service
error).

=head1 EXAMPLES

An opt-in macOS configuration can select the build indicator:

    {
        indicators => [
            { name => 'build', indicator => { macos => 1 } },
        ],
    }

The same runner accepts C<windows> or C<ubuntu> as its platform key. Tests may
pass a menu adapter object implementing C<run> and C<stop>; production callers
omit it to lazily load the bundled native adapter. A disabled configuration
returns no worker and does not load the native adapter.

The foreground web service uses the wrapper form:

    my $status = $runner->run_with(sub { $server->run });

=head1 WHAT USES IT

The runtime menu integration uses this class to connect merged configuration,
IndicatorStore state, the pure SystemMenu projection, and the native event loop.
The focused Docker regression test injects a fake adapter to verify selection
and lifecycle without claiming native UI behavior.

=cut
