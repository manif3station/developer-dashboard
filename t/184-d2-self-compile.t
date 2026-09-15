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
my $d2        = File::Spec->catfile( $repo_root, 'bin', 'd2' );

# Same MD5-keyed cache layout PaxCache.pm uses, this time keyed on d2's OWN
# source path (not dashboard's) - d2 is a distinct compile target from
# dashboard, so it gets its own cache entry under the same md5-of-path key
# scheme (see t/182 for the dashboard-side twin of this test).
sub seed_cache_for_d2 {
    my ( $home, $binary_contents ) = @_;
    my $cache_dir = File::Spec->catdir( $home, '.developer-dashboard', 'cache', 'pax' );
    make_path($cache_dir);
    my $key = Digest::MD5::md5_hex($d2);

    open my $sfh, '<:raw', $d2 or die "Unable to read $d2: $!";
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

# DD-882 (owner correction, Telegram msg #2001): d2, not only dashboard, must
# check its OWN source MD5 and exec a matching cached compiled binary
# directly - the owner named both entrypoints explicitly and separately
# tested `file ~/perl5/bin/d2`.
{
    my $home = tempdir( CLEANUP => 1 );
    seed_cache_for_d2(
        $home,
        "#!/usr/bin/env perl\nprint \"DD882-D2-SENTINEL-COMPILED-OUTPUT\\n\";\n"
    );

    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = $home;
        local $ENV{HARNESS_ACTIVE} = 0;
        system( $^X, '-I', $lib, $d2, 'version' );
    };
    is( $exit >> 8, 0, 'DD-882: d2 exits cleanly when a matching self-compiled binary is cached for d2 itself' );
    like(
        $out,
        qr/DD882-D2-SENTINEL-COMPILED-OUTPUT/,
        'DD-882: d2 execs its own cached self-compiled binary directly on a cache hit, instead of re-execing interpreted dashboard'
    );
}

# No cache present: falls through to the existing, unchanged behavior of
# re-execing sibling dashboard interpreted.
{
    my $home = tempdir( CLEANUP => 1 );
    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = $home;
        local $ENV{HARNESS_ACTIVE} = 0;
        local $ENV{PATH} = '/nonexistent-empty-dir-for-this-test';
        system( $^X, '-I', $lib, $d2, 'version' );
    };
    is( $exit >> 8, 0, 'DD-882: d2 exits cleanly with no cached self-binary' );
    like( $out, qr/\A\d+\.\d+\s*\z/, 'DD-882: d2 re-execs dashboard interpreted normally with no cached self-binary' );
}

# Safety: the shared guard env var (already set, e.g. because dashboard's own
# hook already fired once in this process tree) must stop d2 from attempting
# its own self-exec too, even though its cache matches.
{
    my $home = tempdir( CLEANUP => 1 );
    seed_cache_for_d2(
        $home,
        "#!/usr/bin/env perl\nprint \"DD882-D2-SENTINEL-SHOULD-NOT-RUN\\n\";\nexit 1;\n"
    );

    my ( $out, $err, $exit ) = capture {
        local $ENV{HOME} = $home;
        local $ENV{HARNESS_ACTIVE} = 0;
        local $ENV{DEVELOPER_DASHBOARD_PAX_SELF_EXECED} = 1;
        system( $^X, '-I', $lib, $d2, 'version' );
    };
    is( $exit >> 8, 0, 'DD-882: with the self-exec guard already set, d2 still exits cleanly' );
    unlike(
        $out,
        qr/DD882-D2-SENTINEL-SHOULD-NOT-RUN/,
        'DD-882: with the self-exec guard already set, d2 never execs its own cached binary even though it matches'
    );
    like( $out, qr/\A\d+\.\d+\s*\z/, 'DD-882: with the guard set, d2 falls through to its normal re-exec of dashboard' );
}

done_testing;

__END__

=head1 NAME

t/184-d2-self-compile.t - d2's own MD5-checked self-compile hook

=head1 PURPOSE

Exercises DD-882's requirement that C<d2>, not only C<dashboard>, checks its
own source MD5 against PaxCache's cache and execs a matching cached compiled
binary directly, sharing the C<DEVELOPER_DASHBOARD_PAX_SELF_EXECED> guard
with dashboard's own hook so neither entrypoint double-triggers a self-exec
in the same process tree.

=head1 WHY IT EXISTS

The owner named both C<d2> and C<dashboard> explicitly (Telegram msg #2001,
2026-09-15) and personally tested C<file ~/perl5/bin/d2> - relying only on
d2's unconditional re-exec into interpreted dashboard (whose own hook would
then fire) does not satisfy that: it costs an extra process hop through the
interpreter before the compiled binary is ever reached. This file is the
executable proof d2 checks itself directly.

=head1 WHEN TO USE

Run this file whenever the self-compile hook in bin/d2 changes, or whenever
PaxCache's cache file layout changes (this file seeds the cache directly
using that exact layout, so a layout change must update both this file and
its t/182 dashboard-side twin).

=head1 HOW TO USE

    PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/184-d2-self-compile.t

=head1 WHAT USES IT

Confirms the contract every real C<d2> invocation depends on: a fresh
compiled binary for d2 itself is used transparently when available, a miss
falls through to the existing sibling-dashboard re-exec unchanged, and the
shared guard prevents either entrypoint's hook from re-triggering the other.

=head1 EXAMPLES

Seeding a fake cached binary for d2 and confirming d2 execs it directly:

    my $bin_file = seed_cache_for_d2($home, "#!/usr/bin/env perl\nprint 'hi';\n");
    system($^X, '-I', $lib, $d2, 'version');    # runs the sentinel, not dashboard

=cut
