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

# DD-882 (owner correction): dashboard must check ITS OWN source MD5 and, on
# a cache hit, exec the cached compiled binary directly instead of running
# interpreted at all.
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
    is( $exit >> 8, 0, 'DD-882: dashboard exits cleanly when a matching self-compiled binary is cached' );
    like(
        $out,
        qr/DD882-SENTINEL-COMPILED-OUTPUT/,
        'DD-882: dashboard execs the cached self-compiled binary directly on a cache hit, instead of running interpreted'
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

# The critical safety property: a process that has ALREADY been self-exec'd
# once (the guard env var is set, simulating running as the compiled binary
# itself) must never attempt to re-exec, however matching the cache is -
# otherwise the compiled binary's own embedded copy of this same check would
# loop forever.
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
    is( $exit >> 8, 0, 'DD-882: with the self-exec guard already set, dashboard still exits cleanly' );
    unlike(
        $out,
        qr/DD882-SENTINEL-SHOULD-NOT-RUN/,
        'DD-882: with the self-exec guard already set, the cached binary is never re-executed even though it matches'
    );
    like( $out, qr/\A\d+\.\d+\s*\z/, 'DD-882: with the guard set, dashboard runs its own interpreted body normally instead' );
}

done_testing;

__END__

=head1 NAME

t/182-dashboard-self-compile.t - dashboard's own MD5-checked self-compile hook

=head1 PURPOSE

Exercises DD-882's core requirement: bin/dashboard checks its own source
MD5 against PaxCache's cache and, on a match, execs the cached compiled
binary directly instead of continuing interpreted - with a hard safety
guard against the compiled binary's own embedded copy of this same check
ever re-triggering a self-exec, which would loop forever.

=head1 WHY IT EXISTS

DD-877 only wired PaxCache into the internal C<ps1> helper command, never
into dashboard's own entrypoint - the owner's original, explicit request
(Telegram msg #2001, 2026-09-15) was specifically that d2/dashboard
themselves become the self-compiling target. This file is the executable
proof that gap is closed, and that closing it did not introduce an
infinite self-exec loop.

=head1 WHEN TO USE

Run this file whenever the self-compile hook in bin/dashboard changes, or
whenever PaxCache's cache file layout changes (this file seeds the cache
directly using that exact layout, so a layout change must update both).

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/182-dashboard-self-compile.t

=head1 WHAT USES IT

Confirms the contract every real dashboard invocation depends on: a fresh
compiled binary is used transparently when available, a miss never blocks
or breaks normal interpreted operation, and the guard prevents runaway
self-exec recursion.

=head1 EXAMPLES

Seeding a fake cached binary and confirming dashboard execs it:

    my $bin_file = seed_cache_for_dashboard($home, "#!/usr/bin/env perl\nprint 'hi';\n");
    system($^X, '-I', $lib, $dashboard, 'version');    # runs the sentinel, not the real body

=cut
