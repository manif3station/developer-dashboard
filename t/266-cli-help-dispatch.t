#!/usr/bin/env perl

use strict;
use warnings;

use Capture::Tiny qw(capture);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use Developer::Dashboard::CLI::Help;

my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = File::Spec->catdir( $home, 'state' );
my $perl = $^X;
my $dashboard = File::Spec->catfile( File::Spec->curdir, 'bin', 'dashboard' );
my $lib = File::Spec->catdir( File::Spec->curdir, 'lib' );

sub run_cli {
    my (@args) = @_;
    my ( $stdout, $stderr, $exit ) = capture {
        system $perl, "-I$lib", $dashboard, @args;
        return $? >> 8;
    };
    return ( $stdout, $stderr, $exit );
}

for my $command ( Developer::Dashboard::CLI::Help::command_names() ) {
    my ( $stdout, $stderr, $exit ) = run_cli( $command, '--help' );
    is( $exit, 0, "$command --help exits successfully" );
    like( $stdout, qr/^Usage:\s+dashboard\s+\Q$command\E\b/m, "$command --help renders its own synopsis" );
    is( $stderr, '', "$command --help is free from parser errors" );
}

for my $alias ( sort keys %{ Developer::Dashboard::CLI::Help::aliases() } ) {
    my $canonical = Developer::Dashboard::CLI::Help::aliases()->{$alias};
    my ( $stdout, $stderr, $exit ) = run_cli( $alias, '--help' );
    is( $exit, 0, "$alias compatibility alias --help exits successfully" );
    like( $stdout, qr/^Usage:\s+dashboard\s+\Q$canonical\E\b/m, "$alias compatibility alias resolves canonical help" );
    is( $stderr, '', "$alias compatibility alias help has no parser errors" );
}

for my $namespace ( Developer::Dashboard::CLI::Help::command_names() ) {
    my @parent = split /\s+/, $namespace;
    for my $action ( Developer::Dashboard::CLI::Help::actions_for($namespace) ) {
        my @invocation = ( @parent, $action, '--help' );
        my $qualified = join ' ', @parent, $action;
        my ( $stdout, $stderr, $exit ) = run_cli( @invocation );
        is( $exit, 0, "$qualified --help exits successfully" );
        like( $stdout, qr/^Usage:\s+dashboard\s+\Q$qualified\E(?:\s|$)/m, "$qualified --help renders its own synopsis" );
        is( $stderr, '', "$qualified --help is free from parser errors" );
    }
}

for my $case (
    [ [ 'api', '--help' ],                     qr/^Usage: dashboard api/m, 'api --help' ],
    [ [ 'file', '--help' ],                    qr/^Usage: dashboard file/m, 'file --help' ],
    [ [ 'path', 'cdr', '--help' ],             qr/^Usage: dashboard path cdr/m, 'path cdr --help' ],
    [ [ 'docker', 'development', 'enable', '--help' ], qr/^Usage: dashboard docker development enable/m, 'nested Docker action --help' ],
    [ [ 'api', 'add', 'help' ],                qr/^Usage: dashboard api add/m, 'nested api add help' ],
    [ [ 'api', 'help', 'add' ],                qr/^Usage: dashboard api add/m, 'api help add' ],
    [ [ 'docker', 'help', 'development', 'enable' ], qr/^Usage: dashboard docker development enable/m, 'nested docker help action path' ],
    [ [ 'logs', 'web', '--help' ],              qr/^Usage: dashboard log web/m, 'logs alias action help' ],
    [ [ 'help', 'api', 'rm' ],                  qr/^Usage: dashboard api rm/m, 'dashboard help api rm' ],
    [ [ 'help', 'version' ],                     qr/^Usage: dashboard version/m, 'dashboard help version' ],
    [ [ 'help' ],                               qr/^Available built-in commands:/m, 'global dashboard help' ],
    [ [ 'jq', '-h' ],                           qr/^Usage: dashboard jq/m, 'direct query helper -h' ],
    [ [ 'ask', '--help' ],                      qr/^Usage: dashboard ask/m, 'ask --help remains supported' ],
) {
    my ( $args, $expected, $label ) = @{$case};
    my ( $stdout, $stderr, $exit ) = run_cli( @{$args} );
    is( $exit, 0, "$label exits successfully" );
    like( $stdout, $expected, "$label prints the matching synopsis to stdout" );
    is( $stderr, '', "$label does not emit an option-parser error" );
}

for my $entrypoint (
    [ ['help'], 'dashboard help' ],
    [ ['help', '--help'], 'dashboard help --help' ],
    [ ['--help'], 'dashboard --help' ],
    [ ['-h'], 'dashboard -h' ],
) {
    my ( $args, $label ) = @{$entrypoint};
    my ( $stdout, $stderr, $exit ) = run_cli( @{$args} );
    is( $exit, 0, "$label exits successfully" );
    like( $stdout, qr/^Available built-in commands:/m, "$label prints the concise command index" );
    like( $stdout, qr/^  dashboard api\b/m, "$label includes built-in command usage" );
    like( $stdout, qr/^  dashboard version\b/m, "$label includes the public version command" );
    cmp_ok( scalar( split /\n/, $stdout ), '<=', 100, "$label avoids dumping the full module POD" );
    is( $stderr, '', "$label emits no help errors" );
}

my ( $api_out ) = run_cli( 'api', '--help' );
like( $api_out, qr/--key/, 'API root help documents the implicit list key filter' );
like( $api_out, qr/--output/, 'API root help documents the implicit list output option' );
unlike( $api_out, qr/^Key\s+Secret\s+Route/m, 'API help does not continue into the API listing action' );
ok( !-e File::Spec->catfile( $home, '.developer-dashboard', 'config', 'api.json' ), 'help does not create or mutate the API registry' );
done_testing;

__END__

=pod

=head1 NAME

t/266-cli-help-dispatch.t - explicit built-in command help dispatch

=head1 PURPOSE

Verifies helper and direct-version help spellings reach the shared catalog
before command execution, including nested actions, the global help form, and
root API help for the implicit list action.

=head1 WHY IT EXISTS

Some internal commands treated C<--help> as ordinary input, printed an error,
or continued into a real operation. This regression ensures representative
commands return successful help output without touching their underlying data.

=head1 WHEN TO USE

Run this test when changing the public switchboard, private helper dispatch, or
command help routing.

=head1 HOW TO USE

  prove -lv t/266-cli-help-dispatch.t

The test uses a temporary HOME and captures each child process's output and
exit status; run it inside the isolated Docker development container.

=head1 WHAT USES IT

The repository test suite runs this test to protect helper roots, version,
nested actions, aliases, and global-help invocation paths.

=head1 EXAMPLES

  d2 docker compose --project-name problem25 run --rm --no-deps dev prove -lv t/266-cli-help-dispatch.t

Run the focused dispatch regression in Docker.

  d2 docker compose --project-name problem25 run --rm --no-deps dev prove -lr t

Re-run the suite after changing help dispatch behavior.

=cut
