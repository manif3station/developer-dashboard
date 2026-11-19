use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same reason as t/05.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(abs_path getcwd);
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Encode qw(decode encode);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IPC::Open3;
use LWP::UserAgent;
use Symbol;
use Test::More;
use Time::HiRes qw(sleep);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );

my $UNDER_COVER = exists $INC{'Devel/Cover.pm'};
my $repo = getcwd();
my $lib = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
my $perl = $^X;

sub _find_free_port {
    my $socket = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 1,
        ReuseAddr => 1,
    ) or die "Unable to reserve a free local TCP port: $!";
    my $port = $socket->sockport();
    close $socket or die "Unable to release reserved local TCP port $port: $!";
    return $port;
}

# _run_split($home, @argv)
# Runs one d2 command as a child perl process with cwd $home and captures
# stdout and stderr SEPARATELY (unlike t/05's _run, which concatenates
# them). The separation is the whole point: build #217's Windows leg died
# in json_decode because the restart output began with
# "Failed to stop Windo...", and the concatenated capture cannot say
# whether that text was restart's stdout, its stderr, or a dying child
# that inherited its stderr while restart itself exited 0.
# Input: home directory and d2 argv list.
# Output: hash reference with stdout, stderr and exit_code.
sub _run_split {
    my ( $home, @argv ) = @_;
    my $saved_cwd = getcwd();
    chdir $home or die "Unable to chdir to $home: $!";
    my $stderr_fh = Symbol::gensym();
    my $pid = IPC::Open3::open3( undef, my $stdout_fh, $stderr_fh, $perl, "-I$lib", $dashboard, @argv );
    my $stdout = do { local $/; <$stdout_fh> };
    my $stderr = do { local $/; <$stderr_fh> };
    waitpid( $pid, 0 );
    my $exit_code = $? >> 8;
    chdir $saved_cwd or die "Unable to chdir back to $saved_cwd: $!";
    return {
        stdout    => decode( 'UTF-8', defined $stdout ? $stdout : '' ),
        stderr    => decode( 'UTF-8', defined $stderr ? $stderr : '' ),
        exit_code => $exit_code,
    };
}

# _run_quiet($home, @argv)
# Same as _run_split but discards the streams; used for stop calls whose
# outcome cannot change the micro's verdict.
sub _run_quiet {
    my ( $home, @argv ) = @_;
    return _run_split( $home, @argv );
}

# _kill_survivors($home, $web_pid)
# Kills anything the stop left alive so the leg can finish: the web pid
# from the serve JSON and the loop pid from `collector status`. Same
# shape as the t/05-360 v4 micro: TERM, 0.5s, then KILL.
sub _kill_survivors {
    my ( $home, $web_pid ) = @_;
    my @pids;
    push @pids, $web_pid if defined $web_pid && $web_pid =~ /^\d+$/ && $web_pid > 0;
    my $status = _run_split( $home, 'collector', 'status', 'tick.collector' );
    if ( $status->{exit_code} == 0 ) {
        my $decoded = eval { json_decode( $status->{stdout} ) };
        if ( !$@ && ref($decoded) eq 'HASH' && defined $decoded->{pid} ) {
            push @pids, $decoded->{pid};
        }
    }
    for my $pid (@pids) {
        next if !kill( 0, $pid );
        diag("micro: killing surviving pid $pid after stop");
        kill 15, $pid;
        sleep 0.5;
        kill 9, $pid if kill( 0, $pid );
        diag( sprintf 'micro: pid %s alive after kill=%d', $pid, kill( 0, $pid ) ? 1 : 0 );
    }
    return;
}

