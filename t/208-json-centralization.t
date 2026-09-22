#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use JSON::XS ();
use File::Temp qw(tempdir);
use File::Spec;
use IO::Socket::UNIX;

use lib 'lib';

use Developer::Dashboard::JSON qw(json_encode json_encode_with_options json_decode);
use Developer::Dashboard::Pax::ArtifactCache ();
use Developer::Dashboard::Pax::AppImage ();
use Developer::Dashboard::Pax::AppServer ();
use Developer::Dashboard::Pax::CLI ();

# --------------------------------------------------------------------------
# AC-3 (unit slice): json_encode_with_options reproduces every option
# combination the 9 DD-1002 call sites actually used, byte-for-byte
# identical to constructing JSON::XS directly with the same options - this
# is what makes the later per-call-site conversion behavior-preserving.
# --------------------------------------------------------------------------

my $payload = { b => 2, a => 1, unicode => "caf\x{e9}" };

{
    my $expected = JSON::XS->new->canonical(1)->pretty(1)->encode($payload);
    is( json_encode_with_options( $payload, pretty => 1 ), $expected,
        'canonical+pretty (matches Pax/ArtifactCache.pm:30 pre-change options)' );
}

{
    my $expected = JSON::XS->new->canonical(1)->encode($payload);
    is( json_encode_with_options($payload), $expected,
        'canonical only, no other options (matches Pax/ArtifactCache.pm:45 and Pax/ProfileGuidedAOT.pm:50)' );
}

{
    my $expected = JSON::XS->new->ascii(1)->canonical(1)->encode($payload);
    is( json_encode_with_options( $payload, ascii => 1 ), $expected,
        'ascii+canonical, no pretty (matches Pax/Capture.pm:303, Pax/AppServer.pm:36, Pax/CLI.pm:1512)' );
}

{
    my $expected = JSON::XS->new->ascii(1)->canonical(1)->pretty(1)->encode($payload);
    is( json_encode_with_options( $payload, ascii => 1, pretty => 1 ), $expected,
        'ascii+canonical+pretty (matches Pax/AppImage.pm:425 and some Pax/StandaloneImage.pm sites)' );
}

{
    my $expected = JSON::XS->new->utf8(1)->ascii(1)->canonical(1)->encode($payload);
    is( json_encode_with_options( $payload, utf8 => 1, ascii => 1 ), $expected,
        'utf8+ascii+canonical, no pretty (matches Pax/CodeUnitCompiler.pm\'s 6 sites)' );
}

{
    my $expected = JSON::XS->new->utf8->canonical->pretty->encode($payload);
    is( json_encode($payload), $expected, 'json_encode itself is unchanged by this addition' );
}

# --------------------------------------------------------------------------
# AC-1: no lib/Developer/Dashboard/Pax/*.pm module (excluding
# StandaloneRuntime.pm, CodeUnitCompiler.pm's own regex-recognition lines,
# and Pax/Capture.pm:303's documented exception below) constructs
# JSON::XS->new directly any more.
# --------------------------------------------------------------------------
{
    # Pax/Capture.pm's isolated child-probe script (inside the
    # _probe_source heredoc, executed via open3($^X, '-', ...) with no -I
    # lib path, so the child's @INC has no guaranteed way to find
    # Developer::Dashboard::JSON) is a documented exception - identified by
    # its own explanatory comment immediately above the call, not by a
    # brittle fixed line number.
    my @hits;
    for my $file ( glob('lib/Developer/Dashboard/Pax/*.pm') ) {
        next if $file =~ m{StandaloneRuntime\.pm$};
        open my $fh, '<', $file or die "cannot read $file: $!";
        my @lines = <$fh>;
        close $fh;
        for my $i ( 0 .. $#lines ) {
            my $line = $lines[$i];
            next if $line !~ /JSON::XS->new/;
            next if $line =~ /^\s*#/;    # a comment mentioning the pattern, not a real call

            # A line matching JSON::XS->new AGAINST OTHER TEXT (a regex
            # match, `=~`) is recognizing source text, not constructing an
            # object - CodeUnitCompiler.pm's own self-compilation
            # recognition of json_encode/json_decode's bodies.
            next if $line =~ /=~/;

            # The documented probe-isolation exception carries its own
            # explanatory comment on the line directly above it.
            next if $i > 0 && $lines[ $i - 1 ] =~ /Deliberately kept as a direct/;

            push @hits, "$file:" . ( $i + 1 );
        }
    }
    is_deeply( \@hits, [], 'AC-1: zero undocumented direct JSON::XS->new construction sites remain outside StandaloneRuntime.pm, CodeUnitCompiler.pm\'s regex-recognition lines, and Pax/Capture.pm:303\'s documented probe-isolation exception' )
      or diag( "remaining direct construction sites: " . join( ', ', @hits ) );
}

# --------------------------------------------------------------------------
# AC-2 (call-site slice): the 4 converted call sites this run's Devel::Cover
# pass found ZERO other test in the whole suite ever loading (ArtifactCache,
# AppImage, AppServer, Pax::CLI) are exercised here directly, so each
# converted line has real execution evidence rather than only the isolated
# json_encode_with_options unit proof above. DD-1011 tracks the unrelated,
# pre-existing t/43 usage-string regression found during this same coverage
# run; this block is DD-1002's own obligation, not that one's.
# --------------------------------------------------------------------------

