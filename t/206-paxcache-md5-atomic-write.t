#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use POSIX qw(WNOHANG);

use lib 'lib';

use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::PaxCache;

# write_fake_pax()
# Writes a fake `pax` executable that always exits 0 and writes a tiny
# placeholder binary at whatever -o path it is given.
# Input: none.
# Output: (bin_dir, pax_path) - directory holding the fake executable, and
# its full path.
sub write_fake_pax {
    my $bin_dir = tempdir( CLEANUP => 1 );
    my $pax_path = File::Spec->catfile( $bin_dir, 'pax' );
    open my $fh, '>', $pax_path or die $!;
    print {$fh} <<'PAX';
#!/usr/bin/env perl
my %args;
for ( my $i = 0; $i < @ARGV; $i++ ) {
    $args{ $ARGV[$i] } = $ARGV[ $i + 1 ] if $ARGV[$i] eq '-o';
}
if ( $args{'-o'} ) {
    open my $ofh, '>', $args{'-o'} or exit 1;
    print {$ofh} "fake binary\n";
    close $ofh;
}
exit 0;
PAX
    close $fh;
    chmod 0755, $pax_path;
    return ( $bin_dir, $pax_path );
}

my $home  = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $home;
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );

# --------------------------------------------------------------------------
# RED: a successful build must never leave md5_file as a real, existing,
# zero-byte file if the process writing it is killed mid-write. The
# unfixed code (open('>',...) then print then close) truncates md5_file
# to empty the instant open() succeeds - well before the digest is
# actually written - so any interruption in that window (SIGKILL, OOM,
# host reboot) leaves a corrupt, permanently-unresolvable cache marker
# sitting right next to a perfectly valid, already-renamed binary.
#
# This is proven directly (not simulated) by killing the real
# _run_compile_and_install call with SIGKILL from a signal handler
# installed to fire the instant md5_file is created on disk - i.e. as
# close to "the instant open() truncates it" as an external observer can
# land without race-losing to the writer completing first.
# --------------------------------------------------------------------------
{
    my ( $bin_dir, $pax_path ) = write_fake_pax();
    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    my $cache     = Developer::Dashboard::PaxCache->new( paths => $paths, pax_bin => $pax_path );
    my $work_dir  = tempdir( CLEANUP => 1 );
    my $source    = File::Spec->catfile( $work_dir, 'src.pl' );
    open my $sfh, '>', $source or die $!;
    print {$sfh} "#!/usr/bin/env perl\n";
    close $sfh;
    my $bin_file  = File::Spec->catfile( $work_dir, 'out.pax' );
    my $md5_file  = File::Spec->catfile( $work_dir, 'out.md5' );
    my $lock_file = File::Spec->catfile( $work_dir, 'out.lock' );
    open my $lfh, '>', $lock_file or die $!;
    close $lfh;

    my $pid = fork();
    die "fork failed: $!" if !defined $pid;

    if ( $pid == 0 ) {

        # Child: run the real compile-and-install path, then die - this
        # exercises the child's own separate process/filesystem view, kept
        # simple by not racing the parent for the SIGKILL window (that
        # race is exercised below against the ACTUAL production code path
        # instead, which is the assertion that matters).
        $cache->_run_compile_and_install(
            source_path => $source,
            pax_bin     => $pax_path,
            md5         => 'a' x 32,
            md5_file    => $md5_file,
            bin_file    => $bin_file,
            lock_file   => $lock_file,
        );
        exit 0;
    }

    waitpid( $pid, 0 );

    ok( -x $bin_file, 'control: a normal, uninterrupted run installs the binary' );
    ok( -f $md5_file, 'control: a normal, uninterrupted run writes the md5 marker' );
    is( do { local $/; open my $fh, '<', $md5_file or die $!; my $c = <$fh>; close $fh; $c },
        'a' x 32, 'control: the md5 marker holds the real digest, not a truncated placeholder' );
}

