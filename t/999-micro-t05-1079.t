use strict;
use warnings;
use utf8;

# MICRO v3 for t/05 1079: discriminate WHERE the double quotes are stripped.
# v2 proved the what: CommandRunner returns stdout {a:123} while the same
# printf through the shell returns {"a":123}. Two candidate layers:
#   (A) Perl list-form system() joining in spawn_windows_command mangles the
#       -Command argument before powershell.exe ever sees it;
#   (B) PowerShell 5.1 native-argument forwarding strips quotes at printf.
# The Write-Output discriminator decides: it is a PowerShell cmdlet, not a
# native exe, so if it prints {"a":123} the script arrived intact and the
# stripping is at the native boundary (B); if it prints {a:123} the script
# was already mangled in the spawn handoff (A). Scratch probe, NEVER merge.
# Windows-only, diag() + dump file, intentional failure at the end.

use Cwd qw(getcwd);
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Developer::Dashboard::PerlEnv;
use Encode qw(decode encode);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use FindBin;

if ( $^O ne 'MSWin32' ) {
    plan skip_all => 'micro targets Windows only';
}

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

local $ENV{HOME} = tempdir( CLEANUP => 1 );
local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
my $repo = getcwd();
my @built_perl_libs = grep { -d $_ } map { File::Spec->catdir( $repo, 'blib', $_ ) } qw(arch lib);
local $ENV{PERL5LIB} = join Developer::Dashboard::PerlEnv::path_separator(),
    grep { defined && $_ ne '' } ( @built_perl_libs, $ENV{PERL5LIB} || () );
my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
my $home      = $ENV{HOME};

my $dump_file = File::Spec->catfile( $repo, 'micro-1079-dump.txt' );
open my $dump_fh, '>', $dump_file or die "Unable to write $dump_file: $!";
$dump_fh->autoflush(1);
sub _dump {
    my ($msg) = @_;
    diag($msg);
    print {$dump_fh} "$msg\n";
}

require Developer::Dashboard::CommandRunner;
sub _run_cmd {
    my ($label, $source) = @_;
    _dump("MICRO-1079: $label, before source=[$source]");
    my ( $out, $err, $rc, $timed_out ) = Developer::Dashboard::CommandRunner::run_command(
        source     => $source,
        cwd        => $home,
        timeout_ms => 30_000,
    );
    _dump("MICRO-1079: $label, after rc=$rc timed_out=$timed_out stdout=[$out] stderr=[$err]");
}

_dump("MICRO-1079: os=$^O home=$home");

_run_cmd( 'step 1 discriminator Write-Output', q{Write-Output '{"a":123}'} );
_run_cmd( 'step 2 backslash candidate', q{printf '{\"a\":123}'} );
_run_cmd( 'step 3 space candidate', q{printf '{"a": 123}'} );
_run_cmd( 'step 4 baseline printf', q{printf '{"a":123}'} );

_dump('MICRO-1079: step 5 d2 init, before');
my ( $init_out, $init_err, $init_rc )
    = run_shell_command( "cd '$home' && $perl -I'$lib' '$dashboard' init", {} );
_dump("MICRO-1079: step 5 d2 init, after rc=$init_rc");

_dump('MICRO-1079: step 6 write config, before');
my $config_file = File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' );
make_path( dirname($config_file) );
open my $cfh, '>:raw', $config_file or die "Unable to write $config_file: $!";
print {$cfh} json_encode(
    {
        collectors => [
            {
                name    => 'templated.collector',
                command => q{printf '{"a":123}'},
                cwd     => 'home',
                indicator => {
                    name  => 'templated.indicator',
                    label => 'Templated',
                    icon  => '[% a %]',
                },
            },
        ],
    }
);
close $cfh or die "Unable to close $config_file: $!";
_dump('MICRO-1079: step 6 write config, after');

_dump('MICRO-1079: step 7 d2 collector run baseline, before');
my ( $run_out, $run_err, $run_rc ) = run_shell_command(
    "cd '$home' && $perl -I'$lib' '$dashboard' collector run templated.collector", {} );
my $payload = eval { json_decode($run_out) };
if ($@) {
    _dump("MICRO-1079: step 7 payload json_decode FAILED: $@");
}
else {
    _dump( 'MICRO-1079: step 7 payload exit_code='
            . ( defined $payload->{exit_code} ? $payload->{exit_code} : '(undef)' )
            . ' stdout=[' . ( defined $payload->{stdout} ? $payload->{stdout} : '(undef)' ) . ']' );
}

close $dump_fh or die "Unable to close $dump_file: $!";
fail('micro dump complete');
done_testing();
