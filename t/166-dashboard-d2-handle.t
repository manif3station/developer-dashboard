#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec ();
use Cwd qw(abs_path getcwd);
use Scalar::Util qw(refaddr);
use Capture::Tiny qw(capture);

use lib 'lib';

use Developer::Dashboard;
use Developer::Dashboard::Handle;
use Developer::Dashboard::CLI::Paths ();
use Developer::Dashboard::PathRegistry;

# Warnings are fatal in this repository: collect any that escape and assert
# the whole run stayed clean.
my @warnings;
$SIG{__WARN__} = sub { push @warnings, $_[0]; return; };

# Hermetic runtime rooted at a temp home. The config root resolves from the
# deepest .developer-dashboard layer above the cwd, so chdir into the temp
# home before building any registry or exercising d2().
my $home = abs_path( tempdir( CLEANUP => 1 ) );
local $ENV{HOME}                           = $home;
local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = tempdir( CLEANUP => 1 );
my $starting_cwd = getcwd();
chdir $home or die "Unable to chdir to $home: $!";

# AC-1: a built-in alias (one PathRegistry answers with a method of the same
# name) resolves the same way through d2->paths as through resolve_dir
# directly.
{
    my $direct = Developer::Dashboard::PathRegistry->new( home => $home, cwd => $home );
    is( d2->paths->{home}, $direct->home, 'AC-1: d2->paths->{home} matches PathRegistry->home directly' );
}

# AC-2: a custom alias added the same way `dashboard path add` does (through
# the real CLI dispatch, so it is genuinely persisted, not a stub) is
# resolvable through d2->paths too.
{
    my ($stdout) = capture {
        Developer::Dashboard::CLI::Paths::run_paths_command(
            command => 'path',
            args    => [ 'add', 'reports', '/var/reports-example' ],
        );
    };

    # A fresh handle for a fresh cwd (still $home) must see the alias just
    # persisted - proves d2->paths reads real configured aliases, not a
    # frozen snapshot from before the alias existed.
    my $fresh = Developer::Dashboard::Handle->new( cwd => $home );
    is( $fresh->paths->{reports}, '/var/reports-example',
        'AC-2: a custom alias added via the real path-add command resolves through Handle->paths' );
}

# AC-3: d2() memoizes one handle per working directory - repeated calls from
# the same cwd return the identical object, not a rebuilt one.
{
    my $first  = d2();
    my $second = d2();
    is( refaddr($first), refaddr($second), 'AC-3: d2() returns the same handle object for the same cwd' );
}

# AC-4: accessing a missing alias is a normal hash miss - undef, never a die.
{
    my $missing = eval { d2->paths->{'this-alias-does-not-exist'} };
    is( $@, '', 'AC-4: looking up a missing alias does not die' );
    is( $missing, undef, 'AC-4: and it is undef, exactly like a normal hash miss' );
}

# AC-5/AC-8: a bareword single-word method (AUTOLOAD) shells to the real
# `dashboard <name>` and a nonzero exit dies with stderr attached, rather
# than silently returning as if it had succeeded.
{
    # REWRITTEN FOR Q-101. This used to assert that a bareword call shells out
    # IMMEDIATELY and dies on a nonzero exit. The owner superseded that - "a bare
    # d2->doctor becomes lazy like any other chain ... a shipped one-word form
    # changes meaning" - so building the chain no longer executes and no longer
    # dies. The die-on-nonzero-exit contract is UNCHANGED; it moves to the
    # terminator, which is what is asserted here.
    my $handle = Developer::Dashboard::Handle->new( cwd => $home );
    my $built = eval { $handle->doesnotexistasarealdashboardsubcommand; 1 };
    ok( $built, 'Q-101: building a chain for an unknown subcommand does NOT die - nothing has run yet' );

    my $ran = eval { $handle->doesnotexistasarealdashboardsubcommand->(); 1 };
    ok( !$ran, 'AC-5/AC-8: TERMINATING it fails rather than silently succeeding' );
    like( $@, qr/failed \(exit \d+\)/, 'and the die message names the exit code' );
}

# AC-6/AC-7: Handle->run() drives an arbitrary "dashboard"-named executable
# on PATH (stubbed here so the test does not depend on the real CLI's own
# subcommand set), decoding JSON-shaped stdout and passing through plain
# text, to isolate the run()/AUTOLOAD contract from the real CLI's behavior.
{
    my $bin_dir = tempdir( CLEANUP => 1 );
    my $stub    = File::Spec->catfile( $bin_dir, 'dashboard' );
    open my $fh, '>', $stub or die $!;
    print {$fh} <<'STUB';
#!/bin/sh
case "$1" in
  json-thing) echo '{"alpha":"beta"}' ;;
  text-thing) echo 'plain text output' ;;
  fail-thing) echo 'stub failure detail' 1>&2; exit 7 ;;
