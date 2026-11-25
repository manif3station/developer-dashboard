#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::SkillManager;
use File::Temp qw(tempdir);
use Test::More;

# ===========================================================================
# CPAN-green skip work (Michael, 25 Nov 2026): the aarch64 tester box has
# no /etc/debian_version, so the code correctly detects there is no Debian
# package manager - but t/102 hard-codes install_aptfile for all Linux.
# That is our test being wrong, not the box. AC 4: t/102 must expect the
# DETECTED package manager, not hard-coded install_aptfile - the test is
# portable across Linux. Harry's NO SKIP conclusion stands: fix the test,
# never skip it.
#
# These tests pin the behaviour the fixed t/102 must exhibit, in a form
# that runs on this host: the distro detection is simulable for the
# no-marker Linux shape (the aarch64 box), and the expected system task
# ids follow the detection, never a hard-coded aptfile for all Linux.
#
# The simulation hook is the force-off extension of the existing DD_TEST_*
# pattern: the existing hooks force a detection ON ('1'); setting one to
# '0' forces it OFF, even when the filesystem marker exists. That is the
# mechanism these tests propose - the aarch64 shape (Linux, no markers)
# is otherwise untestable on a host that has /etc/debian_version. If
# Harry prefers a different simulation, these tests need adjusting - the
# manager rules on that.
#
# The tests are expected to FAIL until Harry implements the force-off
# hook: the detections fall through to the real filesystem (this host has
# /etc/debian_version), so the forced-off expectations fail.
# ===========================================================================

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
chdir $home or die "Unable to chdir to $home: $!";

my $paths   = Developer::Dashboard::PathRegistry->new( home => $home );
my $manager = Developer::Dashboard::SkillManager->new( paths => $paths );

# Expected system task ids, derived from the detection predicates - the
# same mapping _host_progress_system_task_ids uses. The test never
# hard-codes a manager for an OS; it follows the detection.
sub _expected_system_task_ids {
    my ($mgr) = @_;
    my $os = $mgr->_current_os;
    return ['install_wingetfile'] if $os eq 'MSWin32';
    return ['install_brewfile']   if $os eq 'darwin';
    return ['install_apkfile']    if $mgr->_is_alpine;
    return ['install_dnfile']     if $mgr->_is_fedora;
    return ['install_aptfile']    if $mgr->_is_debian_like;
    return [];
}

# Controls: the existing force-on hooks already work, and the expected
# ids follow the detection in each case.
{
    local $ENV{DD_TEST_OS}     = 'linux';
    local $ENV{DD_TEST_ALPINE} = 1;
    delete local $ENV{DD_TEST_DEBIAN_LIKE};
    delete local $ENV{DD_TEST_FEDORA};
    is_deeply( [ $manager->_host_progress_system_task_ids ], ['install_apkfile'],
        'host progress task ids follow detection on Alpine' );
    is_deeply( [ $manager->_host_progress_system_task_ids ], _expected_system_task_ids($manager),
        'expected ids follow detection on Alpine' );
}
{
    local $ENV{DD_TEST_OS}     = 'linux';
    local $ENV{DD_TEST_FEDORA} = 1;
    delete local $ENV{DD_TEST_DEBIAN_LIKE};
    delete local $ENV{DD_TEST_ALPINE};
    is_deeply( [ $manager->_host_progress_system_task_ids ], ['install_dnfile'],
        'host progress task ids follow detection on Fedora' );
    is_deeply( [ $manager->_host_progress_system_task_ids ], _expected_system_task_ids($manager),
        'expected ids follow detection on Fedora' );
}
{
    local $ENV{DD_TEST_OS}          = 'linux';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 1;
    delete local $ENV{DD_TEST_ALPINE};
    delete local $ENV{DD_TEST_FEDORA};
    is_deeply( [ $manager->_host_progress_system_task_ids ], ['install_aptfile'],
        'host progress task ids follow detection on Debian-like hosts' );
    is_deeply( [ $manager->_host_progress_system_task_ids ], _expected_system_task_ids($manager),
        'expected ids follow detection on Debian-like hosts' );
}

# The aarch64 shape: Linux, no distro markers. Each detection can be
# forced off, even when the filesystem marker exists on this host.
{
    local $ENV{DD_TEST_OS}          = 'linux';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 0;
    delete local $ENV{DD_TEST_ALPINE};
    delete local $ENV{DD_TEST_FEDORA};
    is( $manager->_is_debian_like, 0,
        'DD_TEST_DEBIAN_LIKE=0 forces debian detection off despite /etc/debian_version existing' );
}
{
    local $ENV{DD_TEST_OS}     = 'linux';
    local $ENV{DD_TEST_ALPINE} = 0;
    delete local $ENV{DD_TEST_DEBIAN_LIKE};
    delete local $ENV{DD_TEST_FEDORA};
    is( $manager->_is_alpine, 0, 'DD_TEST_ALPINE=0 forces alpine detection off' );
}
{
    local $ENV{DD_TEST_OS}     = 'linux';
    local $ENV{DD_TEST_FEDORA} = 0;
    delete local $ENV{DD_TEST_DEBIAN_LIKE};
    delete local $ENV{DD_TEST_ALPINE};
    is( $manager->_is_fedora, 0, 'DD_TEST_FEDORA=0 forces fedora detection off' );
}

# AC 4: on a Linux host with no distro markers, there is no system task
# - not install_aptfile. The expected ids come from the detection, and
# the product's ids must equal them.
{
    local $ENV{DD_TEST_OS}          = 'linux';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 0;
    local $ENV{DD_TEST_ALPINE}      = 0;
    local $ENV{DD_TEST_FEDORA}      = 0;
    is_deeply( _expected_system_task_ids($manager), [],
        'expected ids are empty on a Linux host with no distro markers (aarch64 box shape)' );
    is_deeply( [ $manager->_host_progress_system_task_ids ], [],
        'host progress task ids are empty on a Linux host with no distro markers, not hard-coded install_aptfile' );
}

done_testing();

__END__

=head1 NAME

t/1000-cpan-green-detected-manager.t - failing tests for the CPAN-green t/102 fix (AC 4)

=head1 PURPOSE

Pin that the host-progress system task ids follow the detected package
manager, never a hard-coded C<install_aptfile> for all Linux. On a Linux
host with no distro markers (the aarch64 tester box: no
F</etc/debian_version>, not Alpine, not Fedora) there is no system task.
The distro detection is simulable via the C<DD_TEST_*> hooks, extended
so C<0> forces a detection off.

=head1 EXPECTED STATE

RED until Harry implements the force-off hook: the detections fall
through to the real filesystem (this host has F</etc/debian_version>),
so the forced-off expectations fail.
