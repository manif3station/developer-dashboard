use strict;
use warnings;
use utf8;

use Cwd qw(getcwd);
use Developer::Dashboard::Collector;
use Developer::Dashboard::JSON qw(json_encode);
use Developer::Dashboard::PathRegistry;
use Encode qw(decode);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;
use FindBin;

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

# Micro-repro for t/05 line 1111: housekeeper rotation is a no-op on Windows
# (the 6-line collector log comes back unrotated, housekeeper still ok=1).
# This file only DUMPS: the in-process path resolution, the subprocess path
# resolution (via the helper file), the raw log bytes before/after, and both
# housekeeper JSON summaries. It asserts nothing about rotation, so the
# output is the verdict. Probe branch only, never merge.

my $repo = getcwd();
local $ENV{HOME} = tempdir( CLEANUP => 1 );
chdir $ENV{HOME} or die "Unable to chdir to $ENV{HOME}: $!";
my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
my $helper    = File::Spec->catfile( $FindBin::Bin, '999-micro-1111-helper.pl' );

sub _esc {
    my ($s) = @_;
    $s = '' if !defined $s;
    $s =~ s/\r/[CR]/g;
    $s =~ s/\n/[LF]\n/g;
    return $s;
}

sub _run_micro {
    my ($cmd) = @_;
    diag("RUN: $cmd");
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => {} } );
    diag("EXIT: $exit_code");
    die "command failed ($exit_code): $cmd\nSTDOUT: $stdout\nSTDERR: $stderr\n" if $exit_code != 0;
    return decode( 'UTF-8', $stdout . $stderr );
}

sub _run_in_home_micro {
    my ( $home, $cmd ) = @_;
    return _run_micro("cd '$home' && $cmd");
}

{
    diag('MICRO-1111 START');
    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
    diag("collector_home=$home");

    diag('STEP init');
    my $init = _run_in_home_micro( $home, "$perl -I'$lib' '$dashboard' init" );
    diag("init output: $init");

    diag('STEP write config');
    my $config_file = File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' );
    open my $cfh, '>:raw', $config_file or die "Unable to write $config_file: $!";
    print {$cfh} json_encode(
        {
            collectors => [
                {
                    name     => 'rotating.collector',
                    command  => q{printf 'rotate\n'},
                    cwd      => 'home',
                    rotation => { lines => 4 },
                },
            ],
        }
    );
    close $cfh or die "Unable to close $config_file: $!";
    diag("config written: $config_file");

    diag('STEP in-process paths');
    my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
    my $store = Developer::Dashboard::Collector->new( paths => $paths );
    diag( 'in-process home=' . $paths->home() );
    diag( 'in-process cwd=' . getcwd() );
    diag( 'in-process runtime_layers=' . join( ' | ', $paths->runtime_layers() ) );
    diag( 'in-process runtime_root=' . $paths->runtime_root() );
    diag( 'in-process state_root=' . $paths->state_root() );
    diag( 'in-process collectors_root=' . $paths->collectors_root() );
    my $log = $store->collector_paths('rotating.collector')->{log};
    diag("in-process collector_log=$log");
    diag( 'in-process collector_log_exists=' . ( -f $log ? 1 : 0 ) );

    diag('STEP write 6-line log');
    open my $lfh, '>', $log or die "Unable to write $log: $!";
    print {$lfh} "line-1\nline-2\nline-3\nline-4\nline-5\nline-6\n";
    close $lfh or die "Unable to close $log: $!";
    diag('wrote 6 lines');

    diag('STEP read back raw bytes');
    open my $rfh, '<:raw', $log or die "Unable to read $log: $!";
    my $raw_before = do { local $/; <$rfh> };
    close $rfh or die "Unable to close $log: $!";
    diag( 'raw before bytes=' . length($raw_before) . ' content=[' . _esc($raw_before) . ']' );

    diag('STEP subprocess probe');
    my $probe = _run_in_home_micro( $home, "$perl -I'$lib' '$helper'" );
    diag("probe output:\n$probe");

    diag('STEP housekeeper --dry-run');
    my $dry = _run_in_home_micro( $home, "$perl -I'$lib' '$dashboard' housekeeper --dry-run" );
    diag("dry-run JSON: $dry");

    diag('STEP housekeeper');
    my $real = _run_in_home_micro( $home, "$perl -I'$lib' '$dashboard' housekeeper" );
    diag("housekeeper JSON: $real");

    diag('STEP read back after');
    open my $afh, '<:raw', $log or die "Unable to read $log: $!";
    my $raw_after = do { local $/; <$afh> };
    close $afh or die "Unable to close $log: $!";
    diag( 'raw after bytes=' . length($raw_after) . ' content=[' . _esc($raw_after) . ']' );
    diag('MICRO-1111 END');
}

pass('micro 1111 dump complete');
done_testing();
