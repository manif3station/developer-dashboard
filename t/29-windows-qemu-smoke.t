use strict;
use warnings;

use Capture::Tiny qw(capture);
use Cwd qw(abs_path getcwd);
use File::Basename qw(dirname);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $root   = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $runner = File::Spec->catfile( $root, 'integration', 'windows', 'run-host-windows-smoke.sh' );

my $should_run = $ENV{DD_WINDOWS_QEMU_SMOKE} || 0;

if ( !$should_run ) {
    plan skip_all => 'Set DD_WINDOWS_QEMU_SMOKE=1 after configuring WINDOWS_QEMU_ENV_FILE or a windows-qemu.env file to run the live Windows QEMU smoke';
}

my $env_file = $ENV{WINDOWS_QEMU_ENV_FILE};
if ( !$env_file || !-f $env_file ) {
    my $project_env = File::Spec->catfile( getcwd(), '.developer-dashboard', 'windows-qemu.env' );
    my $home_env    = File::Spec->catfile( $ENV{HOME} || '', '.developer-dashboard', 'windows-qemu.env' );
    $env_file = -f $project_env ? $project_env : $home_env;
}

ok( -f $runner, 'Windows host rerun helper exists' );
ok( -x $runner, 'Windows host rerun helper is executable' );
ok( -f $env_file, 'Windows QEMU env file exists for the live smoke run' );

my ( $stdout, $stderr ) = capture {
    system $runner;
};
my $exit = $? >> 8;

is( $exit, 0, 'Windows host rerun helper exits successfully' );
like( $stdout, qr/QEMU Windows smoke passed|Windows Strawberry Perl smoke passed/, 'Windows host rerun helper reports a successful Windows smoke run' );
is( $stderr, '', 'Windows host rerun helper keeps stderr clean' );

done_testing();

__END__

=head1 NAME

29-windows-qemu-smoke.t - optionally run the live Windows QEMU smoke helper

=head1 DESCRIPTION

This test is skipped unless C<DD_WINDOWS_QEMU_SMOKE=1> is set. When enabled,
it expects the checked-in Windows QEMU env-file configuration to be available
and runs the host-side Windows QEMU smoke helper end to end.

=cut
