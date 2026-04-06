package Developer::Dashboard::CLI::Ticket;

use strict;
use warnings;

our $VERSION = '1.77';

use Capture::Tiny qw(capture);
use Cwd qw(cwd);
use Exporter 'import';

our @EXPORT_OK = qw(
  build_ticket_plan
  resolve_ticket_request
  run_ticket_command
  session_exists
  ticket_environment
  tmux_command
);

# resolve_ticket_request(%args)
# Resolves the target ticket reference from argv or the current environment.
# Input: args array reference and optional env_ticket scalar.
# Output: non-empty ticket/session name string or dies when none is available.
sub resolve_ticket_request {
    my (%args) = @_;
    my $argv = $args{args} || [];
    die 'Ticket args must be an array reference' if ref($argv) ne 'ARRAY';

    my $ticket = $argv->[0];
    $ticket = $args{env_ticket} if !defined $ticket || $ticket eq '';
    die "Please specify a ticket name\n" if !defined $ticket || $ticket eq '';
    return $ticket;
}

# ticket_environment($ticket)
# Builds the tmux environment values that travel with one ticket session.
# Input: non-empty ticket/session name string.
# Output: hash reference of tmux environment variable names and values.
sub ticket_environment {
    my ($ticket) = @_;
    die "Ticket name is required\n" if !defined $ticket || $ticket eq '';
    return {
        TICKET_REF => $ticket,
        B          => $ticket,
        OB         => "origin/$ticket",
    };
}

# tmux_command(%args)
# Runs one tmux command and captures stdout, stderr, and exit status.
# Input: args array reference for tmux.
# Output: hash reference with stdout, stderr, and exit_code keys.
sub tmux_command {
    my (%args) = @_;
    my $argv = $args{args} || [];
    die 'tmux args must be an array reference' if ref($argv) ne 'ARRAY';

    my ( $stdout, $stderr, $exit_code ) = capture {
        system 'tmux', @{$argv};
        return $? >> 8;
    };

    return {
        stdout    => $stdout,
        stderr    => $stderr,
        exit_code => $exit_code,
    };
}

# session_exists(%args)
# Checks whether the requested tmux session already exists.
# Input: session name and optional tmux runner coderef.
# Output: 1 when the session exists, 0 when it does not, or dies on tmux errors.
sub session_exists {
    my (%args) = @_;
    my $session = $args{session} || die 'Missing session name';
    my $tmux = $args{tmux} || \&tmux_command;
    my $result = $tmux->(
        args => [ 'has-session', '-t', $session ],
    );

    return 1 if $result->{exit_code} == 0;
    return 0 if $result->{exit_code} == 1;
    die sprintf "Unable to inspect tmux session '%s': %s%s",
      $session,
      ( $result->{stderr} || '' ),
      ( $result->{stdout} || '' );
}

# build_ticket_plan(%args)
# Builds the tmux create/attach plan for one ticket session request.
# Input: args array reference, optional cwd/env_ticket values, and optional tmux runner coderef.
# Output: hash reference describing the session, cwd, environment, and tmux argv lists.
sub build_ticket_plan {
    my (%args) = @_;
    my $ticket = resolve_ticket_request(
        args       => $args{args} || [],
        env_ticket => $args{env_ticket},
    );
    my $plan_cwd = $args{cwd};
    $plan_cwd = cwd() if !defined $plan_cwd || $plan_cwd eq '';

    my $env = ticket_environment($ticket);
    my $exists = session_exists(
        session => $ticket,
        tmux    => $args{tmux},
    );

    my @env_args;
    for my $name ( sort keys %{$env} ) {
        push @env_args, '-e', "$name=$env->{$name}";
    }

    return {
        session     => $ticket,
        cwd         => $plan_cwd,
        env         => $env,
        exists      => $exists,
        create      => $exists ? 0 : 1,
        create_argv => [
            'new-session',
            '-d',
            @env_args,
            '-c', $plan_cwd,
            '-s', $ticket,
            '-n', 'Code1',
        ],
        attach_argv => [
            'attach-session',
            '-t', $ticket,
        ],
    };
}

# run_ticket_command(%args)
# Creates a tmux ticket session when needed and attaches to it.
# Input: args array reference plus optional cwd/env_ticket values and optional tmux runner coderef.
# Output: plan hash reference after successful tmux create/attach operations.
sub run_ticket_command {
    my (%args) = @_;
    my $tmux = $args{tmux} || \&tmux_command;
    my $plan = build_ticket_plan(
        %args,
        tmux => $tmux,
    );

    if ( $plan->{create} ) {
        my $created = $tmux->( args => $plan->{create_argv} );
        die sprintf "Unable to create tmux ticket session '%s': %s%s",
          $plan->{session},
          ( $created->{stderr} || '' ),
          ( $created->{stdout} || '' )
          if $created->{exit_code} != 0;
    }

    my $attached = $tmux->( args => $plan->{attach_argv} );
    die sprintf "Unable to attach tmux ticket session '%s': %s%s",
      $plan->{session},
      ( $attached->{stderr} || '' ),
      ( $attached->{stdout} || '' )
      if $attached->{exit_code} != 0;

    return $plan;
}

1;

__END__

=head1 NAME

Developer::Dashboard::CLI::Ticket - private tmux ticket helper for Developer Dashboard

=head1 SYNOPSIS

  use Developer::Dashboard::CLI::Ticket qw(run_ticket_command);
  run_ticket_command( args => \@ARGV );

=head1 DESCRIPTION

Provides the shared implementation behind the private C<ticket> helper staged
under F<~/.developer-dashboard/cli/> so C<dashboard ticket> can stay part of
the dashboard toolchain without installing a public top-level executable.

=cut
