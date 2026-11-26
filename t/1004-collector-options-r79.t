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
use File::Temp qw(tempdir);
use JSON::XS qw(decode_json);
use Test::More;

use Developer::Dashboard::Config;
use Developer::Dashboard::FileRegistry;
use Developer::Dashboard::PathRegistry;

my $repo      = getcwd();
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
my $lib       = File::Spec->catdir( $repo, 'lib' );

my $home = tempdir( CLEANUP => 1 );

# Declared early: _run_d2_timeout uses it, and the lookup runs below.
my $timeout_bin;

# _run_d2(@args)
# Runs the checkout CLI in a child with the temp HOME and returns the
# child exit code, stdout and stderr.
sub _run_d2 {
    my (@args) = @_;
    local $ENV{HOME} = $home;
    my ( $stdout, $stderr, $exit ) = capture {
        system $^X, '-I', $lib, $dashboard, @args;
        return $? >> 8;
    };
    return ( $exit, $stdout, $stderr );
}

# _run_d2_timeout($seconds, @args)
# Runs the checkout CLI under the timeout binary so a follow command that
# never returns is killed instead of hanging the suite. Returns the child
# exit code, stdout and stderr; `timeout` reports 124 when it kills.
sub _run_d2_timeout {
    my ( $seconds, @args ) = @_;
    local $ENV{HOME} = $home;
    my ( $stdout, $stderr, $raw_exit ) = capture {
        system( $timeout_bin, "${seconds}s", $^X, '-I', $lib, $dashboard, @args );
    };
    return ( $raw_exit >> 8, $stdout, $stderr );
}

# _pid_of($stdout)
# The start/stop/restart commands print the loop pid on stdout, or nothing
# when no loop was running. Returns the pid, or undef.
sub _pid_of {
    my ($stdout) = @_;
    my ($pid) = $stdout =~ /(\d+)/;
    return defined $pid ? $pid + 0 : undef;
}

# _wait_for_alive($pid)
# Polls until the pid answers kill 0, or the wait runs out. A loop takes a
# moment to appear after its start command returns, so a single kill 0
# would flake.
sub _wait_for_alive {
    my ($pid) = @_;
    return 0 if !defined $pid;
    for ( 1 .. 25 ) {
        return 1 if kill 0, $pid;
        select undef, undef, undef, 0.2;
    }
    return 0;
}

# _wait_for_gone($pid)
# Polls until the pid stops answering kill 0, or the wait runs out. A stop
# takes a moment to bring the loop down, so a single kill 0 would flake.
sub _wait_for_gone {
    my ($pid) = @_;
    return 1 if !defined $pid;
    for ( 1 .. 25 ) {
        return 1 if !kill 0, $pid;
        select undef, undef, undef, 0.2;
    }
    return 0;
}

# _find_command(@candidates)
# Finds the first candidate on PATH. On Windows, also tries the .exe
# names. Git's usr/bin/timeout.exe is GNU coreutils, but system32 has a
# Windows timeout.exe earlier in PATH, so a .exe candidate is only
# accepted when `--version` reports GNU (see _is_gnu_timeout). A file
# named exactly `timeout` (no extension) can never be found on Windows:
# Perl's -x is false for it, as Peter verified by copying timeout.exe to
# a file named `timeout` ( -f true, -x false). On Linux and macOS the
# .exe names are never added, so behaviour there is unchanged. Same
# lookup as t/1002.
sub _find_command {
    my @candidates = @_;
    my @names = @candidates;
    if ( $^O eq 'MSWin32' ) {
        push @names, map { "$_.exe" } @candidates;
    }
    for my $candidate (@names) {
        next if !defined $candidate || $candidate eq '';
        for my $dir ( File::Spec->path() ) {
            my $path = File::Spec->catfile( $dir, $candidate );
            next if !-f $path || !-x $path;
            next if $candidate =~ /\.exe\z/i && !_is_gnu_timeout($path);
            return $path;
        }
    }
    return undef;
}

sub _is_gnu_timeout {
    my ($path) = @_;
    my ( $stdout, $stderr, $raw_exit ) = capture {
        system( $path, '--version' );
    };
    # Capture::Tiny returns the raw wait status, so shift it to the exit
    # code. GNU --version prints "timeout (GNU coreutils) ..." and exits
    # 0; the Windows timeout.exe rejects --version at once (invalid
    # argument) and exits non-zero without "GNU" in its output.
    return ( $raw_exit >> 8 ) == 0 && $stdout =~ /GNU/;
}

# The follow test needs a timeout binary to bound the never-returning
# follow loop; without one it cannot run, so it skips. The other option
# tests do not need it.
$timeout_bin = _find_command( qw(timeout gtimeout) );

