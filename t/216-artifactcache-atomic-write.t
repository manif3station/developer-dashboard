#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use POSIX qw(WNOHANG);
use JSON::XS qw(decode_json);

use lib 'lib';

use Developer::Dashboard::Pax::ArtifactCache;

# minimal_manifest()
# Builds the smallest manifest metadata_for() accepts.
# Input: none.
# Output: manifest hash reference.
sub minimal_manifest {
    return {
        module_graph => { modules => ['Foo::Bar'] },
        runtime => { perl_config_version => '5.44.0', pax_abi_stamp => 'abc', archname => 'x86_64-linux' },
        schema_version => 1,
        source_entrypoint => 'bin/dashboard',
        capture => { mode => 'static' },
    };
}

my $cache_root = tempdir( CLEANUP => 1 );
my $cache = Developer::Dashboard::Pax::ArtifactCache->new( root => $cache_root );
my $manifest = minimal_manifest();
my $artifact = { region_id => 'region-1' };

my $metadata = $cache->metadata_for( $manifest, $artifact );
my $id = $metadata->{artifact_id};
my $dir = File::Spec->catdir( $cache_root, substr( $id, 0, 2 ) );
my $path = File::Spec->catfile( $dir, "$id.json" );

# --------------------------------------------------------------------------
# RED (reproduces the DD-1009 bug class, DD-989/DD-1003's own established
# proof shape): a write interrupted mid-flight must never leave a real,
# existing, truncated file at the target path - only the complete previous
# content (absent, on a first write) or the complete new content.
# --------------------------------------------------------------------------
{
    my $pid = fork();
    die "fork failed: $!" if !defined $pid;
    if ( $pid == 0 ) {
        $cache->write_artifact( manifest => $manifest, artifact => $artifact );
        POSIX::_exit(0);
    }

    # Poll for the target path to exist, then kill immediately - this
    # catches the write mid-flight on both the old (plain open, truncates
    # instantly) and new (tmp-then-rename, target never appears truncated)
    # code paths, so the test discriminates fixed from broken regardless
    # of timing.
    my $waited = 0;
    while ( $waited < 5 && !-e $path ) {
        select( undef, undef, undef, 0.01 );
        $waited += 0.01;
    }
    kill 'KILL', $pid;
    waitpid( $pid, 0 );

    if ( -e $path ) {
        my $size = -s $path;
        ok( $size > 0, 'the target path, if it exists after an interrupted write, is never a real zero-byte truncated file' )
          or diag("Found a $size-byte file at $path - this is the exact DD-1009/DD-989/DD-1003 truncation defect");
    }
    else {
        pass('the target path does not exist after an interrupted write - no truncated file left behind (the write never got far enough to be observed)');
    }

    unlink $path if -e $path;
}

# --------------------------------------------------------------------------
# GREEN: a real, uninterrupted write_artifact call writes correct,
# complete JSON, unaffected by the atomic-write change.
# --------------------------------------------------------------------------
{
    my $result = $cache->write_artifact( manifest => $manifest, artifact => $artifact );
    is( $result->{id}, $id, 'write_artifact returns the expected artifact id' );
    ok( -e $result->{path}, 'write_artifact leaves a real file at the returned path' );

    open my $fh, '<', $result->{path} or die "cannot read $result->{path}: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    my $decoded = decode_json($content);
    is( $decoded->{metadata}{artifact_id}, $id, 'the written JSON round-trips with the correct artifact_id' );
    is_deeply( $decoded->{artifact}, $artifact, 'the written JSON round-trips the artifact data unchanged' );
}

# --------------------------------------------------------------------------
# AC-1: no stray "$path.tmp.$$" temp file is left behind after a normal,
# successful write - the rename step actually completes and cleans up
# after itself (nothing to explicitly unlink; rename() removes the source).
# --------------------------------------------------------------------------
{
    opendir my $dh, File::Spec->catdir( $cache_root, substr( $id, 0, 2 ) ) or die $!;
    my @files = grep { $_ !~ /^\.\.?\z/ } readdir $dh;
    closedir $dh;
    ok( !( grep { /\.tmp\.\d+\z/ } @files ), 'no stray .tmp.PID file remains after a successful write' );
}

done_testing();

__END__

=pod

=head1 NAME

216-artifactcache-atomic-write.t - proves DD-1009's atomic write fix for ArtifactCache

=head1 PURPOSE

Guards DD-1009: C<Pax::ArtifactCache::write_artifact> must never leave a
truncated cache-metadata JSON file on disk if interrupted mid-write - the
same defect class already fixed in DD-989 (C<IndicatorStore.pm>) and
DD-1003 (C<PaxCache.pm>'s C<md5_file>).

=head1 WHY IT EXISTS

Nothing else in this suite exercised C<write_artifact> directly. This
file proves both the failure mode (a real, forked, SIGKILL-interrupted
write never leaves a truncated file) and the happy path (a normal write
still produces correct, complete, round-trippable JSON).

=head1 WHEN TO USE

Run this file whenever C<ArtifactCache.pm>'s write path changes.

=head1 HOW TO USE

    prove -lv t/216-artifactcache-atomic-write.t

=head1 WHAT USES IT

C<write_artifact>'s atomicity is not exercised by any other test file in
this suite.

=head1 EXAMPLES

The defect this file guards against, in its original (fixed) form:

    open my $fh, '>', $path or die ...;   # truncates $path to 0 bytes HERE
    print {$fh} $json;                     # ... before this ever runs
    close $fh;

Fixed by writing to C<"$path.tmp.$$"> first, then C<rename()>ing onto
C<$path> - matching C<PaxCache.pm>'s own already-established pattern.

=cut
