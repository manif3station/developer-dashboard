package Developer::Dashboard::SkillDispatcher;

use strict;
use warnings;

our $VERSION = '1.47';

use File::Spec;
use File::Basename;
use Capture::Tiny qw(capture);
use Developer::Dashboard::SkillManager;

# new()
# Creates a SkillDispatcher instance to execute skill commands.
# Input: none.
# Output: SkillDispatcher object.
sub new {
    my ($class) = @_;
    my $manager = Developer::Dashboard::SkillManager->new();
    
    return bless {
        manager => $manager,
    }, $class;
}

# dispatch($skill_name, $command, @args)
# Executes a command from an installed skill.
# Input: skill repo name, command name, and command arguments.
# Output: command output or error hash.
sub dispatch {
    my ( $self, $skill_name, $command, @args ) = @_;
    
    return { error => 'Missing skill name' } if !$skill_name;
    return { error => 'Missing command name' } if !$command;
    
    # Find the skill
    my $skill_path = $self->{manager}->get_skill_path($skill_name);
    return { error => "Skill '$skill_name' not found" } if !$skill_path;
    
    # Check for command in skill's cli/ directory
    my $cmd_path = File::Spec->catfile( $skill_path, 'cli', $command );
    return { error => "Command '$command' not found in skill '$skill_name'" } if !-f $cmd_path;
    return { error => "Command '$command' is not executable" } if !-x $cmd_path;
    
    # Execute the command in skill's isolated environment
    my ( $stdout, $stderr, $exit ) = capture {
        system( $cmd_path, @args );
    };
    
    return {
        stdout => $stdout,
        stderr => $stderr,
        exit_code => $exit,
    };
}

# execute_hooks($skill_name, $command, @args)
# Executes hook files from skill's cli/<command>.d/ directory before main command.
# Input: skill repo name, command name, and command arguments.
# Output: hash with hook results and environment.
sub execute_hooks {
    my ( $self, $skill_name, $command, @args ) = @_;
    
    return {} if !$skill_name || !$command;
    
    my $skill_path = $self->{manager}->get_skill_path($skill_name);
    return {} if !$skill_path;
    
    # Check for hooks directory
    my $hooks_dir = File::Spec->catdir( $skill_path, 'cli', "$command.d" );
    return {} if !-d $hooks_dir;
    
    # Execute hook files in sorted order
    my %results;
    opendir( my $dh, $hooks_dir ) or return {};
    
    for my $entry ( sort grep { $_ ne '.' && $_ ne '..' } readdir($dh) ) {
        my $hook_path = File::Spec->catfile( $hooks_dir, $entry );
        next unless -f $hook_path && -x $hook_path;
        
        my ( $stdout, $stderr, $exit ) = capture {
            system( $hook_path, @args );
        };
        
        $results{$entry} = {
            stdout => $stdout,
            stderr => $stderr,
            exit_code => $exit,
        };
    }
    
    closedir($dh);
    return \%results;
}

# get_skill_config($skill_name)
# Reads and returns a skill's configuration.
# Input: skill repo name.
# Output: hash ref with config or empty hash.
sub get_skill_config {
    my ( $self, $skill_name ) = @_;
    
    return {} if !$skill_name;
    
    my $skill_path = $self->{manager}->get_skill_path($skill_name);
    return {} if !$skill_path;
    
    my $config_file = File::Spec->catfile( $skill_path, 'config', 'config.json' );
    return {} if !-f $config_file;
    
    open( my $fh, '<', $config_file ) or return {};
    my $json_text = do { local $/; <$fh> };
    close($fh);
    
    use JSON::XS;
    my $config = eval { JSON::XS->new->decode($json_text) } || {};
    return $config;
}

# get_skill_path($skill_name)
# Returns the path to an installed skill.
# Input: skill repo name.
# Output: skill path string or undef.
sub get_skill_path {
    my ( $self, $skill_name ) = @_;
    
    return if !$skill_name;
    return $self->{manager}->get_skill_path($skill_name);
}

1;

__END__

=pod

=head1 NAME

Developer::Dashboard::SkillDispatcher - execute commands from installed skills

=head1 SYNOPSIS

  use Developer::Dashboard::SkillDispatcher;
  my $dispatcher = Developer::Dashboard::SkillDispatcher->new();
  
  my $result = $dispatcher->dispatch('skill-name', 'cmd', 'arg1', 'arg2');
  my $hooks = $dispatcher->execute_hooks('skill-name', 'cmd');
  my $config = $dispatcher->get_skill_config('skill-name');
  my $path = $dispatcher->get_skill_path('skill-name');

=head1 DESCRIPTION

Dispatches commands to and manages execution of installed dashboard skills.
Handles:
- Command execution with isolation
- Hook file execution in sorted order
- Configuration reading
- Skill path resolution
- Command output capture

=cut