# _count_occurrences($text, $pattern)
# Counts how many times a literal string occurs in the text.
sub _count_occurrences {
    my ( $text, $pattern ) = @_;
    my $count = () = $text =~ /\Q$pattern\E/g;
    return $count;
}

# _is_json_with($stdout, $name, $pid)
# Decodes the output as JSON and checks it names the collector and its
# pid. The exact result shape is the implementer's choice (the verb-first
# form prints the stop/restart result hash), so this pins only that the
# output is valid JSON carrying the stopped or restarted collector.
sub _is_json_with {
    my ( $stdout, $name, $pid ) = @_;
    my $decoded = eval { decode_json($stdout) };
    return 0 if $@ || !defined $decoded;
    return 0 if $stdout !~ /\Q$name\E/;
    return 0 if defined $pid && $stdout !~ /\Q$pid\E/;
    return 1;
}

# Setup: init the isolated HOME, then define the example collector and run
# the built-in housekeeper once so its name is persisted. There is no CLI
# way to define a collector, so the example collector is set up through
# the config directly (the t/120 pattern: save_global with a collectors
# list). The example collector is then run three times so its log holds
# three records (four lines each: header, [stdout], example-ok, blank).
{
    my ( $exit, $stdout, $stderr ) = _run_d2('init');
    die "collector options: d2 init failed in the test HOME: $stderr" if $exit != 0;

    my $paths  = Developer::Dashboard::PathRegistry->new( home => $home );
    my $files  = Developer::Dashboard::FileRegistry->new( paths => $paths );
    my $config = Developer::Dashboard::Config->new( files => $files, paths => $paths );
    $config->save_global(
        {
            collectors => [
                { name => 'example', command => 'echo example-ok' },
            ],
        }
    );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'run', 'housekeeper' );
    die "collector options: d2 collector run housekeeper failed: $stderr" if $exit != 0;
    for ( 1 .. 3 ) {
        ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'run', 'example' );
        die "collector options: d2 collector run example failed: $stderr" if $exit != 0;
    }
}

