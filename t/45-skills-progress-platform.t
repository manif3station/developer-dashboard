use strict;
use warnings;

use Test::More;

use lib 'lib';

use Developer::Dashboard::CLI::Skills ();

{
    package Local::CaptureProgress;

    sub new {
        my ( $class, @args ) = @_;
        shift @args if @args % 2 == 1 && !ref( $args[0] );
        my %args = @args;
        return bless \%args, $class;
    }
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::CLI::Progress::new = sub { return Local::CaptureProgress->new(@_) };
    local $ENV{DEVELOPER_DASHBOARD_PROGRESS} = 1;
    local $ENV{DD_TEST_OS} = 'linux';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 1;
    local $ENV{DD_TEST_ALPINE} = 0;
    local $ENV{DD_TEST_FEDORA} = 0;

    my $progress = Developer::Dashboard::CLI::Skills::_skills_install_progress();
    isa_ok( $progress, 'Local::CaptureProgress', 'skills install progress can be captured through the progress constructor override' );
    is( $progress->{max_detail_lines}, 10, 'skills install progress caps dependency detail output at ten lines' );
    my @task_ids = map { $_->{id} } @{ $progress->{tasks} || [] };
    ok( scalar( grep { $_ eq 'install_aptfile' } @task_ids ), 'skills install progress keeps aptfile tasks on Debian-like hosts' );
    ok( !scalar( grep { $_ eq 'install_wingetfile' } @task_ids ), 'skills install progress hides wingetfile tasks on Debian-like hosts' );
    ok( !scalar( grep { $_ eq 'install_brewfile' } @task_ids ), 'skills install progress hides brewfile tasks on Debian-like hosts' );

    my $source_progress = Developer::Dashboard::CLI::Skills::_skills_install_progress_for_sources(qw(one two));
    isa_ok( $source_progress, 'Local::CaptureProgress', 'multi-source skills install progress also uses the capture progress override' );
    is( $source_progress->{max_detail_lines}, 10, 'multi-source skills install progress also caps dependency detail output at ten lines' );
}

{
    no warnings 'redefine';
    local *Developer::Dashboard::CLI::Progress::new = sub { return Local::CaptureProgress->new(@_) };
    local $ENV{DEVELOPER_DASHBOARD_PROGRESS} = 1;
    local $ENV{DD_TEST_OS} = 'darwin';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 0;
    local $ENV{DD_TEST_ALPINE} = 0;
    local $ENV{DD_TEST_FEDORA} = 0;

    my $progress = Developer::Dashboard::CLI::Skills::_skills_install_progress();
    my @task_ids = map { $_->{id} } @{ $progress->{tasks} || [] };
    ok( scalar( grep { $_ eq 'install_brewfile' } @task_ids ), 'skills install progress keeps brewfile tasks on macOS' );
    ok( !scalar( grep { $_ eq 'install_aptfile' } @task_ids ), 'skills install progress hides aptfile tasks on macOS' );
    ok( !scalar( grep { $_ eq 'install_wingetfile' } @task_ids ), 'skills install progress hides wingetfile tasks on macOS' );
}

{
    local $ENV{DD_TEST_OS} = 'MSWin32';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 0;
    local $ENV{DD_TEST_ALPINE} = 0;
    local $ENV{DD_TEST_FEDORA} = 0;

    my $tasks = Developer::Dashboard::CLI::Skills::_skills_install_progress_tasks();
    my @task_ids = map { $_->{id} } @{ $tasks || [] };
    ok( scalar( grep { $_ eq 'install_wingetfile' } @task_ids ), 'skills install progress keeps wingetfile tasks on Windows' );
    ok( !scalar( grep { $_ eq 'install_aptfile' } @task_ids ), 'skills install progress hides aptfile tasks on Windows' );
    ok( !scalar( grep { $_ eq 'install_brewfile' } @task_ids ), 'skills install progress hides brewfile tasks on Windows' );
}

