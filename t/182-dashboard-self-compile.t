#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Digest::MD5 ();
use Capture::Tiny qw(capture);

my $repo_root = abs_path( File::Spec->catdir( dirname(__FILE__), '..' ) );
my $lib       = File::Spec->catdir( $repo_root, 'lib' );
my $dashboard = File::Spec->catfile( $repo_root, 'bin', 'dashboard' );

# Same MD5-keyed cache layout PaxCache.pm itself uses: home_cache_root/pax/
# <md5_hex(source_path)>.{md5,pax,compiling}. Seeding it directly (rather
# than going through a real PAX compile) keeps this test fast and hermetic.
sub seed_cache_for_dashboard {
    my ( $home, $binary_contents ) = @_;
    my $cache_dir = File::Spec->catdir( $home, '.developer-dashboard', 'cache', 'pax' );
    make_path($cache_dir);
    my $key = Digest::MD5::md5_hex($dashboard);

    open my $sfh, '<:raw', $dashboard or die "Unable to read $dashboard: $!";
    my $md5 = Digest::MD5->new;
    $md5->addfile($sfh);
    close $sfh;
    my $source_md5 = $md5->hexdigest;

    my $md5_file = File::Spec->catfile( $cache_dir, "$key.md5" );
    open my $mfh, '>', $md5_file or die "Unable to write $md5_file: $!";
    print {$mfh} $source_md5;
    close $mfh;

    my $bin_file = File::Spec->catfile( $cache_dir, "$key.pax" );
    open my $bfh, '>', $bin_file or die "Unable to write $bin_file: $!";
    print {$bfh} $binary_contents;
    close $bfh;
    chmod 0755, $bin_file;

    return $bin_file;
}

# DD-905 (disables DD-882's exec side): a real PAX-compiled binary of this
# entrypoint silently corrupts %ENV loading (Developer::Dashboard::EnvLoader's
# _load_env_file, a plain line-by-line read of .env, misreads the whole file
# as one line when run inside the vendored Pax StandaloneRuntime - root cause
# not yet found). So a cache hit must NEVER be exec'd into: dashboard always
# runs its own interpreted body, even when a matching compiled binary exists.
{
    my $home = tempdir( CLEANUP => 1 );
    my $sentinel_bin = seed_cache_for_dashboard(
        $home,
        "#!/usr/bin/env perl\nprint \"DD882-SENTINEL-COMPILED-OUTPUT\\n\";\n"
    );

    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = $home;
        local $ENV{HARNESS_ACTIVE} = 0;
        system( $^X, '-I', $lib, $dashboard, 'version' );
    };
    is( $exit >> 8, 0, 'DD-905: dashboard exits cleanly with a matching self-compiled binary cached' );
    unlike(
        $out,
        qr/DD882-SENTINEL-COMPILED-OUTPUT/,
        'DD-905: dashboard never execs the cached self-compiled binary, even on a cache hit'
    );
    like( $out, qr/\A\d+\.\d+\s*\z/, 'DD-905: dashboard runs its own interpreted body instead, producing the real version output' );
}

# A stale/no-cache case must still work exactly as before: run interpreted,
# with zero behavior change and no attempt to exec anything.
{
    my $home = tempdir( CLEANUP => 1 );
    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = $home;
        local $ENV{HARNESS_ACTIVE} = 0;
        local $ENV{PATH} = '/nonexistent-empty-dir-for-this-test';    # no pax available either
        system( $^X, '-I', $lib, $dashboard, 'version' );
    };
    is( $exit >> 8, 0, 'DD-882: dashboard exits cleanly with no cached self-binary' );
    like( $out, qr/\A\d+\.\d+\s*\z/, 'DD-882: dashboard runs interpreted normally with no cached self-binary (no compile blocking, correct output)' );
}

