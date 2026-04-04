#!/usr/bin/perl
=head1 Test Developer::Dashboard Skill System

Tests for skill installation, uninstallation, updating, and execution.

=cut

use strict;
use warnings;

use Cwd;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use JSON::XS qw(decode_json);
use Capture::Tiny qw(capture);
use Test::More;

use lib 'lib';
use Developer::Dashboard::SkillManager;
use Developer::Dashboard::SkillDispatcher;

# Test configuration
my $test_home = tempdir( CLEANUP => 1 );
my $skills_dir = "$test_home/skills";
my $test_repos_dir = tempdir( CLEANUP => 1 );

# Create test Git repo for skill testing
sub create_test_skill_repo {
    my ($skill_name) = @_;
    
    my $repo_dir = "$test_repos_dir/$skill_name";
    make_path($repo_dir) or die "Cannot create repo dir";
    
    my $cwd = getcwd();
    chdir $repo_dir or die "Cannot chdir to $repo_dir";
    
    # Initialize git repo
    system('git init --quiet 2>/dev/null');
    system('git init') == 0 or die "Failed to init git repo";
    system('git config user.email test@example.com') == 0;
    system('git config user.name Test') == 0;
    
    # Create skill structure
    make_path('cli', 'config', 'state', 'logs') or die "Cannot create skill dirs";
    
    # Create a simple test command
    open my $cmd_fh, '>', 'cli/testcmd' or die "Cannot create cli/testcmd";
    print $cmd_fh "#!/usr/bin/perl\nprint \"Hello from $skill_name\\n\";\n";
    close $cmd_fh;
    chmod 0755, 'cli/testcmd';
    
    # Create config.json
    open my $cfg_fh, '>', 'config/config.json' or die "Cannot create config.json";
    print $cfg_fh qq{{"skill_name":"$skill_name","version":"1.0.0"}};
    close $cfg_fh;
    
    # Create README
    open my $readme_fh, '>', 'README.md' or die "Cannot create README.md";
    print $readme_fh "# $skill_name Skill\n\nTest skill for integration.\n";
    close $readme_fh;
    
    # Commit
    system('git add .') == 0 or die "Failed to git add";
    system("git commit -m 'Initial commit for $skill_name' > /dev/null 2>&1") == 0 or die "Failed to git commit";
    
    chdir $cwd or die "Cannot chdir back";
    return $repo_dir;
}

# Override the default home directory for testing
local $ENV{HOME} = $test_home;

# Run tests
plan tests => 33;

# Test 1: SkillManager initializes correctly
my $skill_mgr = Developer::Dashboard::SkillManager->new();
isa_ok( $skill_mgr, 'Developer::Dashboard::SkillManager', 'SkillManager instantiates' );

# Test 2: Initial skill list is empty
my $skills = $skill_mgr->list();
is_deeply( $skills, [], 'Initial skills list is empty' );

# Test 3: Get skills directory path (should be undef before first install)
my $path = $skill_mgr->get_skill_path('nonexistent');
is( $path, undef, 'get_skill_path returns undef for nonexistent skill' );

# Test 4-6: Create a test skill repo for installation
my $repo_dir = create_test_skill_repo('test-skill-repo');
note("Created test skill repo at: $repo_dir");

my $git_url = "file://$repo_dir";
note("Git URL: $git_url");

# Test 4: Skill installation
my $install_result = $skill_mgr->install($git_url);
ok( !$install_result->{error}, 'Skill installs without error' )
    or diag("Install error: $install_result->{error}");

is( $install_result->{repo_name}, 'test-skill-repo', 'Install returns correct repo name' )
    or diag("Expected test-skill-repo, got: $install_result->{repo_name}");

# Test 5: Installed skill appears in list
$skills = $skill_mgr->list();
is( scalar(@$skills), 1, 'Installed skill appears in list' );
is( $skills->[0]->{name}, 'test-skill-repo', 'Skill list contains correct skill name' );

# Test 6: Skill directory was created
my $installed_path = $skill_mgr->get_skill_path('test-skill-repo');
ok( defined($installed_path) && -d $installed_path, 'Skill directory exists' );
ok( -d "$installed_path/cli", 'Skill cli directory exists' );
ok( -d "$installed_path/config", 'Skill config directory exists' );
ok( -d "$installed_path/state", 'Skill state directory exists' );
ok( -d "$installed_path/logs", 'Skill logs directory exists' );

# Test 7: Skill config file exists and is readable
ok( -f "$installed_path/config/config.json", 'Skill config.json exists' );
my $config_content = do {
    open my $fh, '<', "$installed_path/config/config.json" or die "Cannot read config.json";
    local $/;
    <$fh>;
};
my $config = decode_json($config_content);
ok( $config, 'Config is valid JSON' );

# Test 8: SkillDispatcher initializes correctly
my $dispatcher = Developer::Dashboard::SkillDispatcher->new();
isa_ok( $dispatcher, 'Developer::Dashboard::SkillDispatcher', 'SkillDispatcher instantiates' );

