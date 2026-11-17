use strict;
use warnings;

use Cwd qw(getcwd);
use Developer::Dashboard::Collector;
use Developer::Dashboard::PathRegistry;

# Subprocess probe for the 1111 micro: builds the path registry EXACTLY the
# way share/private-cli/_dashboard-core does (no home/cwd args) and prints
# every value the collector-log rotation path depends on. Probe branch only,
# never merge. Run through the micro test, never directly.

print "HELPER-START\n";
print 'HOME=', ( defined $ENV{HOME} ? $ENV{HOME} : '<undef>' ), "\n";
print 'USERPROFILE=', ( defined $ENV{USERPROFILE} ? $ENV{USERPROFILE} : '<undef>' ), "\n";
print 'CWD=', getcwd(), "\n";
my $paths = Developer::Dashboard::PathRegistry->new(
    workspace_roots => [ grep { defined && -d } map { "$ENV{HOME}/$_" } qw(projects src work) ],
    project_roots   => [ grep { defined && -d } map { "$ENV{HOME}/$_" } qw(projects src work) ],
);
print 'home=', $paths->home(), "\n";
print 'runtime_layers=', join( ' | ', $paths->runtime_layers() ), "\n";
print 'runtime_root=', $paths->runtime_root(), "\n";
print 'state_root=', $paths->state_root(), "\n";
print 'collectors_root=', $paths->collectors_root(), "\n";
my $store = Developer::Dashboard::Collector->new( paths => $paths );
my $log = $store->collector_paths('rotating.collector')->{log};
print "collector_log=$log\n";
print 'collector_log_exists=', ( -f $log ? 1 : 0 ), "\n";
print "HELPER-END\n";
