use strict;
use warnings;
use utf8;

# Micro-repro v6 for Jenkins build #108: t/05 tests 782 and 809 fail
# on Windows only. Both read accumulated RESULT JSON from an earlier
# hook's captured stdout and get one extra trailing newline: the file
# (782) / the RESULT entry (809) holds "hook-one\n\n" / "custom-hook\n\n"
# instead of "hook-one\n" / "custom-hook\n". Build #108's console was
# read byte-by-byte (od -c): the got value is two LF newlines, no CR,
# so this is NOT a CRLF-in-the-value defect - the capture itself gains
# a newline somewhere between the hook printing "hook-one\n" and the
# later hook reading it back.
#
# This micro isolates the three stages of that path, dumping the exact
# bytes (CR -> [CR], LF -> [LF]) at each one, so the next fix targets
# the stage that actually adds the newline:
#  Stage A (drain): spawn the real hook file (00-first.pl, prints
#    "hook-one\n", warns "hook-one-err\n") through IPC::Open3 exactly
#    as bin/d2's _run_command_hook_streaming does, and drain it with
#    StreamDrain::_drain_child_streams_windows on Windows (select loop
#    elsewhere). If the capture is already "hook-one\n\n" here, the
#    drain/child is the culprit.
#  Stage B (RESULT round-trip): push the captured stdout through
#    Runtime::Result::set_current / stdout(), the JSON env channel
#    later hooks read. If it gains the newline here, RESULT is.
#  Stage C (file round-trip): write the round-tripped value to a file
#    and read it back, exactly as the second hook (782) and the test
#    do. If it gains the newline here, the file write/read is.
# All loops are bounded; every stage logs BEFORE/AFTER with wall-clock
# times, so a stuck stage is still named by its BEFORE line.

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so
# this process runs the tip's Perl modules exactly like the CLI
# subprocesses already do (same drift fix as t/05, commit cbf9855d).
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(getcwd);
use Developer::Dashboard::PerlEnv;
use Developer::Dashboard::Platform qw(command_argv_for_path);
use Developer::Dashboard::Runtime::Result;
use File::Temp qw(tempdir);
use IO::Select;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;
use Time::HiRes qw(time);

my $repo = getcwd();
my @built_perl_libs = grep { -d $_ } map { File::Spec->catdir( $repo, 'blib', $_ ) } qw(arch lib);
local $ENV{PERL5LIB} = join Developer::Dashboard::PerlEnv::path_separator(), grep { defined && $_ ne '' } ( @built_perl_libs, $ENV{PERL5LIB} || () );

my $IS_WINDOWS = $^O eq 'MSWin32';

my $T0 = time();

sub _elapsed {
    return sprintf( '%.1fs', time() - $T0 );
}

sub _log {
    my ($msg) = @_;
    diag( '[' . _elapsed() . "] $msg" );
}

# _show($value): render a string with control bytes visible, so the
# console shows the exact bytes unambiguously (no CR/LF rendering
# doubt, the trap build #108's console set).
sub _show {
    my ($value) = @_;
    return 'undef' if !defined $value;
    my $shown = $value;
    $shown =~ s/\r/[CR]/g;
    $shown =~ s/\n/[LF]/g;
    $shown =~ s/\t/[TAB]/g;
    return "'$shown' (length " . length($value) . ')';
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

    # The real hook fixture, byte-identical to t/05's 00-first.pl.
    my $hook = File::Spec->catfile( $home, '00-first.pl' );
    open my $hook_fh, '>', $hook or die "Unable to write $hook: $!";
    print {$hook_fh} "#!/usr/bin/env perl\nprint \"hook-one\\n\";\nwarn \"hook-one-err\\n\";\n";
    close $hook_fh or die "Unable to close $hook: $!";
    chmod 0755, $hook or die "Unable to chmod $hook: $!";

    # Stage A: spawn + drain, exactly as bin/d2 _run_command_hook_streaming.
    _log('BEFORE stage A (drain): open3 + drain the hook');
    my $captured_stdout = '';
    my $captured_stderr = '';
    my $child_exit;
    {
        open my $stdin, '<', File::Spec->devnull() or die "Unable to open " . File::Spec->devnull() . " for hook stdin: $!";
        my $stderr = gensym();
        my $stdout;
        my @command = command_argv_for_path($hook);
        _log( 'stage A command: ' . join( ' ', @command ) );
        my $pid = open3( $stdin, $stdout, $stderr, @command );
        close $stdin;
        if ($IS_WINDOWS) {
            require Developer::Dashboard::StreamDrain;
            my $drained = Developer::Dashboard::StreamDrain::_drain_child_streams_windows(
                undef,
                $stdout,
                $stderr,
                sub {
                    my ( $is_stdout, $chunk ) = @_;
                    if ($is_stdout) {
                        $captured_stdout .= $chunk;
                    }
                    else {
                        $captured_stderr .= $chunk;
                    }
                },
            );
            _log("stage A drain returned: $drained");
        }
        else {
            my $selector = IO::Select->new( $stdout, $stderr );
            my $stdout_fd = fileno($stdout);
            my $stderr_fd = fileno($stderr);
            while ( my @ready = $selector->can_read ) {
                for my $fh (@ready) {
                    my $buffer = '';
                    my $read = sysread( $fh, $buffer, 8192 );
                    if ( !defined $read || $read == 0 ) {
                        $selector->remove($fh);
                        close $fh;
                        next;
                    }
                    if ( fileno($fh) == $stdout_fd ) {
                        $captured_stdout .= $buffer;
                    }
                    elsif ( fileno($fh) == $stderr_fd ) {
                        $captured_stderr .= $buffer;
                    }
                }
            }
        }
        waitpid( $pid, 0 );
        $child_exit = $? >> 8;
    }
    _log("AFTER stage A: child exit=$child_exit, stdout=" . _show($captured_stdout) . ', stderr=' . _show($captured_stderr));
    is( $captured_stdout, "hook-one\n", 'micro hook drain captures exactly one trailing newline' );

    # Stage B: RESULT JSON round-trip.
    _log('BEFORE stage B (RESULT round-trip): set_current + stdout()');
    my %results = (
        '00-first.pl' => {
            stdout    => $captured_stdout,
            stderr    => $captured_stderr,
            exit_code => $child_exit,
        },
    );
    Developer::Dashboard::Runtime::Result::set_current( \%results );
    my $round_tripped = Developer::Dashboard::Runtime::Result::stdout('00-first.pl');
    _log( 'AFTER stage B: stdout()=' . _show($round_tripped) );
    is( $round_tripped, "hook-one\n", 'micro RESULT round-trip keeps exactly one trailing newline' );

    # Stage C: file write + read, exactly as the second hook + test do.
    _log('BEFORE stage C (file round-trip): write + slurp');
    my $file = File::Spec->catfile( $home, 'hook-result.txt' );
    open my $out_fh, '>', $file or die "Unable to write $file: $!";
    print {$out_fh} $round_tripped;
    close $out_fh or die "Unable to close $file: $!";
    my $read_back = _slurp($file);
    _log( 'AFTER stage C: file content=' . _show($read_back) );
    is( $read_back, "hook-one\n", 'micro file round-trip keeps exactly one trailing newline' );
}

done_testing();