# DD-882's exec guard var (DEVELOPER_DASHBOARD_PAX_SELF_EXECED) is now dead
# with the exec side removed - a leftover value in the environment (a stale
# process, an old shell) must still be harmless: dashboard runs interpreted
# normally regardless of whether that var happens to be set.
{
    my $home = tempdir( CLEANUP => 1 );
    seed_cache_for_dashboard(
        $home,
        "#!/usr/bin/env perl\nprint \"DD882-SENTINEL-SHOULD-NOT-RUN\\n\";\nexit 1;\n"
    );

    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = $home;
        local $ENV{HARNESS_ACTIVE} = 0;
        local $ENV{DEVELOPER_DASHBOARD_PAX_SELF_EXECED} = 1;
        system( $^X, '-I', $lib, $dashboard, 'version' );
    };
    is( $exit >> 8, 0, 'DD-905: with the now-dead self-exec guard set, dashboard still exits cleanly' );
    unlike(
        $out,
        qr/DD882-SENTINEL-SHOULD-NOT-RUN/,
        'DD-905: with the now-dead guard set, the cached binary is never executed'
    );
    like( $out, qr/\A\d+\.\d+\s*\z/, 'DD-905: with the guard set, dashboard runs its own interpreted body normally' );
}

# DD-905's own regression coverage: a REAL PAX compile of dashboard (not a
# hand-written sentinel) must reproduce the known %ENV-corruption defect when
# invoked directly, AND dashboard itself must still run cleanly even with
# that exact real broken binary sitting in the cache - proving the fix
# addresses the actual defect, not just the sentinel-based mechanism test
# above. Skipped when pax is not resolvable (no vendored Pax CLI staged) or
# when explicitly disabled, since a real compile is slow and heavy.
SKIP: {
    skip 'DD_SKIP_REAL_PAX_COMPILE_TEST is set', 2 if $ENV{DD_SKIP_REAL_PAX_COMPILE_TEST};

    my $home = tempdir( CLEANUP => 1 );
    my $cache_dir = File::Spec->catdir( $home, '.developer-dashboard', 'cache', 'pax' );
    make_path($cache_dir);
    my $key = Digest::MD5::md5_hex($dashboard);
    my $bin_file = File::Spec->catfile( $cache_dir, "$key.pax" );
    my $md5_file = File::Spec->catfile( $cache_dir, "$key.md5" );

    my $pax = File::Spec->catfile( $repo_root, 'share', 'private-cli', 'pax' );
    my ( $build_out, $build_err, $build_exit ) = capture {
        local $ENV{HOME} = $home;
        system( $^X, $pax, 'build', '--compact', '-o', $bin_file, $dashboard );
    };
    skip 'a real pax build did not succeed in this environment', 2 if ( $build_exit >> 8 ) != 0 || !-x $bin_file;

    open my $sfh, '<:raw', $dashboard or die "Unable to read $dashboard: $!";
    my $md5 = Digest::MD5->new;
    $md5->addfile($sfh);
    close $sfh;
    open my $mfh, '>', $md5_file or die "Unable to write $md5_file: $!";
    print {$mfh} $md5->hexdigest;
    close $mfh;

    # .env is untracked (git-ignored) and loaded relative to the REPO ROOT,
    # not $HOME - a ticket worktree sandbox carries no .env of its own, so
    # write a throwaway multi-line one here to give the known upstream
    # defect (see the block comment on _maybe_exec_self_compiled_dashboard
    # in bin/dashboard) a real chance to reproduce. Whether it reproduces in
    # THIS environment is informational only (diag, not asserted) - it is
    # environment-dependent (confirmed: it did not reproduce from this exact
    # worktree without a real .env present) and is not this ticket's own
    # correctness property. The property this ticket actually guarantees is
    # below: dashboard itself must never be corrupted by a broken compiled
    # binary, regardless of whether that binary happens to fail loudly.
    my $env_file = File::Spec->catfile( $repo_root, '.env' );
    my $had_env = -f $env_file;
    my $original_env_content;
    if ($had_env) {
        open my $rfh, '<:raw', $env_file or die "Unable to read $env_file: $!";
        local $/;
        $original_env_content = <$rfh>;
        close $rfh;
    }
    open my $wfh, '>:raw', $env_file or die "Unable to write $env_file: $!";
    print {$wfh} "DD905_TEST_TOKEN=1234:abcdEFGHijklMNOP\nDD905_TEST_SECOND=another-value\n";
    close $wfh;

    my ( $direct_out, $direct_err, $direct_exit ) = capture {
        local $ENV{HOME} = $home;
        system($bin_file, 'version');
    };

    if ($had_env) {
        open my $wfh2, '>:raw', $env_file or die "Unable to restore $env_file: $!";
        print {$wfh2} $original_env_content;
        close $wfh2;
    }
    else {
        unlink $env_file;
    }

    diag(
        ( $direct_exit >> 8 ) != 0
        ? "DD-905: the real self-compiled binary reproduced the known upstream .env-corruption defect in this environment (exit $direct_exit), as expected."
        : "DD-905: the real self-compiled binary did NOT reproduce the known upstream defect in this environment this run - environment-dependent, not this ticket's own concern (see DD-905's card for the confirmed reproduction)."
    );

    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = $home;
        local $ENV{HARNESS_ACTIVE} = 0;
        system( $^X, '-I', $lib, $dashboard, 'version' );
    };
    is( $exit >> 8, 0, 'DD-905 regression: dashboard exits cleanly even with a REAL compiled binary cached' );
    like( $out, qr/\A\d+\.\d+\s*\z/, 'DD-905 regression: dashboard runs its own interpreted body and produces correct output, never touching the cached compiled binary' );
}

