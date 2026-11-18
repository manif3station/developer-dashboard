use strict;
use warnings;

# MICRO (scratch only, never merge): why does `d2 workspace DD-NEW` exit
# 255 on Windows (build #86, tests 725/726) with "Unable to create tmux
# ticket session 'DD-NEW': " (EMPTY detail) and the fake-tmux log never
# written? The fake `tmux` is an extensionless #!/bin/sh script, the
# same family as the docker/vim fakes. The product invokes tmux via
# Ticket::tmux_command, which is list-form system('tmux', ...) inside
# Capture::Tiny - unlike _exec_raw's block form, the list form DOES find
# .bat files via the cmd fallback (probe E, build #83), so a tmux.bat
# twin MIGHT fix this with no product change. But the empty detail is
# suspicious: if cmd's "not recognized" reached stderr, Capture::Tiny
# should have caught it, so the spawn may return -1 with no child output
# at all. This micro measures the spawn inside Capture::Tiny (cases 1-2),
# the end-to-end run with and without the twin (cases 3-4), and the
# product's tmux_command in-process (case 5).

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use Cwd qw(getcwd);
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);
use Developer::Dashboard::CLI::Ticket ();

my $is_windows = $^O eq 'MSWin32';
my $repo = getcwd();
my $lib = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
my $perl = $^X;

# Same fixtures as t/05's workspace block, in a fresh temp HOME.
my $tmp_home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $tmp_home;
my $fake_ticket_bin = File::Spec->catdir( $tmp_home, 'fake-ticket-bin' );
make_path($fake_ticket_bin);
my $fake_ticket_log = File::Spec->catfile( $tmp_home, 'fake-ticket-tmux.log' );

my $fake_tmux = File::Spec->catfile( $fake_ticket_bin, 'tmux' );
open my $tfh, '>', $fake_tmux or die "Unable to write $fake_tmux: $!";
print {$tfh} <<"SH";
#!/bin/sh
printf '%s\\n' "\$*" >> '$fake_ticket_log'
if [ "\$1" = "has-session" ]; then
  if [ "\$3" = "DD-NEW" ]; then
    exit 1
  fi
  exit 0
fi
if [ "\$1" = "show-options" ] && [ "\$3" = "status-format[0]" ]; then
  printf '%s\\n' '#[default]DEFAULT-ROW'
  exit 0
fi
exit 0
SH
close $tfh;
chmod 0755, $fake_tmux or die "Unable to chmod $fake_tmux: $!";

sub read_log {
    open my $fh, '<', $fake_ticket_log or return '<no log file>';
    my $content = do { local $/; <$fh> };
    close $fh;
    return defined $content ? $content : '<empty>';
}

sub write_sentinel {
    open my $fh, '>', $fake_ticket_log or die "Unable to write $fake_ticket_log: $!";
    print {$fh} "SENTINEL\n";
    close $fh;
}

sub run_workspace {
    my ( $out, $err, $exit ) = run_shell_command(
        "PATH='$fake_ticket_bin':\"\$PATH\" $perl -I'$lib' '$dashboard' workspace DD-NEW",
        {},
    );
    return ( $out . $err, $exit );
}

# CASE 1+2: the spawn probe (list-form system inside Capture::Tiny).
my $probe = File::Spec->catfile( $tmp_home, 'probe-tmux-spawn.pl' );
{
    open my $pfh, '>', $probe or die "Unable to write $probe: $!";
    print {$pfh} do { local $/; <DATA> };
    close $pfh;
}
my $probe_out;
{
    my ( $out, $err, $exit ) = run_shell_command(
        "PATH='$fake_ticket_bin':\"\$PATH\" $perl '$probe' '$fake_ticket_bin' '$fake_ticket_log'",
        {},
    );
    $probe_out = $out . $err;
    diag "CASE 1+2 spawn probe (exit=$exit):\n$probe_out";
    my ($a_exit) = $probe_out =~ /A list-form in capture, extensionless-only: exit=(-?\d+)/;
    my ($a_log) = $probe_out =~ /A list-form in capture, extensionless-only: exit=-?\d+ stdout=\[.*?\] stderr=\[.*?\] log=\[(.*?)\]/s;
    if ($is_windows) {
        ok( defined $a_exit && $a_exit != 0 && defined $a_log && $a_log =~ /^SENTINEL/,
            'CASE 1 Windows: list-form tmux spawn fails with the extensionless fake only (log still sentinel)' );
    }
    else {
        ok( defined $a_exit && $a_exit == 1 && defined $a_log && $a_log =~ /has-session -t DD-NEW/,
            'CASE 1 Unix: list-form tmux spawn runs the fake, has-session reports the session missing (exit 1)' );
    }
    my ($b_exit) = $probe_out =~ /B list-form in capture, with tmux\.bat: exit=(-?\d+)/;
    my ($b_log) = $probe_out =~ /B list-form in capture, with tmux\.bat: exit=-?\d+ stdout=\[.*?\] stderr=\[.*?\] log=\[(.*?)\]/s;
    ok( defined $b_exit && $b_exit == 1 && defined $b_log && $b_log =~ /has-session -t DD-NEW/,
        'CASE 2: list-form tmux spawn finds the tmux.bat twin inside Capture::Tiny (fake runs, has-session exit 1)' );
}

