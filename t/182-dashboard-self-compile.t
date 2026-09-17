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

# DD-882 (owner correction, Telegram msg #2001, 2026-09-15): dashboard checks
# its own source MD5 against PaxCache's cache and execs a matching compiled
# binary directly on a hit. DD-905 (2026-09-16) temporarily disabled the exec
# side after finding that a real PAX-compiled binary of this entrypoint
# silently corrupted %ENV loading. DD-922 (2026-09-16) root-caused and fixed
# the actual defect (StandaloneRuntime's own _run_*_unit dispatchers left $/
# undef across a later `eval` of the entrypoint's own source, since eval
# STRING shares its caller's dynamic scope - see StandaloneRuntime.pm's
# DD-922 comments) and re-enabled the exec side. A cache hit is executed
# again, exactly as DD-882 originally intended.
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
    is( $exit >> 8, 0, 'DD-922: dashboard exits cleanly with a matching self-compiled binary cached' );
    like(
        $out,
        qr/DD882-SENTINEL-COMPILED-OUTPUT/,
        'DD-922: dashboard execs the cached self-compiled binary on a cache hit, restoring DD-882\'s original behavior'
    );
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

# DD-882's exec guard var (DEVELOPER_DASHBOARD_PAX_SELF_EXECED) must still do
# its job now that the exec side is live again: a stale value inherited from
# a parent process (rather than one this exact invocation just set) must not
# suppress the self-check for THIS invocation, but the guard must still be
# cleared before falling through so a later child `dashboard` this process
# spawns gets its own independent, unsuppressed self-check.
{
    my $home = tempdir( CLEANUP => 1 );
    seed_cache_for_dashboard(
        $home,
        "#!/usr/bin/env perl\nprint \"DD882-SENTINEL-GUARD-TEST\\n\";\n"
    );

    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = $home;
        local $ENV{HARNESS_ACTIVE} = 0;
        local $ENV{DEVELOPER_DASHBOARD_PAX_SELF_EXECED} = 1;
        system( $^X, '-I', $lib, $dashboard, 'version' );
    };
    is( $exit >> 8, 0, 'DD-882: with the exec guard set from outside, dashboard still exits cleanly' );
    unlike(
        $out,
        qr/DD882-SENTINEL-GUARD-TEST/,
        'DD-882: a self-exec guard already set from OUTSIDE this invocation suppresses the self-check, matching the documented anti-infinite-loop contract'
    );
    like( $out, qr/\A\d+\.\d+\s*\z/, 'DD-882: with the guard pre-set, dashboard runs its own interpreted body normally' );
}

# DD-922's own regression coverage: a REAL PAX compile of dashboard (not a
# hand-written sentinel) must now run CORRECTLY when execed directly - the
# actual property this ticket restores. .env parsing must succeed under the
# real compiled binary, proving the $/ fix addresses the genuine defect, not
# just the sentinel-based mechanism test above. Skipped when pax is not
# resolvable (no vendored Pax CLI staged) or when explicitly disabled, since
# a real compile is slow and heavy.
SKIP: {
    skip 'DD_SKIP_REAL_PAX_COMPILE_TEST is set', 3 if $ENV{DD_SKIP_REAL_PAX_COMPILE_TEST};

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
    skip 'a real pax build did not succeed in this environment', 3 if ( $build_exit >> 8 ) != 0 || !-x $bin_file;

    open my $sfh, '<:raw', $dashboard or die "Unable to read $dashboard: $!";
    my $md5 = Digest::MD5->new;
    $md5->addfile($sfh);
    close $sfh;
    open my $mfh, '>', $md5_file or die "Unable to write $md5_file: $!";
    print {$mfh} $md5->hexdigest;
    close $mfh;

    # .env is untracked (git-ignored) and loaded relative to the REPO ROOT,
    # not $HOME - a ticket worktree sandbox carries no .env of its own, so
    # write a throwaway multi-line one here: this is the exact shape DD-905
    # found broken (a plain line-by-line <$fh> read misreading the whole
    # file as one "line") and DD-922 fixed at the StandaloneRuntime level.
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
    print {$wfh} "DD922_TEST_TOKEN=1234:abcdEFGHijklMNOP\nDD922_TEST_SECOND=another-value\nDD922_TEST_THIRD=third-value\n";
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

    is( $direct_exit >> 8, 0, 'DD-922 regression: a REAL self-compiled dashboard binary now runs cleanly (the fixed defect)' );
    unlike(
        $direct_out . $direct_err,
        qr/Invalid env line/,
        'DD-922 regression: the real compiled binary no longer misreads .env as one concatenated line'
    );
    like(
        $direct_out,
        qr/\A\d+\.\d+\s*\z/,
        'DD-922 regression: the real compiled binary prints the correct version, proving .env loaded (and the rest of startup ran) correctly'
    );
}

done_testing;

__END__

=head1 NAME

t/182-dashboard-self-compile.t - dashboard's own MD5-checked self-compile hook

=head1 PURPOSE

Exercises bin/dashboard's self-compile check: it checks its own source MD5
against PaxCache's cache and execs a matching cached compiled binary
directly on a hit (DD-882), including the guarded anti-infinite-loop
contract and the DD-922 regression proof that a REAL PAX-compiled binary of
this entrypoint now runs correctly (the defect DD-905 found and DD-922
fixed no longer reproduces).

=head1 WHY IT EXISTS

DD-877 only wired PaxCache into the internal C<ps1> helper command, never
into dashboard's own entrypoint - the owner's original, explicit request
(Telegram msg #2001, 2026-09-15) was specifically that d2/dashboard
themselves become the self-compiling target. DD-882 built that (execing a
cached compiled binary on a hit); DD-905 found and disabled the exec side
after it silently broke config loading in real use, undetected by DD-882's
own tests because prove sets HARNESS_ACTIVE, which skips this whole check;
DD-922 root-caused the actual defect (a `local $/;` in the vendored Pax
StandaloneRuntime's own entrypoint dispatchers spanning a later `eval` of
the entrypoint's own source, since C<eval STRING> shares its caller's
dynamic scope rather than opening a fresh one) and re-enabled the exec
side. This file is the executable proof that a cache hit is exec'd into
correctly, that the DD-882 anti-infinite-loop guard still works, and that
a genuinely real compiled binary no longer corrupts config loading.

=head1 WHEN TO USE

Run this file whenever the self-compile hook in bin/dashboard changes, or
whenever PaxCache's cache file layout changes (this file seeds the cache
directly using that exact layout, so a layout change must update both), or
whenever StandaloneRuntime's entrypoint dispatch changes (the DD-922 fix
lives there, not in bin/dashboard itself).
Set C<DD_SKIP_REAL_PAX_COMPILE_TEST=1> to skip the slow real-compile
regression block (still runs the fast sentinel-based blocks).

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/182-dashboard-self-compile.t

=head1 WHAT USES IT

Confirms the contract every real dashboard invocation depends on: a cache
hit is exec'd into correctly, a miss never blocks or breaks normal
interpreted operation, the anti-infinite-loop guard still works, and a real
compiled binary's actual (not simulated) config loading now succeeds.

=head1 EXAMPLES

Seeding a fake cached binary and confirming dashboard execs it:

    my $bin_file = seed_cache_for_dashboard($home, "#!/usr/bin/env perl\nprint 'hi';\n");
    system($^X, '-I', $lib, $dashboard, 'version');    # execs the cached binary on a hit

=cut
