use strict;
use warnings;
use utf8;

# MICRO v4 for t/05 1079: test whether the native boundary is clean, using
# spawn paths the handoff cannot mangle. v3 proved the script PowerShell
# executes is already mangled (Write-Output, a cmdlet, lost the quotes), so
# the stripping is at or before PowerShell receives the -Command string.
# These two probes bypass -Command entirely, with args that contain no
# spaces or quotes, so the argv joining cannot interfere:
#   probe 1: powershell -EncodedCommand <base64 UTF-16LE of the script>
#   probe 2: powershell -ExecutionPolicy Bypass -File <temp .ps1>
# If either prints {"a":123}, the native boundary is clean and the fix is to
# stop passing the command through the -Command argv (EncodedCommand is the
# cleanest). If both print {a:123}, the native boundary also strips and a
# different fix is needed. Scratch probe, NEVER merge. Windows-only,
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

_dump("MICRO-1079: os=$^O home=$home");

my $script = q{printf '{"a":123}'};

_dump('MICRO-1079: probe 1 EncodedCommand, before');
my $encoded = encode_base64( encode( 'UTF-16LE', $script ), '' );
_dump("MICRO-1079: probe 1 encoded=[$encoded]");
my ( $enc_out, $enc_err, $enc_rc ) = capture {
    system( 'powershell', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encoded );
    $? >> 8;
};
_dump("MICRO-1079: probe 1 EncodedCommand, after rc=$enc_rc stdout=[$enc_out] stderr=[$enc_err]");

_dump('MICRO-1079: probe 2 File, before');
my ( $ps_fh, $ps_file ) = tempfile( 'micro-1079-XXXXXX', SUFFIX => '.ps1', TMPDIR => 1, UNLINK => 0 );
print {$ps_fh} $script or die "Unable to write $ps_file: $!";
close $ps_fh or die "Unable to close $ps_file: $!";
_dump("MICRO-1079: probe 2 script file=[$ps_file]");
my ( $file_out, $file_err, $file_rc ) = capture {
    system( 'powershell', '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $ps_file );
    $? >> 8;
};
_dump("MICRO-1079: probe 2 File, after rc=$file_rc stdout=[$file_out] stderr=[$file_err]");

_dump('MICRO-1079: probe 3 baseline CommandRunner, before');
require Developer::Dashboard::CommandRunner;
my ( $cr_out, $cr_err, $cr_rc, $cr_timed_out ) = Developer::Dashboard::CommandRunner::run_command(
    source     => $script,
    cwd        => $home,
    timeout_ms => 30_000,
);
_dump("MICRO-1079: probe 3 baseline CommandRunner, after rc=$cr_rc timed_out=$cr_timed_out stdout=[$cr_out] stderr=[$cr_err]");

close $dump_fh or die "Unable to close $dump_file: $!";
fail('micro dump complete');
done_testing();
