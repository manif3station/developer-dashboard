#!/usr/bin/perl
=head1 Test Skill Web Routes

Tests for skill HTTP route namespacing under /skill/:repo-name/:route

=cut

use strict;
use warnings;

use Cwd;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Developer::Dashboard::Web::App;
use Developer::Dashboard::SkillManager;

# Test configuration
my $test_home = tempdir( CLEANUP => 1 );
my $test_repos_dir = tempdir( CLEANUP => 1 );

# Create test Git repo for skill
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
    
    # Create config.json
    open my $cfg_fh, '>', 'config/config.json' or die "Cannot create config.json";
    print $cfg_fh qq{{"skill_name":"$skill_name","version":"1.0.0"}};
    close $cfg_fh;
    
    # Create README
    open my $readme_fh, '>', 'README.md' or die "Cannot create README.md";
    print $readme_fh "# $skill_name Skill\n\nTest skill.\n";
    close $readme_fh;
    
    # Commit
    system('git add .') == 0 or die "Failed to git add";
    system("git commit -m 'Initial commit' > /dev/null 2>&1") == 0 or die "Failed to git commit";
    
    chdir $cwd or die "Cannot chdir back";
    return $repo_dir;
}

# Override HOME for testing
local $ENV{HOME} = $test_home;

# Run tests
plan tests => 8;

# Create minimal app instance (mock objects)
my $mock_auth = {
    helper_users_enabled => 0,
};

my $mock_pages = {};
my $mock_sessions = {};
my $mock_config = {};

my $app = Developer::Dashboard::Web::App->new(
    auth     => $mock_auth,
    pages    => $mock_pages,
    sessions => $mock_sessions,
    config   => $mock_config,
);

# Test 1: Web app initializes
isa_ok( $app, 'Developer::Dashboard::Web::App', 'Web app instantiates' );

# Test 2-3: Install a test skill
my $skill_mgr = Developer::Dashboard::SkillManager->new();
my $repo_dir = create_test_skill_repo('test-skill-repo');
my $git_url = "file://$repo_dir";
my $install_result = $skill_mgr->install($git_url);
ok( !$install_result->{error}, 'Test skill installs for routing test' );

# Test 4: Skill route for nonexistent skill returns 404
my $response = $app->dispatch_request(
    path   => '/skill/nonexistent-skill/bookmarks',
    method => 'GET',
    headers => {},
);
is( $response->[0], 404, 'Nonexistent skill route returns 404' );
like( $response->[2], qr/not found/, 'Error message indicates skill not found' );

# Test 5: Skill route for installed skill with unimplemented routes returns 501
$response = $app->dispatch_request(
    path   => '/skill/test-skill-repo/bookmarks',
    method => 'GET',
    headers => {},
);
is( $response->[0], 501, 'Installed skill with no routes returns 501 Not Implemented' );
like( $response->[2], qr/does not provide/, 'Error message indicates routes not implemented' );

# Test 6-7: Invalid skill/route patterns return 404 (not matched by skill pattern)
$response = $app->dispatch_request(
    path   => '/skill//invalid',
    method => 'GET',
    headers => {},
);
is( $response->[0], 404, 'Empty skill name pattern returns 404 (not matched)' );

# Test 8: Invalid route with empty path returns 404
$response = $app->dispatch_request(
    path   => '/skill/test-skill-repo/',
    method => 'GET',
    headers => {},
);
is( $response->[0], 404, 'Empty route pattern returns 404 (not matched)' );

done_testing();

=head1 License

This test is part of Developer Dashboard.

=cut