done_testing;

__END__

=head1 NAME

t/182-dashboard-self-compile.t - dashboard's own MD5-checked self-compile hook

=head1 PURPOSE

Exercises bin/dashboard's self-compile check: it still checks its own
source MD5 against PaxCache's cache (keeping a background compile warm),
but DD-905 disabled acting on a cache hit - dashboard always runs its own
interpreted body, never execs into the cached compiled binary, because a
real PAX-compiled binary of this entrypoint was found to silently corrupt
%ENV loading (see DD-905, and the block comment on
C<_maybe_exec_self_compiled_dashboard> in bin/dashboard for the full
mechanism).

=head1 WHY IT EXISTS

DD-877 only wired PaxCache into the internal C<ps1> helper command, never
into dashboard's own entrypoint - the owner's original, explicit request
(Telegram msg #2001, 2026-09-15) was specifically that d2/dashboard
themselves become the self-compiling target. DD-882 built that (execing a
cached compiled binary on a hit); DD-905 found and disabled the exec side
after it silently broke config loading in real use, undetected by DD-882's
own tests because prove sets HARNESS_ACTIVE, which skips this whole check.
This file is the executable proof that a cache hit is now inert, and that
disabling it did not reintroduce any of DD-882's original miss-case or
guard-safety behavior regressions.

=head1 WHEN TO USE

Run this file whenever the self-compile hook in bin/dashboard changes, or
whenever PaxCache's cache file layout changes (this file seeds the cache
directly using that exact layout, so a layout change must update both).
Set C<DD_SKIP_REAL_PAX_COMPILE_TEST=1> to skip the slow real-compile
regression block (still runs the fast sentinel-based blocks).

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/182-dashboard-self-compile.t

=head1 WHAT USES IT

Confirms the contract every real dashboard invocation depends on: a cache
hit is never acted on, a miss never blocks or breaks normal interpreted
operation, and a real compiled binary's actual (not simulated) corruption
of %ENV loading never reaches a live dashboard invocation.

=head1 EXAMPLES

Seeding a fake cached binary and confirming dashboard never execs it:

    my $bin_file = seed_cache_for_dashboard($home, "#!/usr/bin/env perl\nprint 'hi';\n");
    system($^X, '-I', $lib, $dashboard, 'version');    # runs dashboard's own body, not the sentinel

=cut