{
    local $ENV{DD_TEST_OS} = 'linux';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 0;
    local $ENV{DD_TEST_ALPINE} = 1;
    local $ENV{DD_TEST_FEDORA} = 0;

    my $tasks = Developer::Dashboard::CLI::Skills::_skills_install_progress_tasks();
    my @task_ids = map { $_->{id} } @{ $tasks || [] };
    ok( scalar( grep { $_ eq 'install_apkfile' } @task_ids ), 'skills install progress keeps apkfile tasks on Alpine hosts' );
    ok( !scalar( grep { $_ eq 'install_aptfile' } @task_ids ), 'skills install progress hides aptfile tasks on Alpine hosts' );
    ok( !scalar( grep { $_ eq 'install_brewfile' } @task_ids ), 'skills install progress hides brewfile tasks on Alpine hosts' );
}

{
    local $ENV{DD_TEST_OS} = 'linux';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 0;
    local $ENV{DD_TEST_ALPINE} = 0;
    local $ENV{DD_TEST_FEDORA} = 1;

    my $tasks = Developer::Dashboard::CLI::Skills::_skills_install_progress_tasks();
    my @task_ids = map { $_->{id} } @{ $tasks || [] };
    ok( scalar( grep { $_ eq 'install_dnfile' } @task_ids ), 'skills install progress keeps dnfile tasks on Fedora-like hosts' );
    ok( !scalar( grep { $_ eq 'install_aptfile' } @task_ids ), 'skills install progress hides aptfile tasks on Fedora-like hosts' );
    ok( !scalar( grep { $_ eq 'install_brewfile' } @task_ids ), 'skills install progress hides brewfile tasks on Fedora-like hosts' );
}

{
    local $ENV{DD_TEST_OS} = 'solaris';
    local $ENV{DD_TEST_DEBIAN_LIKE} = 0;
    local $ENV{DD_TEST_ALPINE} = 0;
    local $ENV{DD_TEST_FEDORA} = 0;

    my $tasks = Developer::Dashboard::CLI::Skills::_skills_install_progress_tasks();
    my @task_ids = map { $_->{id} } @{ $tasks || [] };
    ok( scalar( grep { $_ eq 'install_aptfile' } @task_ids ), 'skills install progress keeps aptfile tasks on unknown hosts' );
    ok( scalar( grep { $_ eq 'install_wingetfile' } @task_ids ), 'skills install progress keeps wingetfile tasks on unknown hosts' );
    ok( scalar( grep { $_ eq 'install_brewfile' } @task_ids ), 'skills install progress keeps brewfile tasks on unknown hosts' );
}

done_testing();

__END__

=pod

=head1 NAME

t/45-skills-progress-platform.t - skill install progress host filtering regression

=head1 PURPOSE

This test keeps the skill-install progress board aligned with the current host.
It verifies that dependency detail output is capped to ten lines and that only
platform-relevant package-manager tasks stay visible in the progress board.

=head1 WHY IT EXISTS

The skills install progress board became noisy and misleading because it showed
every package-manager step regardless of the current operating system. This
test exists to stop regressions where Linux users see irrelevant Brew or
Winget progress rows, macOS users see Apt rows, or dependency output floods
the whole terminal instead of staying capped.

=head1 WHEN TO USE

Use this test when changing the skills install progress task list, the
platform-detection logic behind package-manager filtering, or the detail-line
limit used while streaming dependency installation progress.

=head1 HOW TO USE

Run this file directly with C<prove -lv t/45-skills-progress-platform.t> when
iterating on the progress board behaviour, or let it run through the full test
suite to confirm the regression stays covered across the release gates. The
test forces synthetic Linux and macOS host markers through environment
variables and inspects the captured progress object produced by the skills
helper.

=head1 WHAT USES IT

This file is used by the repository release metadata gate, the full Perl test
suite, and contributors changing C<Developer::Dashboard::CLI::Skills> or the
shared progress rendering behaviour.

=head1 EXAMPLES

  prove -lv t/45-skills-progress-platform.t
  prove -lr t

=cut
