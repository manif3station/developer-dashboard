package Developer::Dashboard::SkillManager;

use strict;
use warnings;

our $VERSION = '1.47';

use Cwd qw(realpath);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Basename;
use Capture::Tiny qw(capture);
use JSON::XS;

# new()
# Creates a SkillManager instance to handle skill installation, updates, uninstalls.
# Input: none.
# Output: SkillManager object.
sub new {
    my ($class) = @_;
    my $home = $ENV{HOME} || (getpwuid($>))[7] || $ENV{USERPROFILE};
    my $skills_root = File::Spec->catdir( $home, '.developer-dashboard', 'skills' );
    
    return bless {
        home        => $home,
        skills_root => $skills_root,
    }, $class;
}

# install($git_url)
# Clones a Git repository as a skill into ~/.developer-dashboard/skills/<repo-name>/
# Input: Git URL (can be git@, https://, file:///, etc.)
# Output: hash ref with success status and repo name.
sub install {
    my ( $self, $git_url ) = @_;
    
    return { error => 'Missing Git URL' } if !$git_url;
    
    # Extract repo name from URL
    my $repo_name = _extract_repo_name($git_url);
    return { error => "Unable to extract repo name from $git_url" } if !$repo_name;
    
    # Check if skill already exists
    my $skill_path = File::Spec->catdir( $self->{skills_root}, $repo_name );
    return { error => "Skill '$repo_name' already installed at $skill_path" } if -d $skill_path;
    
    # Ensure skills root exists
    make_path( $self->{skills_root} ) if !-d $self->{skills_root};
    
    # Clone the repository
    my ( $stdout, $stderr, $exit ) = capture {
        system( 'git', 'clone', $git_url, $skill_path );
    };
    
    if ( $exit != 0 ) {
        remove_tree($skill_path) if -d $skill_path;
        return { error => "Failed to clone $git_url: $stderr" };
    }
    
    # Create skill structure directories
    for my $dir ( qw(cli config state logs) ) {
        my $dir_path = File::Spec->catdir( $skill_path, $dir );
        make_path($dir_path) unless -d $dir_path;
    }
    
    # Create subdirectories for config
    make_path( File::Spec->catdir( $skill_path, 'config', 'docker' ) )
        unless -d File::Spec->catdir( $skill_path, 'config', 'docker' );
    
    return {
        success => 1,
        repo_name => $repo_name,
        path => $skill_path,
        message => "Skill '$repo_name' installed successfully",
    };
}

# uninstall($repo_name)
# Removes a skill completely from ~/.developer-dashboard/skills/<repo-name>/
# Input: skill repo name.
# Output: hash ref with success status.
sub uninstall {
    my ( $self, $repo_name ) = @_;
    
    return { error => 'Missing repo name' } if !$repo_name;
    
    my $skill_path = File::Spec->catdir( $self->{skills_root}, $repo_name );
    return { error => "Skill '$repo_name' not found" } if !-d $skill_path;
    
    # Remove the entire skill directory
    my $error;
    remove_tree( $skill_path, { error => \$error } );
    
    if ( @$error ) {
        return { error => "Failed to uninstall skill: " . join( ', ', @$error ) };
    }
    
    return {
        success => 1,
        repo_name => $repo_name,
        message => "Skill '$repo_name' uninstalled successfully",
    };
}

# update($repo_name)
# Pulls latest changes from the skill's Git repository.
# Input: skill repo name.
# Output: hash ref with success status.
sub update {
    my ( $self, $repo_name ) = @_;
    
    return { error => 'Missing repo name' } if !$repo_name;
    
    my $skill_path = File::Spec->catdir( $self->{skills_root}, $repo_name );
    return { error => "Skill '$repo_name' not found" } if !-d $skill_path;
    
    # Pull latest changes
    my ( $stdout, $stderr, $exit ) = capture {
        system( 'git', '-C', $skill_path, 'pull' );
    };
    
    if ( $exit != 0 ) {
        return { error => "Failed to update skill: $stderr" };
    }
    
    return {
        success => 1,
        repo_name => $repo_name,
        message => "Skill '$repo_name' updated successfully",
    };
}

# list()
# Lists all installed skills with metadata.
# Input: none.
# Output: array ref of skill metadata hashes.
sub list {
    my ($self) = @_;
    
    return [] if !-d $self->{skills_root};
    
    opendir( my $dh, $self->{skills_root} ) or return [];
    my @skills;
    
    for my $entry ( sort grep { $_ ne '.' && $_ ne '..' } readdir($dh) ) {
        my $skill_path = File::Spec->catdir( $self->{skills_root}, $entry );
        next unless -d $skill_path;
        
        my $skill_info = {
            name => $entry,
            path => $skill_path,
            has_config => -f File::Spec->catfile( $skill_path, 'config', 'config.json' ),
            has_cli => -d File::Spec->catdir( $skill_path, 'cli' ),
            has_cpanfile => -f File::Spec->catfile( $skill_path, 'cpanfile' ),
        };
        
        push @skills, $skill_info;
    }
    
    closedir($dh);
    return \@skills;
}

# get_skill_path($repo_name)
# Returns the full path to an installed skill.
# Input: skill repo name.
# Output: skill path string or undef.
sub get_skill_path {
    my ( $self, $repo_name ) = @_;
    
    return if !$repo_name;
    
    my $skill_path = File::Spec->catdir( $self->{skills_root}, $repo_name );
    return -d $skill_path ? $skill_path : undef;
}

# _extract_repo_name($git_url)
# Extracts repository name from various Git URL formats.
# Input: Git URL string.
# Output: repo name or undef.
sub _extract_repo_name {
    my ($url) = @_;
    
    return if !$url;
    
    # Extract from: git@github.com:user/repo-name.git
    if ( $url =~ m{/([^/]+?)(\.git)?$} ) {
        my $name = $1;
        return $name;
    }
    
    return;
}

1;

__END__

=pod

=head1 NAME

Developer::Dashboard::SkillManager - manage installed dashboard skills

=head1 SYNOPSIS

  use Developer::Dashboard::SkillManager;
  my $manager = Developer::Dashboard::SkillManager->new();
  
  my $result = $manager->install('git@github.com:user/skill-name.git');
  my $list = $manager->list();
  my $path = $manager->get_skill_path('skill-name');
  my $update_result = $manager->update('skill-name');
  my $uninstall_result = $manager->uninstall('skill-name');

=head1 DESCRIPTION

Manages the lifecycle of installed dashboard skills:
- Install: Clone Git repositories as skills
- Uninstall: Remove skills completely
- Update: Pull latest changes from skill repositories
- List: Show all installed skills
- Resolve: Find skill paths and metadata

Skills are isolated under ~/.developer-dashboard/skills/<repo-name>/

=cut
