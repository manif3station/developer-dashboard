use strict;
use warnings;
use utf8;

# Micro-repro v5 for Jenkins builds #99/#100/#101: t/05 test 781
# (d2 which --edit jq) never runs the fake editor on Windows.
#
# Builds #99/#100 proved the editor log is never written and the test
# process dies at the log read (exit 2 after test 780). Build #101
# proved the Which.pm entrypoint fix (0f2b3f55) did not change the
# outcome: no DD-910 die fired, so the re-entry exec either never ran
# the new code or still fails silently. This micro splits the chain
# into its three halves and measures each one separately, so the next
# fix targets the half that actually fails:
#  Phase 1 (in-process): does _dashboard_entry_command() resolve to a
#    runnable entrypoint, and does command_in_path_direct('d2') find
#    anything on this box?
#  Phase 2 (system half): does Perl's block-form system() run a .bat
#    file by full path on Windows at all (the exact call _exec_raw
#    makes), and does the .bat write its log?
#  Phase 3 (open-file half): does `d2 open-file <file>` with EDITOR
#    set to the .bat write the log?
#  Phase 4 (which half): does `d2 which --edit jq` with EDITOR set to
#    the .bat write the log (the exact failing scenario)?
# All loops are bounded; every phase logs BEFORE/AFTER with wall-clock
# times, so a stuck phase is still named by its BEFORE line.

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so
# this process runs the tip's Perl modules exactly like the CLI
# subprocesses already do (same drift fix as t/05, commit cbf9855d).
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Developer::Dashboard::GoRoutine ();
use Developer::Dashboard::JSON qw(json_decode);
use Developer::Dashboard::PerlEnv;
use Developer::Dashboard::Platform qw(command_in_path_direct);
use Encode qw(decode);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use LWP::UserAgent;
use Test::More;
use Time::HiRes qw(sleep time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo = getcwd();
my @built_perl_libs = grep { -d $_ } map { File::Spec->catdir( $repo, 'blib', $_ ) } qw(arch lib);
local $ENV{PERL5LIB} = join Developer::Dashboard::PerlEnv::path_separator(), grep { defined && $_ ne '' } ( @built_perl_libs, $ENV{PERL5LIB} || () );
local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

my $T0 = time();

sub _elapsed {
    return sprintf( '%.1fs', time() - $T0 );
}

sub _log {
    my ($msg) = @_;
    diag( '[' . _elapsed() . "] $msg" );
}

sub _run_logged {
    my ( $label, $cmd ) = @_;
    _log("BEFORE $label: $cmd");
    my $start = time();
    my %env;
    if ( $cmd =~ /\Q'$dashboard'\E\s+(?:serve|restart|stop|which|open-file)\b/ ) {
        $env{PERL5OPT}              = undef;
        $env{HARNESS_PERL_SWITCHES} = undef;
    }
    my ( $stdout, $stderr, $exit_code ) = run_shell_command( $cmd, { env => \%env } );
    _log( sprintf( 'AFTER %s: exit=%d in %.1fs', $label, $exit_code, time() - $start ) );
    _log("$label stdout: $stdout") if defined $stdout && $stdout ne '';
    _log("$label stderr: $stderr") if defined $stderr && $stderr ne '';
    return ( decode( 'UTF-8', $stdout . $stderr ), $exit_code );
}

sub _slurp {
    my ($path) = @_;
    return undef if !-f $path;
    open my $fh, '<', $path or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

{
    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
    local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
    local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
    local $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT};
    delete $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT};

    my ( $out, $rc );
    ( $out, $rc ) = _run_logged( 'init', "cd '$home' && $perl -I'$lib' '$dashboard' init" );
    like( $out, qr/runtime_root/, 'micro init initializes a runtime' );
    my $runtime_jq = File::Spec->catfile( $home, '.developer-dashboard', 'cli', 'dd', 'jq' );
    ok( -f $runtime_jq, 'micro init seeds the jq helper' );

    my $editor_log = File::Spec->catfile( $home, 'which-editor.log' );
    my $editor_bat = File::Spec->catfile( $home, 'fake-editor.bat' );
    open my $bat_fh, '>', $editor_bat or die "Unable to write $editor_bat: $!";
    print {$bat_fh} <<"BAT";
\@echo off
echo %*>"$editor_log"
BAT
    close $bat_fh;
    ok( -f $editor_bat, 'micro fake-editor.bat written' );

    # Phase 1: entrypoint resolution, in-process. Proves whether the
    # 0f2b3f55 fix runs here and what it resolves to. ($0 here is this
    # test file, not bin/d2, so the fallback value is only diagnostic.)
    require Developer::Dashboard::CLI::Which;
    my $d2_on_path = command_in_path_direct('d2');
    _log( 'command_in_path_direct(d2): ' . ( defined $d2_on_path ? $d2_on_path : 'undef (no runnable d2 on PATH)' ) );
    _log( sprintf( '$0 is %s: -f=%d -x=%d', $0, -f $0 ? 1 : 0, -x $0 ? 1 : 0 ) );
    my @entry = Developer::Dashboard::CLI::Which::_dashboard_entry_command();
    _log( 'dashboard_entry_command() returns: [' . join( ', ', map { "'$_'" } @entry ) . ']' );
    _log("\$0 in this process: $0");
    ok( 1, 'micro entrypoint resolution logged' );

    # Phase 2: Perl block-form system() on a .bat by full path, the
    # exact call OpenFile::_exec_raw makes on Windows.
    _log("BEFORE system-bat: system { '$editor_bat' } '$editor_bat', '$runtime_jq'");
    my $sys_start = time();
    my $sys_rc;
    {
        local $SIG{__WARN__} = sub { _log("system-bat warning: $_[0]") };
        $! = 0;
        $sys_rc = system { $editor_bat } $editor_bat, $runtime_jq;
    }
    _log( sprintf( 'AFTER system-bat: rc=%d ($! = %s) in %.1fs', $sys_rc, $! // '', time() - $sys_start ) );
    my $log_after_system = _slurp($editor_log);
    _log( 'log after system-bat: ' . ( defined $log_after_system ? "'$log_after_system'" : 'MISSING (never written)' ) );
    ok( defined $log_after_system, 'micro block-form system runs the .bat and writes the log' );
    unlink $editor_log if -f $editor_log;

    # Phase 3: the open-file half, as a subprocess with EDITOR set.
    {
        local $ENV{EDITOR} = $editor_bat;
        ( $out, $rc ) = _run_logged( 'open-file', "cd '$home' && $perl -I'$lib' '$dashboard' open-file '$runtime_jq'" );
    }
    my $log_after_open = _slurp($editor_log);
    _log( 'log after open-file: ' . ( defined $log_after_open ? "'$log_after_open'" : 'MISSING (never written)' ) );
    is( $rc, 0, 'micro d2 open-file exits 0' );
    ok( defined $log_after_open, 'micro d2 open-file invokes the .bat editor and writes the log' );
    unlink $editor_log if -f $editor_log;

    # Phase 4: the which half, the exact failing scenario.
    {
        local $ENV{EDITOR} = $editor_bat;
        ( $out, $rc ) = _run_logged( 'which-edit', "cd '$home' && $perl -I'$lib' '$dashboard' which --edit jq" );
    }
    my $log_after_which = _slurp($editor_log);
    _log( 'log after which --edit: ' . ( defined $log_after_which ? "'$log_after_which'" : 'MISSING (never written)' ) );
    is( $rc, 0, 'micro d2 which --edit exits 0' );
    ok( defined $log_after_which, 'micro d2 which --edit invokes the .bat editor and writes the log' );
    unlink $editor_log if -f $editor_log;
}

done_testing;
