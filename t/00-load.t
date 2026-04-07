use strict;
use warnings;

use Test::More;

my @modules = qw(
  Developer::Dashboard
  Developer::Dashboard::Auth
  Developer::Dashboard::PathRegistry
  Developer::Dashboard::FileRegistry
  Developer::Dashboard::Codec
  Developer::Dashboard::JSON
  Developer::Dashboard::DataHelper
  Developer::Dashboard::Folder
  Developer::Dashboard::Zipper
  Developer::Dashboard::Runtime::Result
  Developer::Dashboard::InternalCLI
  Developer::Dashboard::CLI::OpenFile
  Developer::Dashboard::CLI::Paths
  Developer::Dashboard::CLI::Query
  Developer::Dashboard::IndicatorStore
  Developer::Dashboard::Collector
  Developer::Dashboard::CollectorRunner
  Developer::Dashboard::Config
  Developer::Dashboard::ActionRunner
  Developer::Dashboard::PageResolver
  Developer::Dashboard::PageRuntime
  Developer::Dashboard::DockerCompose
  Developer::Dashboard::Prompt
  Developer::Dashboard::RuntimeManager
  Developer::Dashboard::PageDocument
  Developer::Dashboard::PageStore
  Developer::Dashboard::SkillManager
  Developer::Dashboard::SkillDispatcher
  Developer::Dashboard::UpdateManager
  Developer::Dashboard::SessionStore
  Developer::Dashboard::Web::App
  Developer::Dashboard::Web::DancerApp
  Developer::Dashboard::Web::Server::Daemon
  Developer::Dashboard::Web::Server
);

for my $module (@modules) {
    use_ok($module);
}

done_testing;

__END__

=head1 NAME

00-load.t - load tests for Developer Dashboard modules

=head1 DESCRIPTION

This test verifies that the core Developer Dashboard modules compile and load.

=cut
