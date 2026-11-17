# t/999-micro-t88-hang.t — MINIMAL reproduction of the t/88 Windows hang.
# Scratch only, do not merge, do not ship.
#
# Michael's method: extract the stuck part into a micro script, log before and
# after every line, and expand the stuck line until the cause is 100% clear.
# Every module is loaded with require+import at RUNTIME (not `use`, which runs
# at compile time) so the logs truly bracket each load. After every load the
# script dumps this process's TCP connections, so the log shows exactly which
# load creates the loopback listeners seen in the hung process.
use strict;
use warnings;

sub _log { warn "MICRO: $_[0]\n"; }
sub _net {
    my ($label) = @_;
    my $n = `netstat -ano | findstr "$$"`;
    warn "MICRO net after $label pid $$:\n$n\n";
}

_log("start, pid $$");
_net("start");

_log("before require Capture::Tiny");
require Capture::Tiny; Capture::Tiny->import(qw(capture));
_log("after require Capture::Tiny"); _net("Capture::Tiny");

_log("before require Errno");
require Errno; Errno->import(qw(EBADF EINTR));
_log("after require Errno"); _net("Errno");

_log("before require File::Basename");
require File::Basename; File::Basename->import(qw(basename dirname));
_log("after require File::Basename"); _net("File::Basename");

_log("before require File::Path");
require File::Path; File::Path->import(qw(make_path));
_log("after require File::Path"); _net("File::Path");

_log("before require File::Spec");
require File::Spec;
_log("after require File::Spec"); _net("File::Spec");

_log("before require File::Temp");
require File::Temp; File::Temp->import(qw(tempdir tempfile));
_log("after require File::Temp"); _net("File::Temp");

_log("before require IO::Select");
require IO::Select;
_log("after require IO::Select"); _net("IO::Select");

_log("before require IO::Socket::INET");
require IO::Socket::INET;
_log("after require IO::Socket::INET"); _net("IO::Socket::INET");

_log("before require Socket");
require Socket; Socket->import(qw(AF_UNIX PF_UNSPEC SOCK_STREAM SOL_SOCKET SO_LINGER));
_log("after require Socket"); _net("Socket");

_log("before require Symbol");
require Symbol; Symbol->import(qw(gensym));
_log("after require Symbol"); _net("Symbol");

_log("before require Test::More");
require Test::More; Test::More->import();
_log("after require Test::More"); _net("Test::More");

_log("before unshift lib");
unshift @INC, 'lib';
_log("after unshift lib"); _net("lib");

_log("before require PathRegistry");
require Developer::Dashboard::PathRegistry;
_log("after require PathRegistry"); _net("PathRegistry");

_log("before require Web::Server");
require Developer::Dashboard::Web::Server;
_log("after require Web::Server"); _net("Web::Server");

_log("before require Web::Server::Daemon");
require Developer::Dashboard::Web::Server::Daemon;
_log("after require Web::Server::Daemon"); _net("Web::Server::Daemon");

_log("before tempdir");
my $home = File::Temp::tempdir( CLEANUP => 1 );
_log("after tempdir $home"); _net("tempdir");

_log("before chdir");
chdir $home or die "Unable to chdir to $home: $!";
_log("after chdir"); _net("chdir");

_log("before PathRegistry->new");
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
_log("after PathRegistry->new"); _net("PathRegistry->new");

_log("before home_runtime_path");
my $rt = $paths->home_runtime_path;
_log("after home_runtime_path $rt"); _net("home_runtime_path");

_log("before ok 1");
Test::More::ok( $rt, 'micro: home runtime path' );
_log("after ok 1"); _net("ok 1");

_log("done");
Test::More::done_testing();