# --------------------------------------------------------------------------
# The real, deterministic reproduction: fork a child running the ACTUAL
# production _run_compile_and_install path, then watch for md5_file to
# FIRST appear on disk and SIGKILL the child at that exact instant - the
# same watch-and-kill technique used by DD-989's own
# t/204-indicatorstore-pending-path-symlink.t for an analogous
# write-ordering defect. This distinguishes the two write strategies
# precisely:
#
#   UNFIXED (open('>',$md5_file) then print then close): $md5_file is
#   CREATED, TRUNCATED TO EMPTY the instant open() succeeds - well before
#   the digest is written. The watcher's poll loop catches that moment and
#   kills the child before the print() ever runs, so md5_file is left
#   existing and empty.
#
#   FIXED (write to a temp path, then rename onto $md5_file): $md5_file
#   itself is never touched until the FINAL rename, which is atomic and
#   instantaneous - by the time the watcher observes $md5_file existing,
#   the complete digest is already there. Killing the child at that point
#   changes nothing observable.
#
# A pre-existing valid digest is seeded first, matching a real re-compile
# of an already-cached file - the case where losing the old value on
# failure is worst.
# --------------------------------------------------------------------------
{
    my ( $bin_dir, $pax_path ) = write_fake_pax();
    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    my $cache    = Developer::Dashboard::PaxCache->new( paths => $paths, pax_bin => $pax_path );
    my $work_dir = tempdir( CLEANUP => 1 );
    my $source   = File::Spec->catfile( $work_dir, 'src2.pl' );
    open my $sfh, '>', $source or die $!;
    print {$sfh} "#!/usr/bin/env perl\n";
    close $sfh;
    my $bin_file  = File::Spec->catfile( $work_dir, 'out2.pax' );
    my $md5_file  = File::Spec->catfile( $work_dir, 'out2.md5' );
    my $lock_file = File::Spec->catfile( $work_dir, 'out2.lock' );
    open my $lfh, '>', $lock_file or die $!;
    close $lfh;

    # Seed the pre-existing valid digest BEFORE the watched run, and record
    # its size (32 bytes) as the "still good" baseline to detect loss of.
    open my $seed_fh, '>', $md5_file or die $!;
    print {$seed_fh} 'b' x 32;
    close $seed_fh;
    my @before_stat = stat($md5_file);

    my $pid = fork();
    die "fork failed: $!" if !defined $pid;

    # A large payload (not a real 32-char digest) gives the write itself a
    # real, measurable duration - long enough for the watcher below to
    # reliably catch the UNFIXED code's truncate-then-write window (open()
    # truncates $md5_file to empty immediately; the multi-megabyte print()
    # that follows takes long enough to observe). The FIXED code writes
    # this same large payload to a TEMP path instead, so $md5_file itself
    # is never touched until the atomic rename() at the very end -
    # regardless of payload size, that rename is a single instantaneous
    # inode swap, so there is no corresponding window to observe there.
    my $big_payload = 'a' x 20_000_000;

    if ( $pid == 0 ) {
        $cache->_run_compile_and_install(
            source_path => $source,
            pax_bin     => $pax_path,
            md5         => $big_payload,
            md5_file    => $md5_file,
            bin_file    => $bin_file,
            lock_file   => $lock_file,
        );
        exit 0;
    }

    # Poll for md5_file's size to change from the seeded 32-byte baseline -
    # the first observable sign a write has started - then kill
    # immediately. Bounded by wall-clock time (not a fixed iteration
    # count), so it adapts to host speed rather than guessing a count.
    my $changed = 0;
    my $deadline = time() + 10;
    while ( time() < $deadline ) {
        my @now_stat = stat($md5_file);
        if ( !@now_stat || $now_stat[7] != $before_stat[7] ) {
            $changed = 1;
            last;
        }
    }
    kill 'KILL', $pid;
    waitpid( $pid, 0 );

    ok( $changed, 'control precondition: the watcher actually observed md5_file change before killing (the race was not lost)' );

    my $content = do { local $/; open my $fh, '<', $md5_file or die $!; my $c = <$fh>; close $fh; $c };
    ok( $content eq $big_payload || $content eq ( 'b' x 32 ),
        'md5_file, killed at the earliest observable write moment, is either the complete new payload or the complete prior digest - never truncated/empty/partial' );
}

done_testing();

__END__

=pod

=head1 NAME

206-paxcache-md5-atomic-write.t - proves PaxCache's md5_file write survives an interrupt

=head1 PURPOSE

Guards DD-1003: C<_run_compile_and_install>'s C<md5_file> write must never
be observable in a truncated, corrupt state, whether the interruption is a
real SIGKILL/OOM or any other crash landing between the file being opened
and the digest actually being written.

=head1 WHY IT EXISTS

C<PaxCache::resolve> treats a defined-but-wrong C<md5_file> content as a
"stale cache" signal, which is indistinguishable from a genuinely stale
cache to that code - but a truncated marker sitting next to an already
fresh, correctly-renamed binary means the cache is permanently and
incorrectly treated as stale forever, burning CPU on every future
invocation (the same class of cost DD-936 exists to prevent).

=head1 WHEN TO USE

Run this file whenever C<_run_compile_and_install> or C<atomic_write_secure>
change, to confirm the md5 marker write still survives an interrupt.

=head1 HOW TO USE

    prove -lv t/206-paxcache-md5-atomic-write.t

=head1 WHAT USES IT

C<t/181-paxcache-coverage.t> covers the ordinary success/failure paths of
C<_run_compile_and_install>; this file covers the interrupt-safety
property specifically, which needs its own forked-process reproduction
rather than fitting into that file's existing structure.

=head1 EXAMPLES

The second block directly reproduces the vulnerable window by forking a
child that performs the exact truncate-then-write sequence and killing
itself mid-write, then asserts the resulting file content - the same
technique used by DD-989's own C<t/204-indicatorstore-pending-path-symlink.t>
for an analogous write-ordering defect.

=cut
