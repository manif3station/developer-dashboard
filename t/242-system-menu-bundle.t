use strict;
use warnings;

use File::Spec;
use Test::More;
use Developer::Dashboard::Version ();

my $loaded = eval { require Developer::Dashboard::System::Menu; 1 };
ok( $loaded, 'system-menu API loads through the Dashboard XS bundle' )
  or diag( $@ || 'System::Menu failed to load' );

SKIP: {
    skip 'system-menu API is not loadable yet', 7 if !$loaded;

    is(
        $Developer::Dashboard::System::Menu::VERSION,
        $Developer::Dashboard::Version::VERSION,
        'system-menu module shares the distribution version',
    );

    for my $xs_method (qw(_start _command_json _read_events _stop _running)) {
        ok(
            Developer::Dashboard::System::Menu->can($xs_method),
            "$xs_method is registered in the shared Dashboard XS bundle",
        );
    }

    my $helper_name = $^O eq 'MSWin32'
      ? 'system_menu_helper.exe'
      : 'system_menu_helper';
    my $helper = File::Spec->catfile(
        'blib', 'arch', 'auto', 'Developer', 'Dashboard', $helper_name,
    );
    ok( -f $helper, 'native platform helper is built beside the Dashboard XS bundle' );
}

done_testing;

__END__

=head1 NAME

t/242-system-menu-bundle.t - shared XS bundle registration tests

=head1 PURPOSE

Verifies that the native System Menu API loads through the existing
Developer::Dashboard XS extension rather than requiring a second extension
object with a separately versioned ABI.

=head1 WHY IT EXISTS

System Menu owns native helper-process startup, command transport, event reads,
shutdown, and running-state checks. These XSUBs must be installed under the
System::Menu package by the Dashboard shared extension so normal Perl callers
can use the existing Developer::Dashboard::* module namespace.

=head1 WHEN TO USE

Run this test after changing the System Menu XS source, the main XS include
list, or the Perl module's XS loading path. It is intended to catch accidental
creation of a second XS bundle or missing XSUB registration before any native
helper is started.

=head1 HOW TO USE

Run inside the project dev container after generating the Makefile and building
the XS extension:

  prove -Iblib/lib -Iblib/arch -Ilib -lv t/242-system-menu-bundle.t

=head1 WHAT USES IT

The distribution test suite runs this contract alongside configuration and
runner lifecycle tests. The installed System::Menu module relies on the same
Dashboard XS object as HtmlEscape and GoRoutine.

=head1 EXAMPLES

Check the test through the Docker dev service:

  d2 docker compose exec dev prove -Iblib/lib -Iblib/arch -Ilib -lv t/242-system-menu-bundle.t

Load the module after building the distribution:

  perl -Iblib/lib -Iblib/arch -Ilib -MDeveloper::Dashboard::System::Menu -e 'print "$Developer::Dashboard::System::Menu::VERSION\n"'

=cut
