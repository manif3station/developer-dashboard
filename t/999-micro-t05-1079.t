use strict;
use warnings;
use utf8;

# MICRO v5 for t/05 1079: confirm layer B and test the fix. v4 proved the
# quotes are stripped even via -EncodedCommand and -File, so a second layer
# exists downstream of the -Command handoff. Two candidates for it:
#   (B1) PowerShell 5.1 native-argument forwarding strips embedded quotes
#        when it builds the native command line;
#   (B2) Capture::Tiny (used by the v4 probes) mangles the captured text.
# Probe 1 decides: printf piped to Out-File, no capture involved at all.
# Probe 2 tests the fix end to end: the same printf with backslash-escaped
# quotes, delivered via -EncodedCommand (so layer A cannot touch it). If it
# prints {"a":123}, the fix is -EncodedCommand delivery plus escaping " as
# \" inside single-quoted strings. Probe 3 checks whether pwsh exists on
# the node (alternative fix path). Scratch probe, NEVER merge. Windows-only,
# diag() + dump file, intentional failure at the end.

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Developer::Dashboard::PerlEnv;
use Encode qw(decode encode);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use MIME::Base64 qw(encode_base64);
use Test::More;
use FindBin;

if ( $^O ne 'MSWin32' ) {
    plan skip_all => 'micro targets Windows only';
}

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );

local $ENV{HOME} = tempdir( CLEANUP => 1 );
my $repo = getcwd();
my @built_perl_libs = grep { -d $_ } map { File::Spec->catdir( $repo, 'blib', $_ ) } qw(arch lib);
local $ENV{PERL5LIB} = join Developer::Dashboard::PerlEnv::path_separator(),
    grep { defined && $_ ne '' } ( @built_perl_libs, $ENV{PERL5LIB} || () );
my $home = $ENV{HOME};

my $dump_file = File::Spec->catfile( $repo, 'micro-1079-dump.txt' );
open my $dump_fh, '>', $dump_file or die "Unable to write $dump_file: $!";
$dump_fh->autoflush(1);
sub _dump {
    my ($msg) = @_;
    diag($msg);
    print {$dump_fh} "$msg\n";
}

sub _run_encoded {
    my ( $label, $script ) = @_;
    _dump("MICRO-1079: $label, before script=[$script]");
    my $encoded = encode_base64( encode( 'UTF-16LE', $script ), '' );
    my ( $out, $err, $rc ) = capture {
        system( 'powershell', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-EncodedCommand', $encoded );
        $? >> 8;
    };
    _dump("MICRO-1079: $label, after rc=$rc stdout=[$out] stderr=[$err]");
    return $out;
}

_dump("MICRO-1079: os=$^O home=$home");

my ( $out_fh, $out_file ) = tempfile( 'micro-1079-out-XXXXXX', SUFFIX => '.txt', TMPDIR => 1, UNLINK => 0 );
close $out_fh or die "Unable to close $out_file: $!";
my $out_ps = $out_file;
_dump('MICRO-1079: probe 1 Out-File, before');
_run_encoded( 'probe 1 Out-File run',
    qq{printf '{"a":123}' | Out-File -Encoding ascii '$out_ps'} );
open my $read_fh, '<', $out_file or die "Unable to read $out_file: $!";
my $out_content = do { local $/; <$read_fh> };
close $read_fh or die "Unable to close $out_file: $!";
_dump( 'MICRO-1079: probe 1 Out-File content=[' . ( defined $out_content ? $out_content : '(undef)' ) . ']' );

_run_encoded( 'probe 2 backslash through EncodedCommand', q{printf '{\"a\":123}'} );

_dump('MICRO-1079: probe 3 pwsh check, before');
my ( $pwsh_out, $pwsh_err, $pwsh_rc ) = capture {
    system( 'where.exe', 'pwsh' );
    $? >> 8;
};
_dump("MICRO-1079: probe 3 pwsh check, after rc=$pwsh_rc stdout=[$pwsh_out] stderr=[$pwsh_err]");

_dump('MICRO-1079: probe 4 baseline CommandRunner, before');
require Developer::Dashboard::CommandRunner;
my ( $cr_out, $cr_err, $cr_rc, $cr_timed_out ) = Developer::Dashboard::CommandRunner::run_command(
    source     => q{printf '{"a":123}'},
    cwd        => $home,
    timeout_ms => 30_000,
);
_dump("MICRO-1079: probe 4 baseline CommandRunner, after rc=$cr_rc timed_out=$cr_timed_out stdout=[$cr_out] stderr=[$cr_err]");

close $dump_fh or die "Unable to close $dump_file: $!";
fail('micro dump complete');
done_testing();