# CASE 3: end-to-end workspace with the extensionless fake only (baseline).
{
    my $bat = File::Spec->catfile( $fake_ticket_bin, 'tmux.bat' );
    unlink $bat;
    write_sentinel();
    my ( $combined, $exit ) = run_workspace();
    my $log = read_log();
    $combined =~ s/\n/\\n/g;
    $log =~ s/\n/\\n/g;
    diag "CASE 3 extensionless only: exit=$exit log=[$log] output=[$combined]";
    if ($is_windows) {
        ok( $exit != 0, 'CASE 3 Windows: d2 workspace exits non-zero with the extensionless fake tmux' );
    }
    else {
        ok( $exit == 0 && $log =~ /has-session -t DD-NEW/, 'CASE 3 Unix: d2 workspace exits 0 with the extensionless fake tmux' );
    }
}

# CASE 4: end-to-end workspace WITH the tmux.bat twin.
{
    my $bat = File::Spec->catfile( $fake_ticket_bin, 'tmux.bat' );
    open my $bfh, '>', $bat or die "Unable to write $bat: $!";
    print {$bfh} "\@echo off\r\n";
    print {$bfh} "echo \%*>>\"$fake_ticket_log\"\r\n";
    print {$bfh} "if \"%~1\"==\"has-session\" if \"%~3\"==\"DD-NEW\" exit /b 1\r\n";
    print {$bfh} "if \"%~1\"==\"show-options\" if \"%~3\"==\"status-format[0]\" echo #[default]DEFAULT-ROW\r\n";
    print {$bfh} "exit /b 0\r\n";
    close $bfh;
    write_sentinel();
    my ( $combined, $exit ) = run_workspace();
    my $log = read_log();
    $combined =~ s/\n/\\n/g;
    $log =~ s/\n/\\n/g;
    diag "CASE 4 with tmux.bat twin: exit=$exit log=[$log] output=[$combined]";
    ok( $exit == 0 && $log =~ /has-session -t DD-NEW/ && $log =~ /new-session/,
        'CASE 4: d2 workspace exits 0 and creates the session once the tmux.bat twin exists' );
}

# CASE 5: the product's tmux_command in-process, with the twin present.
{
    write_sentinel();
    local $ENV{PATH} = $fake_ticket_bin . ( $is_windows ? ';' : ':' ) . ( $ENV{PATH} // '' );
    my $result = Developer::Dashboard::CLI::Ticket::tmux_command( args => [ 'has-session', '-t', 'DD-NEW' ] );
    my $log = read_log();
    diag "CASE 5 tmux_command in-process: exit_code=$result->{exit_code} stdout=[$result->{stdout}] stderr=[$result->{stderr}] log=[$log]";
    ok( $result->{exit_code} == 1 && $log =~ /has-session -t DD-NEW/,
        'CASE 5: tmux_command reports the fake has-session exit 1 and the fake ran' );
}

done_testing();

__DATA__
use File::Spec;
use strict;
use warnings;
use Capture::Tiny qw(capture);

my ( $fake_bin, $log ) = @ARGV;
die "usage: $0 <fake-bin> <log>\n" if !defined $log;

open STDIN, '<', File::Spec->devnull() or die "Unable to open devnull for stdin: $!";
my $path_sep = $^O eq 'MSWin32' ? ';' : ':';
$ENV{PATH} = $fake_bin . $path_sep . ( $ENV{PATH} // '' );

sub read_log {
    open my $fh, '<', $log or return '<no log file>';
    my $content = do { local $/; <$fh> };
    close $fh;
    return defined $content ? $content : '<empty>';
}

sub write_sentinel {
    open my $fh, '>', $log or die "Unable to write $log: $!";
    print {$fh} "SENTINEL\n";
    close $fh;
}

sub one_line {
    my ($text) = @_;
    $text = '' if !defined $text;
    $text =~ s/\n/\\n/g;
    return $text;
}

# Variant A: list-form system inside Capture::Tiny, extensionless only.
{
    write_sentinel();
    my ( $out, $err, $exit );
    {
        local $?;
        ( $out, $err, $exit ) = capture {
            system 'tmux', 'has-session', '-t', 'DD-NEW';
            return $? >> 8;
        };
    }
    my $log_content = read_log();
    print "A list-form in capture, extensionless-only: exit=$exit stdout=[" . one_line($out) . "] stderr=[" . one_line($err) . "] log=[" . one_line($log_content) . "]\n";
}

# Write the tmux.bat twin, then variant B.
print "--- now writing tmux.bat twin ---\n";
my $bat = "$fake_bin\\tmux.bat";
open my $bfh, '>', $bat or die "Unable to write $bat: $!";
print {$bfh} "\@echo off\r\n";
print {$bfh} "echo \%*>>" . $log . "\r\n";
print {$bfh} "if \"%~1\"==\"has-session\" if \"%~3\"==\"DD-NEW\" exit /b 1\r\n";
print {$bfh} "if \"%~1\"==\"show-options\" if \"%~3\"==\"status-format[0]\" echo #[default]DEFAULT-ROW\r\n";
print {$bfh} "exit /b 0\r\n";
close $bfh;

{
    write_sentinel();
    my ( $out, $err, $exit );
    {
        local $?;
        ( $out, $err, $exit ) = capture {
            system 'tmux', 'has-session', '-t', 'DD-NEW';
            return $? >> 8;
        };
    }
    my $log_content = read_log();
    print "B list-form in capture, with tmux.bat: exit=$exit stdout=[" . one_line($out) . "] stderr=[" . one_line($err) . "] log=[" . one_line($log_content) . "]\n";
}

print "probe done\n";
