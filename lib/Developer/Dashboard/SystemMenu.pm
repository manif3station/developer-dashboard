package Developer::Dashboard::SystemMenu;

use strict;
use warnings;
use JSON::XS ();

our $VERSION = '6.19';

# items_for_platform(%args)
# Projects configured indicator declarations and current indicator states into
# the platform menu entries, without loading any native UI dependency.
# Input: config hash, indicator-state array, and platform name string.
# Output: ordered array reference of { name, icon } menu entries.
sub items_for_platform {
    my ( $class, %args ) = @_;
    die "config must be a hash reference\n" if ref( $args{config} ) ne 'HASH';
    die "indicators must be an array reference\n" if ref( $args{indicators} ) ne 'ARRAY';
    die "platform must be a non-empty string\n"
      if !defined $args{platform} || ref( $args{platform} ) || $args{platform} eq '';

    my $configured = $args{config}{indicators};
    die "indicators configuration must be an array reference\n"
      if defined $configured && ref($configured) ne 'ARRAY';
    return [] if !defined $configured;

    my @validated;
    my %seen;
    for my $entry ( @{$configured} ) {
        die "indicator configuration entries must be hash references\n" if ref($entry) ne 'HASH';
        my $name = $entry->{name};
        die "indicator configuration name must be a non-empty string\n"
          if !defined $name || ref($name) || $name eq '';
        die "duplicate indicator configuration name '$name'\n" if $seen{$name}++;
        my $platforms = $entry->{indicator};
        die "indicator '$name' settings must be a hash reference\n" if ref($platforms) ne 'HASH';
        my $selected;
        for my $platform (qw(macos windows ubuntu)) {
            my $enabled = $platforms->{$platform};
            next if !defined $enabled;
            my $valid_boolean = ref($enabled)
              ? JSON::XS::is_bool($enabled)
              : !ref($enabled) && $enabled =~ /\A(?:0|1)\z/;
            die "indicator '$name' $platform selector must be boolean\n"
              if !$valid_boolean;
            $selected = $enabled ? 1 : 0 if $platform eq $args{platform};
        }
        push @validated, [ $name, $selected ];
    }
    my $platform = $args{platform};
    return [] if $platform ne 'macos' && $platform ne 'windows' && $platform ne 'ubuntu';

    my %states;
    for my $state ( @{ $args{indicators} } ) {
        die "indicator state entries must be hash references\n" if ref($state) ne 'HASH';
        die "indicator state name must be a non-empty string\n"
          if !defined $state->{name} || ref( $state->{name} ) || $state->{name} eq '';
        die "indicator state icon must be a defined scalar\n"
          if !defined $state->{icon} || ref( $state->{icon} );
        $states{ $state->{name} } = $state;
    }

    my @items;
    for my $validated (@validated) {
        my ( $name, $enabled ) = @{$validated};
        next if !$enabled;
        next if !exists $states{$name};
        push @items, { name => $name, icon => $states{$name}{icon} };
    }

    return \@items;
}

1;

__END__

=head1 NAME

Developer::Dashboard::SystemMenu - project indicators into an operating-system menu

=head1 PURPOSE

This module is the configuration and presentation boundary between the
Developer Dashboard indicator store and an operating-system menu adapter. It
keeps menu selection deterministic and testable without loading a native
framework during ordinary command startup.

=head1 WHY IT EXISTS

The Dashboard already records named indicators and their current display
icons. A system menu should show only indicators explicitly enabled for that
platform, in configuration order, while leaving the existing terminal prompt
indicator path unchanged. Separating this projection from AppKit keeps Linux
tests able to validate configuration and mapping without pretending to run a
macOS menu.

=head1 WHEN TO USE

Use C<items_for_platform> from a platform-specific menu runner after loading
the merged dashboard configuration and current indicator records. The current
projection recognises the C<macos>, C<windows>, and C<ubuntu> selectors;
native menu startup and event handling are separate integration work. Ordinary
commands must not start a blocking menu loop.

=head1 HOW TO USE

    my $items = Developer::Dashboard::SystemMenu->items_for_platform(
        config     => $config,
        indicators => \@indicator_states,
        platform   => 'windows',
    );

The method returns an ordered array reference containing C<name> and C<icon>
for each configured indicator whose selector for the requested C<macos>,
C<windows>, or C<ubuntu> platform is enabled and has a current state. A missing
or false selector disables that item. Other platform names return an empty
array reference. Invalid configuration types and non-boolean values for any
supported platform selector are errors, even when the current host is not that
platform.

Pass the already merged configuration, current indicator records from
C<Developer::Dashboard::IndicatorStore>, and the platform key. The returned
array preserves declaration order and contains only currently available,
enabled indicators; callers pass it to a matching native adapter only after
that platform's lifecycle integration is available.

=head1 EXAMPLES

    {
        indicators => [
            { name => 'build', indicator => { macos => 1, windows => 1 } },
            { name => 'tests', indicator => { ubuntu => 1 } },
        ],
    }

Given current states C<{ name =E<gt> 'build', icon =E<gt> 'OK' }> and
C<{ name =E<gt> 'tests', icon =E<gt> 'FAIL' }>, a C<macos> or C<windows> call
contains the C<build> entry, while an C<ubuntu> call contains C<tests>. This is
configuration projection only; it does not assert that any native menu is
started or visible.

=head1 WHAT USES IT

Configuration tests use this module on Linux to verify platform selection and
validation without launching a graphical process. A native runner may use the
projection once its platform backend and lifecycle have been integrated. The
module itself has no native dependencies and can be loaded by commands on
every platform.

=cut