{
    # ArtifactCache.pm: write_artifact (pretty=>1 site) and metadata_for
    # (no-options site) both converted.
    my $dir = tempdir( CLEANUP => 1 );
    my $cache = Developer::Dashboard::Pax::ArtifactCache->new( root => $dir );
    my $manifest = { runtime => { perl_config_version => '5.40.1', archname => 'x86_64' }, module_graph => { modules => ['Foo'] } };
    my $result = $cache->write_artifact( manifest => $manifest, artifact => { blob => 'x' } );
    ok( -e $result->{path}, 'ArtifactCache::write_artifact wrote a file via json_encode_with_options(pretty=>1)' );
    open my $fh, '<', $result->{path} or die $!;
    local $/;
    my $written = <$fh>;
    close $fh;
    my $decoded = eval { JSON::XS::decode_json($written) };
    ok( $decoded && $decoded->{metadata}{artifact_id}, 'the written artifact JSON round-trips and metadata_for\'s json_encode_with_options(no options) call produced a real artifact_id' );
}

{
    # AppImage.pm: _write_json (ascii+pretty site).
    my $dir = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'manifest.json' );
    Developer::Dashboard::Pax::AppImage::_write_json( $path, { a => 1, unicode => "caf\x{e9}" } );
    ok( -e $path, 'AppImage::_write_json wrote a file' );
    open my $fh, '<', $path or die $!;
    local $/;
    my $written = <$fh>;
    close $fh;
    my $decoded = eval { JSON::XS::decode_json($written) };
    is( $decoded->{a}, 1, 'AppImage::_write_json(ascii=>1,pretty=>1) round-trips' );
    unlike( $written, qr/\xc3\xa9/, 'ascii=>1 escaped the non-ASCII byte rather than emitting it raw' );
}

{
    # AppServer.pm: run_client's request-encode line (ascii, no pretty) -
    # only reached when the socket connect SUCCEEDS, so this spins up a
    # real listening UNIX socket rather than letting run_client silently
    # fall through to _direct_exec.
    my $dir = tempdir( CLEANUP => 1 );
    my $socket_path = File::Spec->catfile( $dir, 'pax.sock' );
    my $listener = IO::Socket::UNIX->new( Type => SOCK_STREAM, Local => $socket_path, Listen => 1 )
        or die "cannot listen on $socket_path: $!";
    my $pid = fork();
    if ( !defined $pid ) {
        die "fork failed: $!";
    }
    elsif ( $pid == 0 ) {
        my $client = $listener->accept;
        my $line = <$client>;
        print {$client} "__PAX_EXIT__:0\n";
        close $client;
        require POSIX;
        POSIX::_exit(0);
    }
    my $exit = Developer::Dashboard::Pax::AppServer->run_client(
        image => { socket_path => $socket_path },
        argv  => [ '--version' ],
        cwd   => '/tmp',
    );
    waitpid( $pid, 0 );
    is( $exit, 0, 'AppServer::run_client connected, encoded the request via json_encode_with_options(ascii=>1), and read back the fake server\'s exit line' );
}

{
    # Pax/CLI.pm: _json (ascii, optional pretty).
    my $compact = Developer::Dashboard::Pax::CLI::_json( { a => 1 }, 0 );
    my $pretty  = Developer::Dashboard::Pax::CLI::_json( { a => 1 }, 1 );
    is( $compact, JSON::XS->new->ascii(1)->canonical(1)->encode( { a => 1 } ), 'Pax::CLI::_json(data,0) matches the pre-change ascii+canonical, no-pretty encoding' );
    is( $pretty, JSON::XS->new->ascii(1)->canonical(1)->pretty(1)->encode( { a => 1 } ), 'Pax::CLI::_json(data,1) matches the pre-change ascii+canonical+pretty encoding' );
}

done_testing();

__END__

=pod

=head1 NAME

208-json-centralization.t - proves DD-1002's Pax JSON centralization

=head1 PURPOSE

Guards DD-1002: nine C<lib/Developer/Dashboard/Pax/*.pm> call sites hand-rolled
C<JSON::XS-E<gt>new-E<gt>...-E<gt>encode()> chains with drifted option sets
instead of the shared C<Developer::Dashboard::JSON> wrapper. This file proves
the new C<json_encode_with_options> option-variant form reproduces every
option combination those call sites used byte-for-byte, and that none of
them construct C<JSON::XS> directly any more.

=head1 WHY IT EXISTS

Without this, a future contributor could add a tenth ad hoc C<JSON::XS-E<gt>new>
call site with no guard catching it, or a conversion could silently change a
call site's output encoding (ascii/pretty/utf8) without anyone noticing.

=head1 WHEN TO USE

Run this file whenever C<Developer::Dashboard::JSON> or any
C<lib/Developer/Dashboard/Pax/*.pm> module's JSON encoding changes.

=head1 HOW TO USE

    prove -lv t/208-json-centralization.t

=head1 WHAT USES IT

C<t/21-refactor-coverage.t> covers C<Developer::Dashboard::JSON>'s
pre-existing C<json_encode>/C<json_decode> behavior; this file covers the
DD-1002 option-variant addition and the call-site conversion specifically.

=head1 EXAMPLES

C<json_encode_with_options({a=>1}, ascii=E<gt>1)> produces the identical
byte string C<JSON::XS-E<gt>new-E<gt>ascii(1)-E<gt>canonical(1)-E<gt>encode({a=E<gt>1})>
would have produced before this ticket converted the call site.

=cut