if ( !$UNDER_COVER ) {
    for my $cycle ( 1 .. 3 ) {
        my $cycle_home = tempdir( CLEANUP => 1 );
        local $ENV{HOME} = $cycle_home;
        local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
        local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
        local $ENV{DEVELOPER_DASHBOARD_CHECKERS};
        my $init = _run_split( $cycle_home, 'init' );
        diag("micro: cycle $cycle init exit=$init->{exit_code}");
        my $serve_config_file = File::Spec->catfile( $cycle_home, '.developer-dashboard', 'config', 'config.json' );
        open my $serve_config_fh, '>:raw', $serve_config_file or die "Unable to write $serve_config_file: $!";
        my $serve_config_json = json_encode(
            {
                collectors => [
                    {
                        name     => 'tick.collector',
                        command  => q{perl -MTime::HiRes=time -e 'printf qq{%.6f\n}, time'},
                        cwd      => 'home',
                        interval => 1,
                    },
                ],
            }
        );
        $serve_config_json = encode( 'UTF-8', $serve_config_json ) if utf8::is_utf8($serve_config_json);
        print {$serve_config_fh} $serve_config_json;
        close $serve_config_fh;
        my $serve_port = _find_free_port();
        my $serve = _run_split( $cycle_home, 'serve', '--host', '127.0.0.1', '--port', $serve_port );
        my $serve_json = eval { json_decode( $serve->{stdout} ) };
        my $web_pid = ( !$@ && ref($serve_json) eq 'HASH' ) ? $serve_json->{pid} : undef;
        diag("micro: cycle $cycle serve exit=$serve->{exit_code} web_pid=" . ( defined $web_pid ? $web_pid : 'undef' ) . " alive=" . ( defined $web_pid && kill( 0, $web_pid ) ? 1 : 0 ));
        my $first_stdout = '';
        my $polls = 0;
        for ( 1 .. 160 ) {
            $polls = $_;
            my $output = _run_split( $cycle_home, 'collector', 'output', 'tick.collector' );
            my $decoded = eval { json_decode( $output->{stdout} ) };
            $first_stdout = ( !$@ && ref($decoded) eq 'HASH' ) ? ( $decoded->{stdout} || '' ) : '';
            diag("micro: cycle $cycle poll $polls out=" . ( $first_stdout eq '' ? "''" : "'$first_stdout'" ));
            last if $first_stdout =~ /^\d+\.\d+\n$/;
            sleep 0.25;
        }
        diag("micro: cycle $cycle collector ticked after $polls polls");
        my $restart = _run_split( $cycle_home, 'restart', '-o', 'json', '--host', '127.0.0.1', '--port', $serve_port );
        diag("micro: cycle $cycle restart exit=$restart->{exit_code}");
        diag( 'micro: cycle ' . $cycle . ' restart stdout first 1500: ' . substr( $restart->{stdout}, 0, 1500 ) );
        diag( 'micro: cycle ' . $cycle . ' restart stderr first 1500: ' . substr( $restart->{stderr}, 0, 1500 ) );
        my $restart_json = eval { json_decode( $restart->{stdout} ) };
        if ($@) {
            diag("micro: cycle $cycle restart stdout is NOT JSON: $@");
            diag( 'micro: cycle ' . $cycle . ' web pid ' . ( defined $web_pid ? $web_pid : 'undef' ) . ' alive after failed restart=' . ( defined $web_pid && kill( 0, $web_pid ) ? 1 : 0 ) );
            my $ua = LWP::UserAgent->new( timeout => 5 );
            my $health = eval { $ua->get("http://127.0.0.1:$serve_port/") };
            diag( 'micro: cycle ' . $cycle . ' port health after failed restart=' . ( $health && $health->code ? $health->code : 'unreachable' ) );
            my $retry = _run_split( $cycle_home, 'restart', '-o', 'json', '--host', '127.0.0.1', '--port', $serve_port );
            diag("micro: cycle $cycle second restart exit=$retry->{exit_code}");
            diag( 'micro: cycle ' . $cycle . ' second restart stdout first 1500: ' . substr( $retry->{stdout}, 0, 1500 ) );
            diag( 'micro: cycle ' . $cycle . ' second restart stderr first 1500: ' . substr( $retry->{stderr}, 0, 1500 ) );
        }
        else {
            diag( 'micro: cycle ' . $cycle . ' restart web_pid=' . ( $restart_json->{web_pid} || 'undef' ) );
        }
        my $stop = _run_split( $cycle_home, 'stop', '-o', 'json' );
        diag("micro: cycle $cycle stop exit=$stop->{exit_code}");
        _kill_survivors( $cycle_home, $web_pid );
        like( $restart->{stdout}, qr/^\{/, "micro: cycle $cycle restart stdout starts with JSON" );
    }
}

done_testing();

__END__

=head1 NAME

t/996-micro-t05-restart.t - micro-repro for the Windows d2 restart plain-text failure

=head1 PURPOSE

Reproduce the solo #217 Windows failure exactly: `d2 restart -o json`
exits 0 but its output begins with "Failed to stop Windo..." instead of
JSON, so t/05's json_decode dies and the test process exits 255 just
after test 203. The micro runs the same serve/restart/stop lifecycle as
t/05 tests 196-211 three times, capturing restart stdout and stderr
SEPARATELY so the failure's stream, exit code, full text and
post-failure liveness are all measured, not guessed.

=head1 WHY IT EXISTS

Build #217 (t/05 solo, tip 108f3409) passed t/05 on amd64 and macOS
1036/1036 but the Windows leg died at test 203: the restart command
exited 0 (ok 203) while its output began with "Failed to stop Windo...",
which only proves the first 20 characters of a die message from
RuntimeManager::_send_signal ("Failed to stop Windows process ids ...").
The concatenated stdout+stderr capture in t/05's _run cannot say whether
that text was restart's stdout, its stderr, or a dying child that
inherited its stderr; nor which pids taskkill refused, nor whether the
web service survived. This micro answers all of those before any fix is
attempted.

=head1 WHEN TO USE

Run it as a Jenkins solo (TEST_FILE=t/996-micro-t05-restart.t) on the
loop branch. Never run it by hand against a live home: it starts real
web services and collector loops in temp homes and kills survivors.

=head1 HOW TO USE

Commit it to windows/loop6-combined, push, then trigger a solo with
python3 ~/workspace/jenkins-cli/trigger.py windows/loop6-combined
t/996-micro-t05-restart.t 1. Read the per-cycle diag lines in the
console: restart exit code, the first 1500 chars of stdout and stderr
separately, the web pid liveness after a failed restart, the port
health, and whether a second restart succeeds. Remove the file in a
cleanup commit when the investigation ends.

=head1 WHAT USES IT

Nothing in the product uses this file. It is a diagnostic micro for the
t/05-restart applier, in the testing-v1 loop.

=head1 EXAMPLES

Jenkins solo #218 (t/996-micro-t05-restart.t): if a cycle's restart
stdout starts with "Failed to stop Windows process ids 1234: ..." then
the stop step died inside restart_target and the pids in the message
name the refused target; if stdout is empty and stderr carries the
text with exit 0, the die was caught and printed by a child or the
progress board and the exit-code handling is the defect.

=cut
