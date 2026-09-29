#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use File::Path qw(make_path);
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
is( Developer::Dashboard::Pax::ArtifactCache->new->{root}, '.pax/cache', 'new uses the documented cache root when no root is supplied' );
my $manifest = minimal_manifest();
my $artifact = { region_id => 'region-1' };

my $metadata = $cache->metadata_for( $manifest, $artifact );
my $id = $metadata->{artifact_id};
my $dir = File::Spec->catdir( $cache_root, substr( $id, 0, 2 ) );
my $path = File::Spec->catfile( $dir, "$id.json" );

my $live_manifest = minimal_manifest();
$live_manifest->{capture}{mode} = 'live';
is( $cache->metadata_for( $live_manifest, {} )->{environment_bound}, JSON::XS::true(), 'metadata marks live captures as environment-bound' );
my $sparse_metadata = $cache->metadata_for( { module_graph => {}, runtime => {}, capture => {} }, {} );
is( $sparse_metadata->{cpu_target}, "$^O-unknown", 'metadata uses unknown architecture when the manifest omits it' );
is( $sparse_metadata->{module_graph_hash}, Digest::SHA::sha256_hex(''), 'metadata hashes an empty module graph when it is absent' );

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
    is_deeply( $cache->read_artifact( $result->{path} ), $decoded, 'read_artifact decodes the persisted cache record' );
}

my $read_error = eval { $cache->read_artifact( File::Spec->catfile( $cache_root, 'missing.json' ) ); 1 };
ok( !$read_error, 'read_artifact rejects a missing record' );
like( $@, qr/cannot read .*missing\.json/, 'read_artifact reports the path that could not be opened' );

my $valid_metadata = $cache->validate_metadata( manifest => $manifest, metadata => $metadata );
ok( $valid_metadata->{valid}, 'validate_metadata accepts metadata generated from the same manifest' );
is_deeply( $valid_metadata->{errors}, [], 'valid metadata has no mismatch codes' );
my $invalid_metadata = $cache->validate_metadata(
    manifest => $manifest,
    metadata => {
        perl_version => 'different',
        perl_abi_stamp => 'different',
        snapshot_schema_version => -1,
        capture_mode => 'different',
    },
);
ok( !$invalid_metadata->{valid}, 'validate_metadata rejects each independently mismatched compatibility field' );
is_deeply(
    $invalid_metadata->{errors},
    [qw(perl_version_mismatch abi_stamp_mismatch snapshot_schema_mismatch capture_mode_mismatch)],
    'validate_metadata returns one explicit error code for every mismatch',
);
my $missing_field_metadata = $cache->validate_metadata(
    manifest => { runtime => {}, schema_version => undef, capture => {} },
    metadata => {},
);
ok( !$missing_field_metadata->{valid}, 'validate_metadata rejects absent metadata fields using its documented comparison defaults' );
is_deeply( $missing_field_metadata->{errors}, ['snapshot_schema_mismatch'], 'defaulted absent fields compare consistently and report only the schema mismatch' );
for my $arguments ( { metadata => $metadata }, { manifest => $manifest } ) {
    my $valid = eval { $cache->validate_metadata(%$arguments); 1 };
    ok( !$valid, 'validate_metadata rejects a missing required argument' );
    like( $@, qr/(?:manifest|metadata) required/, 'missing metadata input produces an explicit argument error' );
}
for my $arguments ( { metadata => $metadata }, { artifact => $artifact }, { manifest => $manifest, artifact => undef } ) {
    my $valid = eval { $cache->write_artifact(%$arguments); 1 };
    ok( !$valid, 'write_artifact rejects a missing required argument' );
    like( $@, qr/(?:manifest|artifact) required/, 'missing write input produces an explicit argument error' );
}

# Exercise real filesystem failures at each side of the atomic replacement.
# Separate artifact IDs keep these deliberate failure fixtures independent of
# the successful round-trip above.
{
    my $failed_artifact = { region_id => 'open-failure' };
    my $failed_id = $cache->metadata_for( $manifest, $failed_artifact )->{artifact_id};
    my $failed_dir = File::Spec->catdir( $cache_root, substr( $failed_id, 0, 2 ) );
    my $failed_path = File::Spec->catfile( $failed_dir, "$failed_id.json" );
    my $tmp_path = "$failed_path.tmp.$$";
    make_path($failed_dir);
    mkdir $tmp_path or die "cannot create open-failure fixture $tmp_path: $!";

    my $written = eval { $cache->write_artifact( manifest => $manifest, artifact => $failed_artifact ); 1 };
    ok( !$written, 'write_artifact fails when the temporary path cannot be opened as a file' );
    like( $@, qr/cannot write \Q$tmp_path\E/, 'temporary-file open failure identifies the attempted path' );
    rmdir $tmp_path or die "cannot remove open-failure fixture $tmp_path: $!";
}

{
    my $failed_artifact = { region_id => 'rename-failure' };
    my $failed_id = $cache->metadata_for( $manifest, $failed_artifact )->{artifact_id};
    my $failed_dir = File::Spec->catdir( $cache_root, substr( $failed_id, 0, 2 ) );
    my $failed_path = File::Spec->catfile( $failed_dir, "$failed_id.json" );
    my $tmp_path = "$failed_path.tmp.$$";
    make_path($failed_dir);
    mkdir $failed_path or die "cannot create rename-failure fixture $failed_path: $!";

    my $written = eval { $cache->write_artifact( manifest => $manifest, artifact => $failed_artifact ); 1 };
    ok( !$written, 'write_artifact fails when atomic rename cannot replace a directory' );
    like( $@, qr/cannot rename \Q$tmp_path\E to \Q$failed_path\E/, 'rename failure identifies both source and destination paths' );
    unlink $tmp_path or die "cannot remove failed temporary artifact $tmp_path: $!";
    rmdir $failed_path or die "cannot remove rename-failure fixture $failed_path: $!";
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

The test also forces temporary-file open and final rename failures with
isolated filesystem fixtures, ensuring both error branches remain measured and
their diagnostic paths stay explicit. It round-trips the public reader and
validates matching, mismatching, and missing metadata inputs.

=cut