# Test 9: Dispatcher can get skill config
my $disp_config = $dispatcher->get_skill_config('test-skill-repo');
ok( $disp_config, 'Dispatcher can retrieve skill config' );

# Test 10: Dispatcher can get skill path
my $disp_path = $dispatcher->get_skill_path('test-skill-repo');
ok( $disp_path && -d $disp_path, 'Dispatcher can resolve skill path' );

# Test 11: Update skill (pull changes)
my $update_result = $skill_mgr->update('test-skill-repo');
ok( !$update_result->{error}, 'Skill updates without error' )
    or diag("Update error: $update_result->{error}");

# Test 12-14: Uninstall skill
my $uninstall_result = $skill_mgr->uninstall('test-skill-repo');
ok( !$uninstall_result->{error}, 'Skill uninstalls without error' )
    or diag("Uninstall error: $uninstall_result->{error}");

$skills = $skill_mgr->list();
is( scalar(@$skills), 0, 'Uninstalled skill no longer appears in list' );

ok( ! -d $installed_path, 'Skill directory was removed after uninstall' );

# Test 15: CLI integration - skills list command
my ($stdout, $stderr, $exit);

($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'list' );
};
my $result = decode_json($stdout);
is_deeply( $result, { skills => [] }, 'CLI skills list command works' );

# Test 16: CLI integration - skills install via command line
my $repo_dir2 = create_test_skill_repo('another-skill-repo');
my $git_url2 = "file://$repo_dir2";

($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'install', $git_url2 );
};
ok( $exit == 0, 'CLI skills install command exits successfully' )
    or diag("STDERR: $stderr");

# Test 17: Verify skill was installed via CLI
($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'list' );
};
$result = decode_json($stdout);
is( scalar(@{$result->{skills}}), 1, 'CLI skill install added to skills list' );

# Test 18-19: Test skill command dispatch
my $skill_name = 'another-skill-repo';
my $skill_dir = $skill_mgr->get_skill_path($skill_name);

# Create a test command in the installed skill
open my $cmd_fh, '>', "$skill_dir/cli/echo-test" or die "Cannot create test command";
print $cmd_fh "#!/usr/bin/perl\nprint \"Echo: \" . join(\" \", \@ARGV) . \"\\n\";\n";
close $cmd_fh;
chmod 0755, "$skill_dir/cli/echo-test";

my $disp_result = $dispatcher->dispatch( $skill_name, 'echo-test', 'arg1', 'arg2' );
ok( !$disp_result->{error}, 'Skill command dispatches without error' )
    or diag("Dispatch error: $disp_result->{error}");

like( $disp_result->{stdout}, qr/Echo.*arg1.*arg2/, 'Skill command output contains expected content' );

# Test 20: Test skill hook execution (if hook file exists)
make_path("$skill_dir/cli/echo-test.d") or die "Cannot create hook dir";
open my $hook_fh, '>', "$skill_dir/cli/echo-test.d/pre-test" or die "Cannot create hook";
print $hook_fh "#!/bin/sh\necho 'Hook executed'\n";
close $hook_fh;
chmod 0755, "$skill_dir/cli/echo-test.d/pre-test";

$disp_result = $dispatcher->execute_hooks( $skill_name, 'echo-test', 'pre' );
ok( !$disp_result->{error}, 'Skill hooks execute without error' )
    or diag("Hook error: $disp_result->{error}");

# Test 21: CLI isolation - skills don't interfere with each other
my $repo_dir3 = create_test_skill_repo('third-skill-repo');
my $git_url3 = "file://$repo_dir3";

($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'install', $git_url3 );
};

($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'list' );
};
$result = decode_json($stdout);
is( scalar(@{$result->{skills}}), 2, 'Multiple skills can coexist' );

# Test 22-24: Verify uninstall removes only one skill
($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'uninstall', 'third-skill-repo' );
};
ok( $exit == 0, 'CLI skills uninstall exits successfully' );

($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'list' );
};
$result = decode_json($stdout);
is( scalar(@{$result->{skills}}), 1, 'Uninstall removes only the targeted skill' );

my $remaining_dir = $skill_mgr->get_skill_path('another-skill-repo');
ok( -d $remaining_dir, 'Other skills remain after uninstall' );

# Test 25: Clean up final skill
($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'uninstall', 'another-skill-repo' );
};

# Test 26: Skill system is cleanly empty
($stdout, $stderr, $exit) = capture {
    system( $^X, '-I', 'lib', 'bin/dashboard', 'skills', 'list' );
};
$result = decode_json($stdout);
is( scalar(@{$result->{skills}}), 0, 'All skills successfully uninstalled' );

# Test 27: Skills directory is clean
ok( ! -d $skill_dir, 'Skills directory is clean after all uninstalls' );

done_testing();

=head1 License

This test is part of Developer Dashboard.

=cut