esac
STUB
    close $fh;
    chmod 0755, $stub;
    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    my $handle = Developer::Dashboard::Handle->new( cwd => $home );

    my $decoded = $handle->run('json-thing');
    is_deeply( $decoded, { alpha => 'beta' }, 'AC-6/AC-7: JSON-shaped stdout decodes to a Perl structure' );

    my $text = $handle->run('text-thing');
    is( $text, 'plain text output', 'AC-7: non-JSON stdout passes through as trimmed text' );

    # Also exercised via the AUTOLOAD path, per AC-5's "single-word method"
    # contract - same stub, different call shape.
    # REWRITTEN FOR Q-101: a bareword call now returns a proxy, so the value
    # appears only once the chain is terminated. The mapping being asserted -
    # method name verbatim, underscore not hyphen - is unchanged.
    my $via_autoload = $handle->text_thing->();    # AUTOLOAD -> proxy -> run('text_thing')
    ok( !defined($via_autoload) || $via_autoload eq '',
        'AUTOLOAD maps the METHOD name verbatim (underscore, not the hyphenated CLI form) - no matching stub case, so empty/undef, not a die' );

    my $failed = eval { $handle->run('fail-thing'); 1 };
    ok( !$failed, 'AC-8: a nonzero exit dies' );
    like( $@, qr/stub failure detail/, 'AC-8: and stderr is attached to the die message' );
}

# Coverage: new() with no explicit cwd falls back to Cwd::cwd() - exercises
# the "defined-or fell through" leg that every other test in this file
# avoids by always passing cwd explicitly.
{
    my $handle = Developer::Dashboard::Handle->new;
    is( $handle->{cwd}, getcwd(), 'new() with no cwd falls back to Cwd::cwd()' );
}

# Coverage: run() validates its own subcommand argument - both the "missing
# entirely" and "present but empty" shapes of the guard.
{
    my $handle = Developer::Dashboard::Handle->new( cwd => $home );

    my $ok_undef = eval { $handle->run(undef); 1 };
    ok( !$ok_undef, 'run() with no subcommand dies' );
    like( $@, qr/Missing subcommand/, 'and names the reason' );

    my $ok_empty = eval { $handle->run(''); 1 };
    ok( !$ok_empty, 'run() with an empty-string subcommand dies the same way' );
    like( $@, qr/Missing subcommand/, 'and names the reason' );
}

# Coverage: calling ->paths (and so ->_registry) twice on the SAME handle
# exercises the memoization hit inside _registry's own cache, not just
# paths()'s cache above it.
{
    my $handle = Developer::Dashboard::Handle->new( cwd => $home );
    my $first  = $handle->_registry;
    my $second = $handle->_registry;
    is( refaddr($first), refaddr($second), '_registry() memoizes per handle, not just paths()' );
}

# Coverage: JSON-shaped stdout that decodes successfully but to a non-
# reference scalar (a bare JSON number) must still pass through as text,
# not be mistaken for the decoded-structure case.
{
    my $bin_dir = tempdir( CLEANUP => 1 );
    my $stub    = File::Spec->catfile( $bin_dir, 'dashboard' );
    open my $fh, '>', $stub or die $!;
    print {$fh} <<'STUB';
#!/bin/sh
case "$1" in
  number-thing) echo '42' ;;
esac
STUB
    close $fh;
    chmod 0755, $stub;
    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    my $handle = Developer::Dashboard::Handle->new( cwd => $home );
    my $result = $handle->run('number-thing');
    is( $result, '42', 'a JSON number decodes successfully but is not a ref, so it passes through as text' );
}

# Coverage: with no home directory resolvable at all (HOME and every
# Windows-style fallback var absent), _registry's own PathRegistry
# construction has nothing to fall back to and dies - exercising the
# $ENV{HOME} empty leg inside _registry.
{
    local $ENV{HOME} = '';
    local $ENV{USERPROFILE};
    local $ENV{HOMEDRIVE};
    local $ENV{HOMEPATH};
    delete $ENV{USERPROFILE};
    delete $ENV{HOMEDRIVE};
    delete $ENV{HOMEPATH};

    my $handle = Developer::Dashboard::Handle->new( cwd => $home );
    my $ok = eval { $handle->paths; 1 };
    ok( !$ok, 'with no resolvable home directory anywhere, paths() dies rather than silently using a wrong root' );
}

chdir $starting_cwd or die "Unable to chdir back to $starting_cwd: $!";

