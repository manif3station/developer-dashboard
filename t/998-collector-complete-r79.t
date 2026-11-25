#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';

use Developer::Dashboard::Collector;
use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::CLI::Complete;

# Hermetic runtime: private HOME, isolated state root, and a chdir into the temp
# tree so the DD-OOP-LAYERS config root resolves from this fixture only and never
# from the developer's real ~/.developer-dashboard layers. Same pattern as t/120.
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME}                           = $home;
local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = tempdir( CLEANUP => 1 );
chdir $home or die "Unable to chdir to $home: $!";

make_path( File::Spec->catdir( $home, 'projects' ) );

my $paths     = Developer::Dashboard::PathRegistry->new( home => $home );
my $files     = Developer::Dashboard::FileRegistry->new( paths => $paths );
my $config    = Developer::Dashboard::Config->new( files => $files, paths => $paths );
my $collector = Developer::Dashboard::Collector->new( paths => $paths );

# --- Fixture: two collector names from the two sources completion reads ---
#
# The example collector is configured (the t/120 pattern: save_global with a
# collectors list - there is no CLI way to define a collector), and the
# housekeeper reaches completion through a persisted status record, the way
# the built-in collector does after it has run once. Together they are the
# two names every AC 8 check below expects.
$config->save_global(
    {
        collectors => [
            { name => 'example', command => 'echo example-ok' },
        ],
    }
);

{
    my $status_file = $collector->collector_paths('housekeeper')->{status};
    open my $fh, '>:raw', $status_file or die "Unable to write $status_file: $!";
    print {$fh} q({"name":"housekeeper"});
    close $fh or die "Unable to close $status_file: $!";
}

# Pin the fixture first: both names reach the completion helper, one from
# each source. If this fails, the checks below are testing an empty room.
{
    my @names = Developer::Dashboard::CLI::Complete::_collector_names();
    is( scalar @names, 2, 'collector completion sees exactly the two fixture collectors' );
    ok( ( grep { $_ eq 'example' } @names ), 'collector completion sees the configured example collector' );
    ok( ( grep { $_ eq 'housekeeper' } @names ), 'collector completion sees the persisted housekeeper collector' );
}

# R79 AC 8, in-process: after `d2 collector <action>` the completion
# candidates are collector names. Today the call falls through to the
# subcommand list, so the names are missing and these fail.
for my $action ( qw(run log start stop restart) ) {
    my @candidates = Developer::Dashboard::CLI::Complete::complete(
        words => [ 'd2', 'collector', $action ],
        index => 3,
    );
    ok( ( grep { $_ eq 'housekeeper' } @candidates ),
        "collector: complete d2 collector $action offers the housekeeper name" );
    ok( ( grep { $_ eq 'example' } @candidates ),
        "collector: complete d2 collector $action offers the example name" );
}

# R79 AC 8, in-process prefix filtering: a partial name offers only the
# collector whose name starts with it. Today the subcommand list is
# offered instead, so the partial name matches nothing.
{
    my @candidates = Developer::Dashboard::CLI::Complete::complete(
        words => [ 'd2', 'collector', 'run', 'hou' ],
        index => 3,
    );
    is_deeply(
        \@candidates,
        ['housekeeper'],
        'collector: complete d2 collector run hou offers only the housekeeper name',
    );

    @candidates = Developer::Dashboard::CLI::Complete::complete(
        words => [ 'd2', 'collector', 'run', 'exa' ],
        index => 3,
    );
    is_deeply(
        \@candidates,
        ['example'],
        'collector: complete d2 collector run exa offers only the example name',
    );
}

# R79 AC 6 and AC 8, in-process: after `d2 restart/stop/log/logs
# collector` the collector names are no longer offered. They are offered
# today, so these fail until the verb-first branches are removed.
for my $verb ( qw(restart stop log logs) ) {
    my @candidates = Developer::Dashboard::CLI::Complete::complete(
        words => [ 'd2', $verb, 'collector' ],
        index => 3,
    );
    ok( !( grep { $_ eq 'housekeeper' } @candidates ),
        "collector: complete d2 $verb collector no longer offers the housekeeper name" );
    ok( !( grep { $_ eq 'example' } @candidates ),
        "collector: complete d2 $verb collector no longer offers the example name" );
}

done_testing;

__END__

=pod

=head1 NAME

t/998-collector-complete-r79.t - in-process completion tests for the R79 collector form

=head1 PURPOSE

This test pins the AC 8 completion behaviour for the R79 collector
follow-up at the unit level, calling
C<Developer::Dashboard::CLI::Complete::complete> directly the way t/120
does: after C<d2 collector run|log|start|stop|restart> the candidates are
collector names, a partial name offers only the collector it prefixes, and
after C<d2 restart|stop|log|logs collector> the collector names are no
longer offered. It is the in-process companion to the t/997 smoke tests,
which exercise the same behaviour through the CLI.

=head1 WHY IT EXISTS

The smoke tests prove the behaviour end to end; this file proves the
completion branches themselves, without a subprocess, so a regression in
the branch dispatch fails here first with the exact words and index that
triggered it. The fixture mirrors reality: the example collector is
configured (there is no CLI way to define one) and the housekeeper reaches
completion through a persisted status record, the way the built-in
collector does after it has run once.

=head1 WHEN TO USE

Use this file when changing how completion dispatches collector names, when
changing the verb-first completion branches, or when changing how
C<_collector_names> collects configured and persisted names. Revisit it if
the completion helper starts accepting an injected config object directly,
because the fixture setup here would then be replaced by a plain argument.

=head1 HOW TO USE

Run C<prove -lv t/998-collector-complete-r79.t> from the repository root
while iterating, and keep it green under C<prove -lr t> plus the Devel::Cover
gate before release. The fixture sets a private C<HOME>, an isolated state
root, and chdirs into the temp tree first, so config and collector lookups
only ever touch the temporary layer.

=head1 WHAT USES IT

The full repository suite runs it as a regression, and developers changing
collector completion use it as the fast feedback loop alongside the wider
completion coverage tests and the t/997 smoke tests.

=cut
