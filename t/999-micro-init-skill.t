use strict;
use warnings;

# MICRO (scratch only, never merge): why does `d2 init-skill one two`
# print "Unknown d2 command" on Windows (build #79, tests 670/671)?
# Two candidates:
#   (a) _skill_bare_init_command_name('init-skill') returns empty on
#       Windows (skill lookup or __init__ resolve fails);
#   (b) the name resolves, but the bare-init branch in bin/d2 uses
#       _builtin_helper_path('skills'), which returns '' on Windows
#       (the skills helper is a dashboard-core helper, so its command
#       carries a non-empty argv and the path-only form returns ''),
#       so _exec_switchboard_command('') is a no-op and dispatch falls
#       through to "Unknown d2 command". The dotted branch was already
#       fixed for this exact shape (it uses _builtin_helper_command).
# Each case prints its raw outcome with diag.

use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use Cwd qw(getcwd);
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );
use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);
use Developer::Dashboard::PathRegistry;
use Developer::Dashboard::SkillManager;
use Developer::Dashboard::Platform;
use Developer::Dashboard::InternalCLI;

my $is_windows = $^O eq 'MSWin32';
my $repo = getcwd();
my $lib = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

# Same fixture as t/05's DD-954 block, in a fresh temp HOME.
my $tmp_home = tempdir( CLEANUP => 1 );
local $ENV{HOME} = $tmp_home;
my $init_root = File::Spec->catdir( $tmp_home, '.developer-dashboard', 'skills', 'init-skill', 'cli' );
make_path($init_root);
my $init_file = File::Spec->catfile( $init_root, '__init__' );
open my $fh, '>', $init_file or die "Unable to write $init_file: $!";
print {$fh} "#!/usr/bin/env perl\nuse strict;\nuse warnings;\nprint qq{init-self|\@ARGV\\n};\n";
close $fh;
chmod 0755, $init_file or die "Unable to chmod $init_file: $!";

my $paths = Developer::Dashboard::PathRegistry->new(
    cwd => $repo, home => $tmp_home, workspace_roots => [], project_roots => [],
);

# Verbatim copies of the bin/d2 helpers under test (scratch diagnosis only).
sub _micro_builtin_helper_command {
    my ($cmd) = @_;
    my $helper = Developer::Dashboard::InternalCLI::canonical_helper_name($cmd);
    return () if $helper eq '';
    if ( Developer::Dashboard::Platform::is_windows() && Developer::Dashboard::InternalCLI::_helper_uses_dashboard_core($helper) ) {
        Developer::Dashboard::InternalCLI::ensure_dashboard_core( paths => $paths );
        return (
            Developer::Dashboard::InternalCLI::dashboard_core_path( paths => $paths ),
            $helper,
        );
    }
    Developer::Dashboard::InternalCLI::ensure_helper( paths => $paths, name => $helper );
    return ( Developer::Dashboard::InternalCLI::helper_path( paths => $paths, name => $helper ) );
}

sub _micro_builtin_helper_path {
    my ($cmd) = @_;
    my ( $path, @argv ) = _micro_builtin_helper_command($cmd);
    return '' if !defined $path || $path eq '' || @argv;
    return $path;
}

sub _micro_skill_bare_init_command_name {
    my ($cmd) = @_;
    return if !defined $cmd || $cmd eq '' || $cmd =~ /\./;
    my $manager = Developer::Dashboard::SkillManager->new( paths => $paths );
    my $skill_path = $manager->get_skill_path( $cmd, include_disabled => 1 );
    return if !$skill_path;
    return if !Developer::Dashboard::Platform::resolve_runnable_file( File::Spec->catfile( $skill_path, 'cli', '__init__' ) );
    return $cmd;
}

# CASE 1: does the skill lookup find init-skill?
{
    my $manager = Developer::Dashboard::SkillManager->new( paths => $paths );
    my $skill_path = $manager->get_skill_path( 'init-skill', include_disabled => 1 );
    diag 'CASE 1 get_skill_path: ' . ( defined $skill_path ? $skill_path : 'undef' );
    ok( defined $skill_path, 'CASE 1: skill lookup finds init-skill' );
}

# CASE 2: does the __init__ file resolve as runnable?
{
    my $manager = Developer::Dashboard::SkillManager->new( paths => $paths );
    my $skill_path = $manager->get_skill_path( 'init-skill', include_disabled => 1 );
    my $resolved = defined $skill_path
      ? Developer::Dashboard::Platform::resolve_runnable_file( File::Spec->catfile( $skill_path, 'cli', '__init__' ) )
      : undef;
    diag 'CASE 2 resolve_runnable_file(__init__): ' . ( defined $resolved ? $resolved : 'undef' );
    ok( defined $resolved, 'CASE 2: cli/__init__ resolves as runnable' );
}

# CASE 3: does the bare-init name check return the skill name?
{
    my $name = _micro_skill_bare_init_command_name('init-skill');
    diag 'CASE 3 bare-init name: ' . ( defined $name ? "[$name]" : 'undef' );
    ok( defined $name && $name eq 'init-skill', 'CASE 3: bare-init name check returns init-skill' );
}

# CASE 4: what does the path-only skills helper form return?
{
    my $helper_path = _micro_builtin_helper_path('skills');
    diag "CASE 4 builtin_helper_path('skills'): [$helper_path]";
    if ($is_windows) {
        ok( $helper_path eq '', 'CASE 4 Windows: path-only skills helper form returns empty (dashboard-core argv)' );
    }
    else {
        ok( $helper_path ne '', 'CASE 4 Unix: path-only skills helper form returns a path' );
    }
}

# CASE 5: what does the (path, argv) skills helper form return?
{
    my ( $helper_path, @helper_argv ) = _micro_builtin_helper_command('skills');
    diag "CASE 5 builtin_helper_command('skills'): path=[$helper_path] argv=[@helper_argv]";
    ok( defined $helper_path && $helper_path ne '', 'CASE 5: (path, argv) skills helper form returns a path' );
    if ($is_windows) {
        ok( @helper_argv && $helper_argv[0] eq 'skills', 'CASE 5 Windows: (path, argv) form carries the skills argv' );
    }
    else {
        ok( !@helper_argv, 'CASE 5 Unix: (path, argv) form carries no extra argv' );
    }
}

# CASE 6: end-to-end `d2 init-skill one two` with this fixture.
{
    my $perl = $^X;
    my ( $out, $err, $exit ) = run_shell_command( "$perl -I'$lib' '$dashboard' init-skill one two", {} );
    my $combined = $out . $err;
    diag "CASE 6 d2 init-skill one two: exit=$exit out=[$combined]";
    if ($is_windows) {
        ok( $exit != 0 && $combined =~ /Unknown d2 command/, 'CASE 6 Windows: reproduces the build #79 failure (Unknown d2 command)' );
    }
    else {
        ok( $exit == 0 && $combined =~ /init-self\|one two/, 'CASE 6 Unix: d2 init-skill runs cli/__init__' );
    }
}

done_testing();
