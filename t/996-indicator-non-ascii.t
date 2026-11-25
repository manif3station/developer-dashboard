use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Developer::Dashboard::JSON qw(json_decode);
use Encode qw(encode_utf8);
use File::Temp qw(tempdir);
use Test::More;

my $repo      = getcwd();
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
my $lib       = File::Spec->catdir( $repo, 'lib' );

my $home = tempdir( CLEANUP => 1 );

# _run_d2(@args)
# Runs the checkout CLI in a child with the temp HOME and returns the
# child exit code, stdout and stderr. Arguments are passed as UTF-8
# bytes, exactly as a user's shell passes them.
sub _run_d2 {
    my (@args) = @_;
    local $ENV{HOME} = $home;
    my ( $stdout, $stderr, $exit ) = capture {
        system $^X, '-I', $lib, $dashboard, @args;
        return $? >> 8;
    };
    return ( $exit, $stdout, $stderr );
}

# _set_indicator($name, $label, $icon, $status)
# Sets one indicator through the CLI and returns the decoded record the
# set command printed.
sub _set_indicator {
    my ( $name, $label, $icon, $status ) = @_;
    my ( $exit, $stdout, $stderr ) = _run_d2(
        'indicator', 'set', $name,
        encode_utf8($label), encode_utf8($icon), $status,
    );
    is( $exit, 0, "indicator: d2 indicator set $name exits 0" );
    my $record = eval { json_decode($stdout) };
    ok( $record && ref($record) eq 'HASH', "indicator: d2 indicator set $name prints a JSON record" );
    return $record;
}

# _list_indicator($name)
# Reads one indicator back through `d2 indicator list` and
# returns its decoded record, or undef when it is not listed.
sub _list_indicator {
    my ($name) = @_;
    my ( $exit, $stdout, $stderr ) = _run_d2( 'indicator', 'list' );
    is( $exit, 0, 'indicator: d2 indicator list exits 0' );
    my $list = eval { json_decode($stdout) };
    ok( $list && ref($list) eq 'ARRAY', 'indicator: d2 indicator list prints a JSON list' );
    return undef if !$list || ref($list) ne 'ARRAY';
    for my $record ( @{$list} ) {
        return $record if $record->{name} eq $name;
    }
    return undef;
}

# T3: indicator set round-trips non-ASCII. An emoji icon and an accented
# label come back double-encoded (icon '🧪' reads back as mojibake, label
# 'café test' as 'cafÃ© test'), in the set command's own output, so the
# set path mangles them rather than the display.
{
    my $record = _set_indicator( 'faye-emoji', 'café test', '🧪', 'ok' );
    if ($record) {
        is( $record->{icon},  '🧪',        'indicator: emoji icon round-trips through indicator set' );
        is( $record->{label}, 'café test', 'indicator: accented label round-trips through indicator set' );
        is( $record->{name},  'faye-emoji', 'indicator: name round-trips through indicator set' );
    }

    my $stored = _list_indicator('faye-emoji');
    ok( $stored, 'indicator: the non-ASCII indicator is listed back' );
    if ($stored) {
        is( $stored->{icon},  '🧪',        'indicator: emoji icon round-trips through storage' );
        is( $stored->{label}, 'café test', 'indicator: accented label round-trips through storage' );
    }
}

# Control: an ASCII indicator round-trips, as it already does.
{
    my $record = _set_indicator( 'faye-ascii', 'plain test', 'A', 'ok' );
    if ($record) {
        is( $record->{icon},  'A',          'indicator: ASCII icon round-trips through indicator set' );
        is( $record->{label}, 'plain test', 'indicator: ASCII label round-trips through indicator set' );
    }

    my $stored = _list_indicator('faye-ascii');
    ok( $stored, 'indicator: the ASCII indicator is listed back' );
    if ($stored) {
        is( $stored->{icon},  'A',          'indicator: ASCII icon round-trips through storage' );
        is( $stored->{label}, 'plain test', 'indicator: ASCII label round-trips through storage' );
    }
}

done_testing();
