# t/999-micro-t88-hang.t — MICRO v2: t/88's head with COMPILE-TIME `use`, exactly
# like the real file. Scratch only, do not merge, do not ship.
#
# Micro v1 (runtime require+import, one module at a time) PASSED on Windows in
# 3s and created no listeners — so the hang's trigger is NOT in the head when
# loaded spaced out. v2 tests the other difference: the real file loads all
# modules in one compile-time burst. If v2 hangs, the trigger is load timing.
# If v2 passes, the trigger is after test 1 and v3 expands to the fixtures
# plus the following test blocks.
use strict;
use warnings;
use utf8;
use Capture::Tiny qw(capture);
use Errno qw(EBADF EINTR);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use IO::Select;
use IO::Socket::INET;
use Socket qw(AF_UNIX PF_UNSPEC SOCK_STREAM SOL_SOCKET SO_LINGER);
use Symbol qw(gensym);
use Test::More;
use lib 'lib';
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::Web::Server;
use Developer::Dashboard::Web::Server::Daemon;

sub _log { warn "MICRO2: $_[0]\n"; }
sub _net {
    my ($label) = @_;
    my $n = `netstat -ano | findstr "$$"`;
    warn "MICRO2 net after $label pid $$:\n$n\n";
}

_log("use block finished, pid $$");
_net("use block");

_log("before tempdir");
my $home = tempdir( CLEANUP => 1 );
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
ok( $rt, 'micro2: home runtime path' );
_log("after ok 1"); _net("ok 1");

_log("done");
done_testing();