is( scalar(@warnings), 0, 'no warnings escaped: ' . join( '; ', @warnings ) );


# ---------------------------------------------------------------------------
# DD-738: d2() chaining. RED until the proxy exists.
#
# Design settled by the owner across four questions, and the spec asserts the
# SETTLED shape rather than the one this card was filed with:
#   Q-096  proxy-object chaining, arbitrary depth, mirroring dotted CLI dispatch
#   Q-100  ONLY an explicit terminator executes; boolean, numeric and
#          interpolated context are all inert; an un-terminated proxy
#          stringifies to something obviously non-executing
#   Q-101  supersedes the original AC-3: a bare single-word call is a proxy too,
#          with no depth-1 special case
#   Q-104  the terminator is a CALL - d2()->collector->list->() - overloading
#          &{}, chosen because it reserves no word and so cannot collide with a
#          subcommand, which matters when the CLI dispatches arbitrary dotted
#          names including installed skills.
#
# The stub RECORDS ITS ARGV to a file. Inertness is then asserted by an EMPTY
# LOG rather than by the absence of output - a test that checks "nothing was
# printed" passes just as well when the command ran and printed nothing.
# ---------------------------------------------------------------------------
{
    my $bin_dir = tempdir( CLEANUP => 1 );
    my $log     = File::Spec->catfile( $bin_dir, 'invocations' );
    my $stub    = File::Spec->catfile( $bin_dir, 'dashboard' );
    open my $sfh, '>', $stub or die "Unable to write $stub: $!";
    print {$sfh} <<"STUB";
#!/bin/sh
printf '%s\\n' "\$*" >> '$log'
echo 'stub-ran'
STUB
    close $sfh or die "Unable to close $stub: $!";
    chmod 0755, $stub or die "Unable to chmod $stub: $!";
    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    # purpose: report every argv the stub has been invoked with since the last reset.
    # input: none. output: list of argv strings, oldest first.
    my $invocations = sub {
        return () if !-e $log;
        open my $lfh, '<', $log or die "Unable to read $log: $!";
        my @lines = <$lfh>;
        close $lfh or die "Unable to close $log: $!";
        chomp @lines;
        return @lines;
    };
    # purpose: forget every recorded invocation, so the next assertion speaks
    #          only about what happened after it. input/output: none.
    my $reset = sub { unlink $log if -e $log; return; };

    my $handle = Developer::Dashboard::Handle->new( cwd => $home );

    # AC-1 ARBITRARY DEPTH. Depths 2, 3 and 4 - a fix handling one extra word
    # is a special case, and the owner asked for the general form.
    for my $case ( [ [qw(collector list)], 'collector.list' ],
                   [ [qw(foo bar zzz)],   'foo.bar.zzz' ],
                   [ [qw(foo bar zzz yyy)], 'foo.bar.zzz.yyy' ] ) {
        my ( $words, $dotted ) = @{$case};
        $reset->();
        # eval so a die at the first chained call does not hide the eight
        # assertions after it - a RED spec that stops at its first failure
        # tells you one thing when it could tell you the whole shape.
        eval {
            my $proxy = $handle;
            $proxy = $proxy->$_ for @{$words};
            $proxy->();
            1;
        };
        is_deeply( [ $invocations->() ], [$dotted],
            "AC-1: d2()->" . join( '->', @{$words} ) . "->() invokes exactly `dashboard $dotted`" );
    }

    # AC-2 NO ACCIDENTAL EXECUTION. Each context is exercised against a proxy
    # that is never terminated, and the log must stay EMPTY.
    {
        $reset->();
        eval { my $proxy = $handle->collector->list; my $t = $proxy ? 1 : 0; 1 };
        is_deeply( [ $invocations->() ], [], 'AC-2: boolean context does not execute' );

        $reset->();
        eval { my $p2 = $handle->collector->list; my $n = 0 + $p2; 1 };
        is_deeply( [ $invocations->() ], [], 'AC-2: numeric context does not execute' );

        $reset->();
        my $p3 = eval { $handle->collector->list };
        eval { my $str = "interpolated: $p3"; 1 };
        is_deeply( [ $invocations->() ], [], 'AC-2: interpolation does not execute' );

        # AC-7 (Q-100): and the string it interpolates to must be obviously
        # non-executing. Asserted as TEXT, not merely as "did not execute" -
        # Perl autogenerates a missing stringify from numify, so a silently
        # generated form would satisfy a weaker assertion.
        is( ( defined $p3 ? "$p3" : '(the chain died)' ), 'd2 proxy: collector.list',
            'AC-7: an un-terminated proxy stringifies to "d2 proxy: collector.list"' );
    }

    # AC-3 SUPERSEDED BY Q-101: a bare single-word call is a proxy like any
    # other chain, with no depth-1 special case.
    {
        $reset->();
        my $one = eval { $handle->doctor };
        is_deeply( [ $invocations->() ], [], 'Q-101: a bare single-word call does NOT execute' );
        is( ( defined $one ? "$one" : '(undef)' ), 'd2 proxy: doctor',
            'Q-101: and stringifies as a proxy at depth 1 too' );
        $reset->();
        eval { $one->(); 1 };
        is_deeply( [ $invocations->() ], ['doctor'], 'Q-101: terminating it invokes `dashboard doctor`' );
    }

    # AC-4 run() UNCHANGED - the documented bypass other code depends on.
    {
        $reset->();
        my $out = $handle->run( 'collector', 'list' );
        is_deeply( [ $invocations->() ], ['collector list'],
            'AC-4: run() still passes its words as SEPARATE argv, not dotted' );
        is( $out, 'stub-ran', 'AC-4: and still returns the trimmed stdout' );
    }

    # AC-6 HOOKS STILL RUN. Not asserted directly - a hook test would need a
    # real layered runtime - but asserted by its MECHANISM, which is the thing a
    # refactor could actually lose. Layered pre-run hooks execute because
    # Handle::run shells out through the real `dashboard` entrypoint; anything
    # that reaches the CLI that way gets them for free. So what has to hold is
    # that the proxy terminator goes through run() and inherits its WHOLE
    # contract, rather than growing its own system() call that would bypass the
    # entrypoint and silently lose hooks with every test still green.
    #
    # Two properties only run() provides are asserted here. If a refactor made
    # _execute shell out directly, both would break loudly.
    {
        my $json_dir = tempdir( CLEANUP => 1 );
        my $js = File::Spec->catfile( $json_dir, 'dashboard' );
        open my $jfh, '>', $js or die "Unable to write $js: $!";
        print {$jfh} <<'JSTUB';
#!/bin/sh
case "$1" in
  deep.json) echo '{"via":"proxy"}' ;;
  deep.fail) echo 'proxy failure detail' 1>&2; exit 9 ;;
