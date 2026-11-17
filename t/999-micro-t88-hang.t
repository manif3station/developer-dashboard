# t/999-micro-t88-hang.t — MICRO v3: t/88's head VERBATIM (lines 1-42 of the
# loop-branch file), plus MICRO3 logs and netstat dumps. Scratch only, do not
# merge, do not ship.
#
# Micro v1 (runtime require) and v2 (compile-time use) both PASSED on Windows
# and created no listeners — but both OMITTED three things the real head has:
# (1) the BEGIN block that overrides CORE::GLOBAL::kill, (2) `our
# $KILL_OVERRIDE`, (3) `local $ENV{HOME} = $home`. v3 adds exactly those. If
# v3 hangs, the trigger is one of them (bisect next). If v3 passes, v4 adds
# the fixture packages plus the tests after test 1.
#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

# Keep signal forwarding injectable for unit coverage without creating a
# process in the test harness.
our $KILL_OVERRIDE;

BEGIN {
    *CORE::GLOBAL::kill = sub {
        return $main::KILL_OVERRIDE->(@_) if $main::KILL_OVERRIDE;
        return CORE::kill(@_);
    };
}

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

sub _log { warn "MICRO3: $_[0]\n"; }
sub _net {
    my ($label) = @_;
    my $n = `netstat -ano | findstr "$$"`;
    warn "MICRO3 net after $label pid $$:\n$n\n";
}

_log("use block finished, pid $$");
_net("use block");

# Hermetic runtime: every layer lookup resolves from this temp home and cwd.
_log("before tempdir");
my $home = tempdir( CLEANUP => 1 );
_log("after tempdir $home"); _net("tempdir");

_log("before local HOME");
local $ENV{HOME} = $home;
_log("after local HOME"); _net("local HOME");

_log("before chdir");
chdir $home or die "Unable to chdir to $home: $!";
_log("after chdir"); _net("chdir");

_log("before PathRegistry->new");
my $paths = Developer::Dashboard::PathRegistry->new( home => $home );
_log("after PathRegistry->new"); _net("PathRegistry->new");

_log("before ok 1");
ok( $paths->home_runtime_path, 'hermetic path registry resolves a home runtime path' );
_log("after ok 1"); _net("ok 1");

_log("done");
done_testing();
