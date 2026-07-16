#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use lib 'lib';

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);

use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::PageStore;
use Developer::Dashboard::PageDocument;

# ---------------------------------------------------------------------------
# Hermetic runtime: an isolated HOME and state root, with the current working
# directory set to the temp home so DD-OOP-LAYER discovery resolves entirely
# inside the sandbox.
# ---------------------------------------------------------------------------
my $home = tempdir( CLEANUP => 1 );
local $ENV{HOME}                           = $home;
local $ENV{DEVELOPER_DASHBOARD_STATE_ROOT} = tempdir( CLEANUP => 1 );
chdir $home or die "Unable to chdir to $home: $!";

my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
my $store = Developer::Dashboard::PageStore->new( paths => $paths );

# write_raw($file, $bytes): write exact bytes with no encoding layer.
sub write_raw {
    my ( $file, $bytes ) = @_;
    open my $fh, '>:raw', $file or die "Unable to write $file: $!";
    print {$fh} $bytes;
    close $fh or die "Unable to close $file: $!";
    return $file;
}

my $droot = $paths->dashboards_root;

# ---------------------------------------------------------------------------
# page_file() id validation (line 35: !defined $id || $id eq '').
# ---------------------------------------------------------------------------
ok( !eval { $store->page_file(undef); 1 }, 'page_file(undef) dies on missing id' );
ok( !eval { $store->page_file(''); 1 },    'page_file("") dies on empty id' );
ok( $store->page_file('welcome'),          'page_file(valid id) returns a path' );

# ---------------------------------------------------------------------------
# _normalized_page_id() undef handling (line 211: $id = '' if !defined $id).
# ---------------------------------------------------------------------------
is( $store->_normalized_page_id(undef),      '',    '_normalized_page_id(undef) => empty string' );
is( $store->_normalized_page_id('/app/foo'), 'foo', '_normalized_page_id strips /app/ prefix' );

# ---------------------------------------------------------------------------
# load_saved_page inheriting an id when the parsed page has none
# (line 69: $page->{id} ||= $id, for both a truthy and a falsy load id).
# ---------------------------------------------------------------------------
write_raw( File::Spec->catfile( $droot, 'noident' ), "TITLE: Hi\n" );
write_raw( File::Spec->catfile( $droot, '0' ),       "TITLE: Hi\n" );

my $p_noident = $store->load_saved_page('noident');
is( $p_noident->{id}, 'noident', 'empty-id page inherits a truthy load id' );

my $p_zero = $store->load_saved_page('0');
is( $p_zero->{id}, '0', 'empty-id page inherits a falsy load id' );

$store->save_page( { id => 'realid', title => 'Real' } );
my $p_real = $store->load_saved_page('realid');
is( $p_real->{id}, 'realid', 'saved page keeps its own parsed id' );

# ---------------------------------------------------------------------------
# encode_page raw-instruction handling
# (line 108: defined $raw_instruction && $raw_instruction ne '').
# ---------------------------------------------------------------------------
my $doc_undef = Developer::Dashboard::PageDocument->from_hash( { id => 'e1', title => 'T' } );
ok( length $store->encode_page($doc_undef), 'encode_page without raw_instruction encodes canonical text' );

my $doc_empty = Developer::Dashboard::PageDocument->from_hash( { id => 'e2', title => 'T' } );
$doc_empty->{meta}{raw_instruction} = '';
ok( length $store->encode_page($doc_empty), 'encode_page with empty raw_instruction falls through to canonical' );

my $doc_raw = Developer::Dashboard::PageDocument->from_hash( { id => 'e3', title => 'T' } );
$doc_raw->{meta}{raw_instruction} = "TITLE: raw\n";
ok( length $store->encode_page($doc_raw), 'encode_page uses a present raw_instruction' );

# ---------------------------------------------------------------------------
# list_saved_pages skipping malformed entries (line 150). The saved-entry
# helper is fed crafted rows (undef id, empty id, valid id) so the id guard's
# every side executes; naturally-produced entries always carry a non-empty id.
# ---------------------------------------------------------------------------
{
    my $vf = File::Spec->catfile( $droot, 'listok' );
    write_raw( $vf, "TITLE: Listed\n" );
    my @entries = (
        { id => undef,    file => $vf },
        { id => '',       file => $vf },
        { id => 'listok', file => $vf },
    );
    no warnings 'redefine';
    local *Developer::Dashboard::PageStore::_saved_page_entries_for_root = sub { @entries };
    my @ids = $store->list_saved_pages;
    is_deeply( \@ids, ['listok'], 'list_saved_pages skips undef/empty ids and keeps valid ones' );
}

# ---------------------------------------------------------------------------
# _load_page_file error path when instruction parsing fails
# (line 241: $args{id} || ''  and  line 249: die($@ || "...")).
# ---------------------------------------------------------------------------
{
    my $junk = File::Spec->catfile( $droot, 'junk.bm' );
    write_raw( $junk, "no colon just prose\n" );

    ok( !eval { $store->_load_page_file($junk); 1 },
        '_load_page_file without an id dies on unparseable content' );
    ok( !eval { $store->_load_page_file( $junk, id => 'x' ); 1 },
        '_load_page_file with an id dies on unparseable content' );
}

