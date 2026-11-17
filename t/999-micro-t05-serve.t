use strict;
use warnings;

# MICRO PROBE — NEVER MERGE. Diagnoses the Windows t/05 collector failures
# (lines 805/824): `collector output tick.collector` stays empty after
# `d2 serve` and after `d2 restart`. Replicates t/05's serve block with
# inspection: serve a 1s tick collector, wait, then dump (a) the serve
# JSON, (b) `collector output` and `collector status` JSON, (c) the
# collector dir listing with file sizes, (d) the stored status.json and
# stdout/stderr contents read in-process, (e) the collector log tail.
# The in-process run_command micro (build #44) proved the tick command
# itself works on Windows, so the failure is in the serve/loop path.
# All dumps go to STDERR (prove swallows passing STDOUT) and the probe
# passes by design so all four legs run.
# Run as a Jenkins solo: TEST_FILE=t/999-micro-t05-serve.t

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use IO::Socket::INET;
use Time::HiRes qw(sleep);
use Encode qw(encode);
use Developer::Dashboard::JSON qw(json_decode json_encode);
use Developer::Dashboard::PathRegistry ();
use Developer::Dashboard::Collector ();
use FindBin;

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo      = getcwd();
my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );
local $ENV{HOME} = tempdir( CLEANUP => 1 );
print STDERR "MICRO-SERVE: HOME=$ENV{HOME}\n";

my ( $out, $err, $rc ) = run_shell_command( "$perl -I'$lib' '$dashboard' init", {} );
print STDERR "MICRO-SERVE: init rc=$rc\n";

my $config_file = File::Spec->catfile( $ENV{HOME}, '.developer-dashboard', 'config', 'config.json' );
open my $cfg_fh, '>:raw', $config_file or die "Unable to write $config_file: $!";
my $config_json = json_encode(
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
$config_json = encode( 'UTF-8', $config_json ) if utf8::is_utf8($config_json);
print {$cfg_fh} $config_json;
close $cfg_fh;

my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
    Listen => 1, ReuseAddr => 1,
) or die "Unable to reserve a free local TCP port: $!";
my $port = $sock->sockport();
close $sock or die "Unable to release reserved local TCP port $port: $!";
print STDERR "MICRO-SERVE: port=$port\n";

# t/05 runs the serve block with cwd=serve_home (_run_in_home prefixes
# "cd '$home' &&"); replicate that so the runtime layers match.
my $in_home = "cd '$ENV{HOME}' && ";

print STDERR "MICRO-SERVE: before serve\n";
( $out, $err, $rc ) = run_shell_command( "${in_home}$perl -I'$lib' '$dashboard' serve --host 127.0.0.1 --port $port", {} );
print STDERR "MICRO-SERVE: after serve rc=$rc stdout=$out stderr=$err\n";

print STDERR "MICRO-SERVE: sleeping 8s for ticks\n";
sleep 8;

print STDERR "MICRO-SERVE: before collector output\n";
( $out, $err, $rc ) = run_shell_command( "${in_home}$perl -I'$lib' '$dashboard' collector output tick.collector", {} );
print STDERR "MICRO-SERVE: after collector output rc=$rc stdout=$out stderr=$err\n";

print STDERR "MICRO-SERVE: before collector status\n";
( $out, $err, $rc ) = run_shell_command( "${in_home}$perl -I'$lib' '$dashboard' collector status tick.collector", {} );
print STDERR "MICRO-SERVE: after collector status rc=$rc stdout=$out stderr=$err\n";

my $paths     = Developer::Dashboard::PathRegistry->new( home => $ENV{HOME} );
my $collector = Developer::Dashboard::Collector->new( paths => $paths );
my $cpaths    = $collector->collector_paths('tick.collector');
print STDERR "MICRO-SERVE: collector dir=$cpaths->{dir}\n";
if ( -d $cpaths->{dir} ) {
    opendir my $dh, $cpaths->{dir} or die "Unable to read $cpaths->{dir}: $!";
    my @files = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    for my $file (@files) {
        my $full = File::Spec->catfile( $cpaths->{dir}, $file );
        my $size = -f $full ? -s $full : 'dir';
        print STDERR "MICRO-SERVE: dir entry $file size=$size\n";
    }
    for my $key (qw(stdout stderr combined last_run status job)) {
        my $file = $cpaths->{$key};
        if ( defined $file && -f $file ) {
            open my $fh, '<:raw', $file or die "Unable to read $file: $!";
            local $/;
            my $content = <$fh>;
            close $fh;
            $content = defined $content ? $content : '<undef>';
            $content =~ s/\n/\\n/g;
            print STDERR "MICRO-SERVE: file $key content=[$content]\n";
        }
        else {
            print STDERR "MICRO-SERVE: file $key MISSING\n";
        }
    }
    if ( -f $cpaths->{log} ) {
        open my $fh, '<:raw', $cpaths->{log} or die "Unable to read $cpaths->{log}: $!";
        local $/;
        my $log = <$fh>;
        close $fh;
        $log = defined $log ? $log : '';
        my @lines = split /\n/, $log;
        my @tail = @lines > 10 ? @lines[ -10 .. -1 ] : @lines;
        print STDERR "MICRO-SERVE: log tail:\n";
        for my $line (@tail) {
            print STDERR "MICRO-SERVE-LOG: $line\n";
        }
    }
    else {
        print STDERR "MICRO-SERVE: log MISSING\n";
    }
}
else {
    print STDERR "MICRO-SERVE: collector dir MISSING\n";
}

my $output = $collector->read_output('tick.collector');
print STDERR "MICRO-SERVE: read_output stdout=[" . ( $output->{stdout} // '<undef>' ) . "] stderr=[" . ( $output->{stderr} // '<undef>' ) . "] last_run=[" . ( $output->{last_run} // '<undef>' ) . "]\n";
my $status = $collector->read_status('tick.collector');
print STDERR "MICRO-SERVE: read_status=" . ( defined $status ? json_encode($status) : '<undef>' ) . "\n";

print STDERR "MICRO-SERVE: before stop\n";
( $out, $err, $rc ) = run_shell_command( "${in_home}$perl -I'$lib' '$dashboard' stop -o json", {} );
print STDERR "MICRO-SERVE: after stop rc=$rc stdout=$out stderr=$err\n";

pass('micro serve probe ran');
done_testing;