# R79 R115, collector log options: `d2 collector log` gains the options
# the verb-first `d2 log collector` accepts today via RuntimeControl -
# -t (timestamps), -f (follow) and --tail/-n (trailing lines). The plain
# log is the control: three runs, three example-ok lines, and no line
# starts with a timestamp.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example' );
    is( $exit, 0, 'collector options: d2 collector log example exits 0' );
    is( _count_occurrences( $stdout, 'example-ok' ), 3, 'collector options: the example log holds three example-ok lines' );
    my @plain_lines = split /\n/, $stdout;
    my $plain_timestamped = grep { /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/ } @plain_lines;
    is( $plain_timestamped, 0, 'collector options: the plain log has no timestamped lines' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example', '-t' );
    is( $exit, 0, 'collector options: d2 collector log example -t exits 0' );
    like( $stdout, qr/example-ok/, 'collector options: d2 collector log example -t still shows the example log' );
    my @timed_lines = grep { $_ ne '' } split /\n/, $stdout;
    ok( @timed_lines > 0, 'collector options: d2 collector log example -t prints log lines' );
    my $timed = grep { /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/ } @timed_lines;
    is( $timed, scalar @timed_lines, 'collector options: d2 collector log example -t timestamps every log line' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', '-t', 'example' );
    is( $exit, 0, 'collector options: d2 collector log -t example exits 0' );
    my @timed_first_lines = grep { $_ ne '' } split /\n/, $stdout;
    ok( @timed_first_lines > 0, 'collector options: d2 collector log -t example prints log lines' );
    my $timed_first = grep { /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d/ } @timed_first_lines;
    is( $timed_first, scalar @timed_first_lines, 'collector options: d2 collector log -t example timestamps every log line too' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example', '--tail', '2' );
    is( $exit, 0, 'collector options: d2 collector log example --tail 2 exits 0' );
    is( _count_occurrences( $stdout, 'example-ok' ), 1, 'collector options: d2 collector log example --tail 2 shows one example-ok line' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example', '--tail', '6' );
    is( $exit, 0, 'collector options: d2 collector log example --tail 6 exits 0' );
    is( _count_occurrences( $stdout, 'example-ok' ), 2, 'collector options: d2 collector log example --tail 6 shows two example-ok lines' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example', '--tail', '100' );
    is( $exit, 0, 'collector options: d2 collector log example --tail 100 exits 0' );
    is( _count_occurrences( $stdout, 'example-ok' ), 3, 'collector options: d2 collector log example --tail 100 shows the whole log' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example', '-n', '2' );
    is( $exit, 0, 'collector options: d2 collector log example -n 2 exits 0' );
    is( _count_occurrences( $stdout, 'example-ok' ), 1, 'collector options: d2 collector log example -n 2 shows one example-ok line' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example', '--tail=2' );
    is( $exit, 0, 'collector options: d2 collector log example --tail=2 exits 0' );
    is( _count_occurrences( $stdout, 'example-ok' ), 1, 'collector options: d2 collector log example --tail=2 shows one example-ok line' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example', '--tail', '0' );
    is( $exit, 0, 'collector options: d2 collector log example --tail 0 exits 0' );
    is( $stdout, '', 'collector options: d2 collector log example --tail 0 prints nothing' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'log', 'example', '--tail', '-1' );
    isnt( $exit, 0, 'collector options: d2 collector log example --tail -1 does not succeed' );
    like( $stdout . $stderr, qr/Usage: d2 collector log/, 'collector options: d2 collector log example --tail -1 prints the usage' );
}

# R79 R115, collector log follow: -f follows the log instead of
# returning, so the command is run under a timeout and must still be
# running when the timeout kills it (exit 124), with the initial log
# already printed. Without a timeout binary this cannot be bounded, so
# it skips.
SKIP: {
    skip 'collector options: follow test requires a timeout binary (timeout or gtimeout) on PATH', 2
      if !$timeout_bin;
    my ( $exit, $stdout, $stderr ) = _run_d2_timeout( 3, 'collector', 'log', 'example', '-f' );
    is( $exit, 124, 'collector options: d2 collector log example -f is still following when the timeout kills it' );
    like( $stdout, qr/example-ok/, 'collector options: d2 collector log example -f already printed the log before following' );
}

# R79 R115, collector stop options: `d2 collector stop` gains the
# options the verb-first `d2 stop collector` accepts today via
# RuntimeControl - --output/-o (including JSON mode), --host, --port,
# --workers, --ssl. The plain stop is the control (t/997 covers it in
# full); here each option must be accepted and the stop still performed.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the stop -o json case' );
    my $pid = _pid_of($stdout);
    ok( _wait_for_alive($pid), 'collector options: the example loop is running before the stop -o json case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example', '-o', 'json' );
    is( $exit, 0, 'collector options: d2 collector stop example -o json exits 0' );
    ok( _is_json_with( $stdout, 'example', $pid ), 'collector options: d2 collector stop example -o json prints JSON naming the example loop' );
    ok( _wait_for_gone($pid), 'collector options: the example loop is gone after the stop -o json case' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the stop --output json case' );
    $pid = _pid_of($stdout);
    ok( _wait_for_alive($pid), 'collector options: the example loop is running before the stop --output json case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example', '--output', 'json' );
    is( $exit, 0, 'collector options: d2 collector stop example --output json exits 0' );
    ok( _is_json_with( $stdout, 'example', $pid ), 'collector options: d2 collector stop example --output json prints JSON naming the example loop' );
    ok( _wait_for_gone($pid), 'collector options: the example loop is gone after the stop --output json case' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the stop -o table case' );
    $pid = _pid_of($stdout);
    ok( _wait_for_alive($pid), 'collector options: the example loop is running before the stop -o table case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example', '-o', 'table' );
    is( $exit, 0, 'collector options: d2 collector stop example -o table exits 0' );
    ok( _wait_for_gone($pid), 'collector options: the example loop is gone after the stop -o table case' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the stop -o xml case' );
    $pid = _pid_of($stdout);
    ok( _wait_for_alive($pid), 'collector options: the example loop is running before the stop -o xml case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example', '-o', 'xml' );
    isnt( $exit, 0, 'collector options: d2 collector stop example -o xml does not succeed' );
    like( $stdout . $stderr, qr/Usage: d2 collector stop/, 'collector options: d2 collector stop example -o xml prints the usage' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector options: d2 collector stop example exits 0 after the stop -o xml case' );
    ok( _wait_for_gone($pid), 'collector options: the example loop is gone after the stop -o xml case' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the stop web-options case' );
    $pid = _pid_of($stdout);
    ok( _wait_for_alive($pid), 'collector options: the example loop is running before the stop web-options case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example', '--host', '127.0.0.1', '--port', '7999', '--workers', '2', '--ssl' );
    is( $exit, 0, 'collector options: d2 collector stop example --host --port --workers --ssl exits 0' );
    ok( _wait_for_gone($pid), 'collector options: the example loop is gone after the stop web-options case' );
}

# R79 R115, collector restart options: `d2 collector restart` gains the
# same options - --output/-o (including JSON mode), --host, --port,
# --workers, --ssl. A restart genuinely replaces the loop, so the new
# pid differs from the old one and the old pid is gone.
{
    my ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the restart -o json case' );
    my $old_pid = _pid_of($stdout);
    ok( _wait_for_alive($old_pid), 'collector options: the example loop is running before the restart -o json case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart', 'example', '-o', 'json' );
    is( $exit, 0, 'collector options: d2 collector restart example -o json exits 0' );
    my $new_pid = _pid_of($stdout);
    ok( defined $new_pid, 'collector options: d2 collector restart example -o json prints a pid' );
    isnt( $new_pid, $old_pid, 'collector options: the restart -o json replaces the example loop with a new pid' );
    ok( _is_json_with( $stdout, 'example', $new_pid ), 'collector options: d2 collector restart example -o json prints JSON naming the new loop' );
    ok( _wait_for_alive($new_pid), 'collector options: the new example loop is running after the restart -o json case' );
    ok( _wait_for_gone($old_pid), 'collector options: the old example loop is gone after the restart -o json case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector options: d2 collector stop example exits 0 after the restart -o json case' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the restart --output=json case' );
    $old_pid = _pid_of($stdout);
    ok( _wait_for_alive($old_pid), 'collector options: the example loop is running before the restart --output=json case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart', 'example', '--output=json' );
    is( $exit, 0, 'collector options: d2 collector restart example --output=json exits 0' );
    $new_pid = _pid_of($stdout);
    ok( defined $new_pid, 'collector options: d2 collector restart example --output=json prints a pid' );
    isnt( $new_pid, $old_pid, 'collector options: the restart --output=json replaces the example loop with a new pid' );
    ok( _is_json_with( $stdout, 'example', $new_pid ), 'collector options: d2 collector restart example --output=json prints JSON naming the new loop' );
    ok( _wait_for_alive($new_pid), 'collector options: the new example loop is running after the restart --output=json case' );
    ok( _wait_for_gone($old_pid), 'collector options: the old example loop is gone after the restart --output=json case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector options: d2 collector stop example exits 0 after the restart --output=json case' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the restart -o xml case' );
    $old_pid = _pid_of($stdout);
    ok( _wait_for_alive($old_pid), 'collector options: the example loop is running before the restart -o xml case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart', 'example', '-o', 'xml' );
    isnt( $exit, 0, 'collector options: d2 collector restart example -o xml does not succeed' );
    like( $stdout . $stderr, qr/Usage: d2 collector restart/, 'collector options: d2 collector restart example -o xml prints the usage' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector options: d2 collector stop example exits 0 after the restart -o xml case' );
    ok( _wait_for_gone($old_pid), 'collector options: the old example loop is gone after the restart -o xml case' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the restart web-options case' );
    $old_pid = _pid_of($stdout);
    ok( _wait_for_alive($old_pid), 'collector options: the example loop is running before the restart web-options case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart', 'example', '--host', '127.0.0.1', '--port', '7999', '--workers', '2', '--ssl' );
    is( $exit, 0, 'collector options: d2 collector restart example --host --port --workers --ssl exits 0' );
    $new_pid = _pid_of($stdout);
    ok( defined $new_pid, 'collector options: d2 collector restart example --host --port --workers --ssl prints a pid' );
    isnt( $new_pid, $old_pid, 'collector options: the restart web-options replaces the example loop with a new pid' );
    ok( _wait_for_alive($new_pid), 'collector options: the new example loop is running after the restart web-options case' );
    ok( _wait_for_gone($old_pid), 'collector options: the old example loop is gone after the restart web-options case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector options: d2 collector stop example exits 0 after the restart web-options case' );

    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'start', 'example' );
    is( $exit, 0, 'collector options: d2 collector start example exits 0 for the restart --no-ssl case' );
    $old_pid = _pid_of($stdout);
    ok( _wait_for_alive($old_pid), 'collector options: the example loop is running before the restart --no-ssl case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'restart', 'example', '--no-ssl' );
    is( $exit, 0, 'collector options: d2 collector restart example --no-ssl exits 0' );
    $new_pid = _pid_of($stdout);
    ok( defined $new_pid, 'collector options: d2 collector restart example --no-ssl prints a pid' );
    isnt( $new_pid, $old_pid, 'collector options: the restart --no-ssl replaces the example loop with a new pid' );
    ok( _wait_for_alive($new_pid), 'collector options: the new example loop is running after the restart --no-ssl case' );
    ok( _wait_for_gone($old_pid), 'collector options: the old example loop is gone after the restart --no-ssl case' );
    ( $exit, $stdout, $stderr ) = _run_d2( 'collector', 'stop', 'example' );
    is( $exit, 0, 'collector options: d2 collector stop example exits 0 after the restart --no-ssl case' );
}

done_testing();