# ---------------------------------------------------------------------------
# _raw_nav_fragment_page id and instruction handling (lines 258 and 259).
# ---------------------------------------------------------------------------
ok( !eval { $store->_raw_nav_fragment_page(); 1 }, '_raw_nav_fragment_page dies without an id' );

my $nav_noinstr = $store->_raw_nav_fragment_page( id => 'nav/a.tt' );
is( $nav_noinstr->{layout}{body}, '', 'raw nav fragment defaults to an empty body' );

my $nav_instr = $store->_raw_nav_fragment_page( id => 'nav/b.tt', instruction => 'BODY' );
is( $nav_instr->{layout}{body}, 'BODY', 'raw nav fragment keeps its instruction body' );

# ---------------------------------------------------------------------------
# _looks_like_raw_nav_fragment classification (lines 274 and 276).
# ---------------------------------------------------------------------------
is( $store->_looks_like_raw_nav_fragment(undef),          0, 'undef fragment is not raw nav' );
is( $store->_looks_like_raw_nav_fragment(''),             0, 'empty fragment is not raw nav' );
is( $store->_looks_like_raw_nav_fragment('plain words'),  0, 'plain text is not raw nav' );
is( $store->_looks_like_raw_nav_fragment('<div>x</div>'), 1, 'an html tag looks like raw nav' );

# ---------------------------------------------------------------------------
# _read_saved_instruction decode paths
# (line 286 open-fail; line 291 UTF-8 decode fallback across all three outcomes).
# ---------------------------------------------------------------------------
ok( !eval { $store->_read_saved_instruction( File::Spec->catfile( $home, 'no-such-file-xyz' ) ); 1 },
    '_read_saved_instruction dies when the file cannot be opened' );

my $empty_file = File::Spec->catfile( $droot, 'empty.bm' );
write_raw( $empty_file, '' );
is( $store->_read_saved_instruction($empty_file), '', 'an empty saved file reads back as empty text' );

my $valid_file = File::Spec->catfile( $droot, 'valid.bm' );
write_raw( $valid_file, "hello world\n" );
is( $store->_read_saved_instruction($valid_file), "hello world\n", 'a valid UTF-8 file decodes strictly' );

my $invalid_file = File::Spec->catfile( $droot, 'invalid.bm' );
write_raw( $invalid_file, "bad\xFF\xFEbytes" );
ok( length $store->_read_saved_instruction($invalid_file),
    'an invalid UTF-8 file falls back to lenient decoding' );

# ---------------------------------------------------------------------------
# _normalize_legacy_icon_markup undef handling (line 301).
# ---------------------------------------------------------------------------
is( $store->_normalize_legacy_icon_markup(undef),   '',      'normalize(undef) => empty string' );
is( $store->_normalize_legacy_icon_markup('plain'), 'plain', 'normalize passes plain text through' );

# ---------------------------------------------------------------------------
# _saved_page_entries_for_root root guards (line 314: defined $root && -d $root).
# ---------------------------------------------------------------------------
is_deeply( [ $store->_saved_page_entries_for_root(undef) ], [],
    '_saved_page_entries_for_root(undef) returns nothing' );
is_deeply( [ $store->_saved_page_entries_for_root( File::Spec->catfile( $home, 'missing-dir' ) ) ], [],
    '_saved_page_entries_for_root on a missing directory returns nothing' );
ok( scalar( $store->_saved_page_entries_for_root($droot) ),
    '_saved_page_entries_for_root on a real directory finds entries' );

# ---------------------------------------------------------------------------
# save_page write failure (line 53: open my $fh, '>', $file or die).
# The target id resolves onto an existing directory, so the write fails.
# ---------------------------------------------------------------------------
{
    my $bm = tempdir( CLEANUP => 1 );
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS} = $bm;
    make_path( File::Spec->catdir( $bm, 'isadir' ) );
    ok( !eval { $store->save_page( { id => 'isadir', title => 'X' } ); 1 },
        'save_page dies when the target path is a directory' );
}

# ---------------------------------------------------------------------------
# migrate_legacy_json_pages happy + skip paths (lines 172, 174, 179, 180, and
# the 184/188 success sides).
# ---------------------------------------------------------------------------
{
    my $bm = tempdir( CLEANUP => 1 );
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS} = $bm;
    write_raw( File::Spec->catfile( $bm, 'withid.json' ), '{"id":"withid","title":"t"}' );
    write_raw( File::Spec->catfile( $bm, 'notid.json' ),  '{"title":"t"}' );
    write_raw( File::Spec->catfile( $bm, '0.json' ),      '{"title":"t"}' );
    write_raw( File::Spec->catfile( $bm, 'bad.json' ),    'this is not json' );
    write_raw( File::Spec->catfile( $bm, 'readme.txt' ),  'hello' );
    make_path( File::Spec->catdir( $bm, 'dir.json' ) );

    my $migrated = $store->migrate_legacy_json_pages;
    my %by_id = map { $_->{id} => 1 } @$migrated;
    ok( $by_id{withid}, 'migrate keeps an explicit json id' );
    ok( $by_id{notid},  'migrate falls back to a truthy basename id' );
    ok( $by_id{'0'},    'migrate falls back to a falsy basename id' );
    is( scalar @$migrated, 3, 'migrate skips non-json, directory, and unparseable json entries' );
}

