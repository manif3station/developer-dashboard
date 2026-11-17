use strict;
use warnings;
use utf8;

# MICRO v2 for t/05 1079: reproduce the one-shot TT-icon collector run on
# WINDOWS ONLY and dump every intermediate value. Scratch probe, NEVER merge.
# v1 lesson (build #57): plain print() is swallowed by non-verbose prove, so
# every dump line goes through diag() AND to a dump file in the checkout dir
# (backup: fetch via SSH before the next build wipes dd-source). Non-Windows
# legs skip immediately, so the fail-safe cannot SIGINT-kill the Windows leg
# before it emits its dump. Ends with an intentional failure on Windows so
# prove displays the diag lines; the fail-safe trip at the end is expected.

use Capture::Tiny qw(capture);
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

_dump("MICRO-1079: os=$^O home=$home");

_dump('MICRO-1079: step 1 d2 init, before');
my ( $init_out, $init_err, $init_rc )
    = run_shell_command( "cd '$home' && $perl -I'$lib' '$dashboard' init", {} );
_dump("MICRO-1079: step 1 d2 init, after rc=$init_rc out=[$init_out] err=[$init_err]");

_dump('MICRO-1079: step 2 write config, before');
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
_dump('MICRO-1079: step 2 write config, after');

_dump('MICRO-1079: step 3 d2 collector run, before');
my ( $run_out, $run_err, $run_rc ) = run_shell_command(
    "cd '$home' && $perl -I'$lib' '$dashboard' collector run templated.collector", {} );
_dump("MICRO-1079: step 3 d2 collector run, after rc=$run_rc");
_dump("MICRO-1079: raw stdout=[$run_out]");
_dump("MICRO-1079: raw stderr=[$run_err]");
my $payload = eval { json_decode($run_out) };
if ($@) {
    _dump("MICRO-1079: payload json_decode FAILED: $@");
}
else {
    _dump( 'MICRO-1079: payload exit_code='
            . ( defined $payload->{exit_code} ? $payload->{exit_code} : '(undef)' ) );
    _dump( 'MICRO-1079: payload stdout=[' . ( defined $payload->{stdout} ? $payload->{stdout} : '(undef)' ) . ']' );
    _dump( 'MICRO-1079: payload stderr=[' . ( defined $payload->{stderr} ? $payload->{stderr} : '(undef)' ) . ']' );
    _dump( 'MICRO-1079: payload name=' . ( defined $payload->{name} ? $payload->{name} : '(undef)' ) );
}

_dump('MICRO-1079: step 4 direct CommandRunner run_command, before');
require Developer::Dashboard::CommandRunner;
my ( $cr_out, $cr_err, $cr_rc, $cr_timed_out ) = Developer::Dashboard::CommandRunner::run_command(
    source     => q{printf '{"a":123}'},
    cwd        => $home,
    timeout_ms => 30_000,
);
_dump("MICRO-1079: step 4 direct CommandRunner, after rc=$cr_rc timed_out=$cr_timed_out");
_dump("MICRO-1079: direct stdout=[$cr_out]");
_dump("MICRO-1079: direct stderr=[$cr_err]");

_dump('MICRO-1079: step 5 json_decode of direct stdout, before');
my $decoded = eval { json_decode($cr_out) };
if ($@) {
    _dump("MICRO-1079: step 5 json_decode FAILED: $@");
}
else {
    _dump( 'MICRO-1079: step 5 json_decode ok, a='
            . ( defined $decoded->{a} ? $decoded->{a} : '(undef)' ) );
    _dump('MICRO-1079: step 6 TT render, before');
    require Template;
    my $tt = Template->new();
    my $rendered = '';
    my $tt_ok = $tt->process( \q{[% a %]}, $decoded, \$rendered );
    _dump("MICRO-1079: step 6 TT render, after ok=$tt_ok rendered=[$rendered] error=[" . ( $tt->error() // '' ) . ']');
}

_dump('MICRO-1079: step 7 shell_command_argv, before');
require Developer::Dashboard::Platform;
my @argv = Developer::Dashboard::Platform::shell_command_argv( q{printf '{"a":123}'}, login => 0 );
_dump( 'MICRO-1079: step 7 argv=[' . join( '|', @argv ) . ']' );

_dump('MICRO-1079: step 8 raw printf through the shell, before');
my ( $pf_out, $pf_err, $pf_rc ) = run_shell_command( q{printf '{"a":123}'}, {} );
_dump("MICRO-1079: step 8 raw printf, after rc=$pf_rc out=[$pf_out] err=[$pf_err]");

close $dump_fh or die "Unable to close $dump_file: $!";
fail('micro dump complete');
done_testing();
