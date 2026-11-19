use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use lib 'lib';

use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::Platform qw(effective_mode_octal windows_acl_is_owner_only);

my $home = tempdir( CLEANUP => 1 );
print "LOG: before new PathRegistry home=$home\n";
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
print "LOG: after new PathRegistry\n";

my $overlay = File::Spec->catdir( $home, 'micro-overlay' );
print "LOG: before setting DEVELOPER_DASHBOARD_CONFIG_OVERLAY=$overlay\n";
local $ENV{DEVELOPER_DASHBOARD_CONFIG_OVERLAY} = $overlay;
print "LOG: before first config_root (creation branch)\n";
my $root1 = $paths->config_root;
print "LOG: after first config_root root=$root1 exists=" . ( -d $overlay ? 1 : 0 ) . "\n";
my @stat1 = stat $overlay;
my $mode1 = @stat1 ? sprintf( '%04o', $stat1[2] & 07777 ) : 'undef';
my $eff1  = effective_mode_octal($overlay) // 'undef';
my $acl1  = windows_acl_is_owner_only($overlay);
$acl1 = defined $acl1 ? $acl1 : 'undef';
print "RESULT-AFTER-CREATE: stat=$mode1 effective=$eff1 is_owner_only=$acl1\n";
ok( defined $root1, 'first config_root returns the overlay path' );

print "LOG: before second config_roots (existing branch)\n";
my @roots = $paths->config_roots;
print "LOG: after second config_roots count=" . scalar(@roots) . "\n";
my @stat2 = stat $overlay;
my $mode2 = @stat2 ? sprintf( '%04o', $stat2[2] & 07777 ) : 'undef';
my $eff2  = effective_mode_octal($overlay) // 'undef';
my $acl2  = windows_acl_is_owner_only($overlay);
$acl2 = defined $acl2 ? $acl2 : 'undef';
print "RESULT-AFTER-SECOND: stat=$mode2 effective=$eff2 is_owner_only=$acl2\n";
ok( scalar(@roots) > 0, 'second config_roots returns roots' );

print "LOG: before third config_layers (existing branch again)\n";
my @layers = $paths->config_layers;
print "LOG: after third config_layers count=" . scalar(@layers) . "\n";
my @stat3 = stat $overlay;
my $mode3 = @stat3 ? sprintf( '%04o', $stat3[2] & 07777 ) : 'undef';
my $eff3  = effective_mode_octal($overlay) // 'undef';
my $acl3  = windows_acl_is_owner_only($overlay);
$acl3 = defined $acl3 ? $acl3 : 'undef';
print "RESULT-AFTER-THIRD: stat=$mode3 effective=$eff3 is_owner_only=$acl3\n";
ok( scalar(@layers) > 0, 'third config_layers returns layers' );

print "LOG: done\n";
done_testing();

__END__

=head1 NAME

t/998-micro-t97-overlay-acl.t - measure the private config overlay DACL state on each access

=head1 PURPOSE

Measures, without asserting a fix, whether the private config overlay
directory carries an owner-only DACL right after creation and after the
second and third accesses through _config_overlay_root, on each platform.

=head1 WHY IT EXISTS

Solo #203 failed t/97 test 6 on Windows only: the overlay stat mode read
0777 instead of 0700. The test observes through raw stat, which can never
see a Windows DACL, and _ensure_state_dir only hardens the directory on
the existing-directory branch. This micro measures the stat mode, the
DACL-derived effective mode, and the owner-only check after each access
so the fix can target the real gap instead of the observation.

=head1 WHEN TO USE

Run this micro when diagnosing the t/97 test 6 Windows failure and when
verifying the overlay hardening fix, then remove it.

=head1 HOW TO USE

From the repository, run:

  prove -lv t/998-micro-t97-overlay-acl.t

Run it as a Jenkins solo for the Windows measurement.

=head1 WHAT USES IT

Nothing in production uses this file. It is a throwaway diagnostic for
the t/97 test 6 investigation.

=head1 EXAMPLES

Example 1:

  prove -lv t/998-micro-t97-overlay-acl.t

Prints RESULT-AFTER-CREATE, RESULT-AFTER-SECOND and RESULT-AFTER-THIRD
lines with stat, effective-mode and owner-only readings.

=cut