# ---------------------------------------------------------------------------
# migrate target write failure (line 184: open my $out, '>', $target or die).
# The migrated id resolves onto an existing directory.
# ---------------------------------------------------------------------------
{
    my $bm = tempdir( CLEANUP => 1 );
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS} = $bm;
    write_raw( File::Spec->catfile( $bm, 'clash.json' ), '{"title":"t"}' );
    make_path( File::Spec->catdir( $bm, 'clash' ) );
    ok( !eval { $store->migrate_legacy_json_pages; 1 },
        'migrate dies when the target path is a directory' );
}

# ---------------------------------------------------------------------------
# Permission-dependent failure paths. These require a non-root user because the
# superuser bypasses the directory/file permission bits under test:
#   line 167  opendir on an unreadable root
#   line 175  open '<' on an unreadable json file
#   line 188  unlink of a source file in a read-only root
# ---------------------------------------------------------------------------
SKIP: {
    skip 'permission failure paths require a non-root user', 3 if $> == 0;

    # line 167: an unreadable bookmarks root makes opendir fail.
    {
        my $ro = tempdir( CLEANUP => 1 );
        chmod 0300, $ro or die "Unable to chmod $ro: $!";
        local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS} = $ro;
        my $migrated = $store->migrate_legacy_json_pages;
        is_deeply( $migrated, [], 'migrate returns empty when the root cannot be read' );
        chmod 0700, $ro;
    }

    # line 175: an unreadable json file is skipped.
    {
        my $bm = tempdir( CLEANUP => 1 );
        local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS} = $bm;
        my $np = File::Spec->catfile( $bm, 'noperm.json' );
        write_raw( $np, '{"title":"t"}' );
        chmod 0000, $np or die "Unable to chmod $np: $!";
        my $migrated = $store->migrate_legacy_json_pages;
        is( scalar @$migrated, 0, 'migrate skips an unreadable json file' );
        chmod 0644, $np;
    }

    # line 188: a read-only root leaves the source unlink to fail after the
    # target (in a still-writable subdirectory) is written.
    {
        my $bm = tempdir( CLEANUP => 1 );
        local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS} = $bm;
        write_raw( File::Spec->catfile( $bm, 'src.json' ), '{"id":"sub/page","title":"t"}' );
        make_path( File::Spec->catdir( $bm, 'sub' ) );
        chmod 0500, $bm or die "Unable to chmod $bm: $!";
        ok( !eval { $store->migrate_legacy_json_pages; 1 },
            'migrate dies when the source file cannot be unlinked' );
        chmod 0700, $bm;
    }
}

done_testing;

__END__

=pod

=head1 NAME

t/73-pagestore-coverage.t - branch and condition coverage for the page store

=head1 PURPOSE

This test drives the residual branch and condition paths of the saved-page and
transient-page store so its behaviour under malformed input, permission errors,
and legacy-migration edge cases is pinned by an executable contract rather than
left implicit.

=head1 WHY IT EXISTS

The coverage gate requires the page store to reach one hundred percent on every
Devel::Cover metric, including branch and condition. Several of the store's
defensive paths - missing and empty page ids, id inheritance for parsed pages
without a bookmark, the strict-then-lenient UTF-8 decode fallback, legacy JSON
migration skips, and the write/read/unlink failure exits - are never touched by
the happy-path suite. This test exercises each of them directly so those guards
cannot silently rot or be removed.

=head1 WHEN TO USE

Use this file when changing saved-page file layout, page id normalization,
transient encoding, legacy JSON migration, or the raw-file decode behaviour in
the page store. Re-run it whenever a page-store branch is added or reshaped.

=head1 HOW TO USE

Run C<perl -Ilib t/73-pagestore-coverage.t> or C<prove -lv t/73-pagestore-coverage.t>
while iterating. Confirm the page store stays fully covered under the repository
coverage gate before release. The permission-based cases self-skip when run as
the superuser, which bypasses the directory and file permission bits they probe.

=head1 WHAT USES IT

The repository test suite and the Devel::Cover coverage gate run this file to
keep the page store's error and migration branches verified end to end.

=head1 EXAMPLES

Example 1:

  perl -Ilib t/73-pagestore-coverage.t

Run the page-store coverage regression by itself.

Example 2:

  prove -lv t/73-pagestore-coverage.t

Run it verbosely through the harness while iterating on the page store.

Example 3:

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lr t

Recheck the page store under the repository coverage gate.

=cut
