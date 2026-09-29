#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::XS ();
use Test::More;

use lib 'lib';
use Developer::Dashboard::Pax::StandaloneRuntime ();

my $root = tempdir( CLEANUP => 1 );
my $manifest_path = File::Spec->catfile( $root, 'manifest.json' );
my $manifest = {
    app => {
        namespace           => 'Ignored::Name',
        compat              => { namespace => ' ::Friendly-App:: ' },
        command             => 'manifest-command',
        entrypoint_command  => 'entrypoint-command',
        entrypoint_env      => 'MANIFEST_ENTRY',
        entrypoint_fallback => 'manifest-fallback',
    },
    code_units => [],
};
open my $manifest_fh, '>', $manifest_path or die "Unable to write $manifest_path: $!";
print {$manifest_fh} JSON::XS->new->canonical->encode($manifest);
close $manifest_fh or die "Unable to close $manifest_path: $!";

local $ENV{PAX_STANDALONE_MANIFEST_PATH} = $manifest_path;
local $ENV{PAX_STANDALONE_TMPDIR} = $root;
my $state = Developer::Dashboard::Pax::StandaloneRuntime::_state();

is( Developer::Dashboard::Pax::StandaloneRuntime::_app_env_prefix(), 'FRIENDLY_APP', 'environment prefix uses the compatibility namespace and normalizes punctuation' );
is( Developer::Dashboard::Pax::StandaloneRuntime::_app_env_prefix(), 'FRIENDLY_APP', 'environment prefix returns its cached value' );

{
    local $state->{app_env_prefix} = undef;
    local $state->{manifest}{app} = { name => '---' };
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_env_prefix(), 'APP', 'environment prefix falls back to APP when normalized app identity has no letters' );
}
{
    local $state->{app_env_prefix} = undef;
    local $state->{manifest}{app} = { command => '9' };
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_env_prefix(), 'APP', 'a numeric-only command name uses the safe generic prefix' );
}
{
    local $state->{app_env_prefix} = undef;
    local $state->{manifest}{app} = { name => '  ' };
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_env_prefix(), 'APP', 'blank identity with no command uses the app fallback prefix' );
}

{
    local $ENV{FIRST_COMMAND} = 'first-choice';
    local $ENV{FRIENDLY_APP_COMMAND} = 'prefix-choice';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_command_name( env_names => [ undef, '', 'MISSING_COMMAND', 'FIRST_COMMAND' ] ), 'first-choice', 'command resolution skips empty and unset environment names, then uses the first populated name' );
}
{
    local $ENV{FRIENDLY_APP_COMMAND} = 'prefix-choice';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_command_name(), 'prefix-choice', 'command resolution uses the app-prefixed environment variable' );
}
{
    local $state->{manifest}{app} = { command => 'manifest-command' };
    local $ENV{FRIENDLY_APP_COMMAND};
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_command_name(), 'manifest-command', 'command resolution falls back to manifest command' );
}
{
    local $state->{manifest}{app} = { entrypoint_command => 'entrypoint-command' };
    local $ENV{FRIENDLY_APP_COMMAND};
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_command_name(), 'entrypoint-command', 'command resolution falls back to entrypoint command' );
}
{
    local $state->{manifest}{app} = {};
    local $ENV{FRIENDLY_APP_COMMAND};
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_command_name(), 'pax', 'command resolution uses pax when the manifest has no command' );
}

{
    local $ENV{SUB_ENTRY} = 'sub-entry';
    local $ENV{MANIFEST_ENTRY} = '';
    local $ENV{FRIENDLY_APP_COMMAND} = 'prefix-entry';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command( sub_env => 'SUB_ENTRY' ), 'sub-entry', 'entry command gives an explicit subcommand environment variable first priority' );
}
{
    local $ENV{MANIFEST_ENTRY} = 'manifest-entry';
    local $ENV{FRIENDLY_APP_COMMAND} = 'prefix-entry';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command( sub_env => 'SUB_ENTRY' ), 'manifest-entry', 'entry command falls back to the manifest-selected environment variable' );
}
{
    local $ENV{MANIFEST_ENTRY} = '';
    local $ENV{FRIENDLY_APP_COMMAND} = 'prefix-entry';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command( sub_env => 'MANIFEST_ENTRY' ), 'prefix-entry', 'entry command avoids reading the same selected and fallback environment variable twice' );
}
{
    local $ENV{MANIFEST_ENTRY};
    local $ENV{FRIENDLY_APP_COMMAND} = 'prefix-entry';
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command(), 'prefix-entry', 'entry command checks the app-prefixed command environment variable' );
}
{
    local $state->{manifest}{app} = { entrypoint_fallback => 'manifest-fallback' };
    local $ENV{MANIFEST_ENTRY};
    local $ENV{FRIENDLY_APP_COMMAND};
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command( sub_fallback => 'sub-fallback' ), 'sub-fallback', 'explicit subcommand fallback takes precedence over manifest fallback' );
}
{
    local $state->{manifest}{app} = { entrypoint_fallback => 'manifest-fallback' };
    local $ENV{MANIFEST_ENTRY};
    local $ENV{FRIENDLY_APP_COMMAND};
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command( sub_fallback => '' ), 'manifest-fallback', 'empty subcommand fallback uses manifest entrypoint fallback' );
}
{
    local $state->{manifest}{app} = { command => 'manifest-command' };
    local $ENV{MANIFEST_ENTRY};
    local $ENV{FRIENDLY_APP_COMMAND};
    is( Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command(), 'manifest-command', 'entry command falls back to app command after entrypoint fallback is absent' );
}
{
    local $state->{manifest}{app} = {};
    local $ENV{MANIFEST_ENTRY};
    local $ENV{FRIENDLY_APP_COMMAND};
    my $entry_command;
    {
        local $SIG{__WARN__} = sub { die "Unexpected warning: @_" };
        $entry_command = Developer::Dashboard::Pax::StandaloneRuntime::_app_entry_command();
    }
    is( $entry_command, 'pax', 'entry command defaults to pax without warnings when all configured values are absent' );
}

done_testing();

__END__

=head1 NAME

t/260-pax-standalone-command-resolution.t - tests standalone command naming and environment resolution

=head1 PURPOSE

This test exercises the standalone runtime's application environment-prefix,
command-name, and entrypoint-command resolution rules against a temporary
manifest and controlled environment variables.

=head1 WHY IT EXISTS

These helpers define the executable identity and precedence rules embedded in
standalone PAX artifacts. Testing their fallback combinations directly prevents
runtime command selection from drifting between compiled and source execution.

=head1 WHEN TO USE

Run this test after changes to app metadata normalization, command environment
variables, manifest fallbacks, or standalone entrypoint dispatch.

=head1 HOW TO USE

Run C<prove -lv t/260-pax-standalone-command-resolution.t> from the repository
root using the project's Docker development service.

=head1 WHAT USES IT

C<Developer::Dashboard::Pax::StandaloneRuntime> uses these private helpers when
selecting application and subcommand identities for a standalone executable.

=head1 EXAMPLES

Example 1: the test verifies that C<APP_COMMAND> can override a command stored in
the manifest.

Example 2: the test verifies that an explicit subcommand environment variable
precedes app-wide entrypoint metadata.

=cut