esac
JSTUB
        close $jfh or die "Unable to close $js: $!";
        chmod 0755, $js or die "Unable to chmod $js: $!";
        local $ENV{PATH} = "$json_dir:$ENV{PATH}";
        my $h = Developer::Dashboard::Handle->new( cwd => $home );

        is_deeply( $h->deep->json->(), { via => 'proxy' },
            'AC-6: the terminator inherits run() JSON decoding - so it reaches the real entrypoint, which is what makes layered hooks run' );

        my $died = eval { $h->deep->fail->(); 1 };
        ok( !$died, 'AC-6: and inherits run() die-on-nonzero-exit' );
        like( $@, qr/proxy failure detail/, 'AC-6: with stderr attached, exactly as run() does' );
    }

    # AC-5 DESTROY STILL GUARDED: a proxy that goes out of scope un-terminated
    # invokes nothing. Without the guard, DESTROY is just another bareword.
    {
        $reset->();
        eval { my $doomed = $handle->collector->list; 1 };
        is_deeply( [ $invocations->() ], [],
            'AC-5: a proxy going out of scope un-terminated invokes nothing' );
    }
}

done_testing;

__END__

=head1 NAME

t/166-dashboard-d2-handle.t - spec for the exported d2() Perl-code proxy

=head1 PURPOSE

Assert that C<d2()>, exported by L<Developer::Dashboard>, gives Perl code a
one-line equivalent of the C<dashboard>/C<d2> command line, both for the
fast in-process path-alias case and for the general subcommand proxy.

=head1 WHY IT EXISTS

DD-726: the project owner asked directly (over the project's Telegram
bridge) for C<< d2->paths->{foo} >> instead of hand-building a
PathRegistry/FileRegistry/Config, then widened the request to "anything I
can run with d2 on bash" - so both the fast path-alias accessor and the
general subcommand proxy (C<run()>/C<AUTOLOAD>) need their own coverage.

=head1 WHEN TO USE

Whenever C<Developer::Dashboard::d2>, C<Developer::Dashboard::Handle::paths>,
or C<Developer::Dashboard::Handle::run>/C<AUTOLOAD> changes.

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/166-dashboard-d2-handle.t

=head1 WHAT USES IT

Nothing in the shipped CLI itself uses C<d2()> - it is a convenience
entrypoint for external Perl code embedding this distribution.

=head1 EXAMPLES

The assertion that matters reads as the property it protects:

    d2->paths->{name} matches what `dashboard path resolve name` prints

=cut
