package Developer::Dashboard::InternalCLI;

use strict;
use warnings;

our $VERSION = '1.73';

use File::Spec;

# helper_names()
# Returns the built-in private helper command names that dashboard manages.
# Input: none.
# Output: ordered list of helper command name strings.
sub helper_names {
    return qw(jq yq tomq propq iniq csvq xmlq of open-file ticket);
}

# helper_aliases()
# Returns the compatibility alias map for renamed helper commands.
# Input: none.
# Output: hash reference mapping older names to current helper names.
sub helper_aliases {
    return {
        pjq   => 'jq',
        pyq   => 'yq',
        ptomq => 'tomq',
        pjp   => 'propq',
    };
}

# canonical_helper_name($name)
# Normalizes one helper command name to the current built-in helper name.
# Input: helper command string.
# Output: canonical helper name string or empty string when unsupported.
sub canonical_helper_name {
    my ($name) = @_;
    return '' if !defined $name || $name eq '';
    my %allowed = map { $_ => 1 } helper_names();
    return $name if $allowed{$name};
    my $aliases = helper_aliases();
    return $aliases->{$name} || '';
}

# helper_path(%args)
# Resolves one private helper executable path under the runtime CLI root.
# Input: path registry object plus helper command name.
# Output: helper file path string.
sub helper_path {
    my (%args) = @_;
    my $paths = $args{paths} || die 'Missing paths registry';
    my $name  = canonical_helper_name( $args{name} );
    die "Unsupported helper command '$args{name}'" if $name eq '';
    return File::Spec->catfile( $paths->cli_root, $name );
}

# helper_content($name)
# Builds one self-contained private helper executable body.
# Input: canonical helper command name.
# Output: full executable source text string.
sub helper_content {
    my ($name) = @_;
    $name = canonical_helper_name($name);
    die "Unsupported helper command '$name'" if $name eq '';

    if ( $name eq 'of' || $name eq 'open-file' ) {
        my $content = <<'PERL';
#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use Developer::Dashboard::CLI::OpenFile qw(run_open_file_command);

# main(\@ARGV)
# Runs the __NAME__ open-file helper for Developer Dashboard.
# Input: command-line arguments from \@ARGV and optional STDIN.
# Output: prints matching paths or execs the configured editor, then exits.
run_open_file_command( args => \@ARGV );

__END__

=pod

=head1 NAME

__NAME__ - private open-file helper for Developer Dashboard

=head1 SYNOPSIS

  dashboard __NAME__ [--print] [--line N] [--editor CMD] <file|scope> [pattern...]

=head1 DESCRIPTION

This private helper is staged under F<~/.developer-dashboard/cli/> so the main
C<dashboard> command can keep file-opening behaviour available without
installing a generic executable into the user's global PATH.

=cut
PERL
        $content =~ s/__NAME__/$name/g;
        return $content;
    }

    if ( $name eq 'ticket' ) {
        my $content = <<'PERL';
#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use Developer::Dashboard::CLI::Ticket qw(run_ticket_command);

# main(\@ARGV)
# Runs the ticket helper for Developer Dashboard.
# Input: command-line arguments from \@ARGV.
# Output: creates or attaches to the requested tmux ticket session, then exits.
run_ticket_command( args => \@ARGV );

__END__

=pod

=head1 NAME

ticket - private tmux ticket helper for Developer Dashboard

=head1 SYNOPSIS

  dashboard ticket <ticket-ref>

=head1 DESCRIPTION

This private helper is staged under F<~/.developer-dashboard/cli/> so the main
C<dashboard> command can keep ticket-session behaviour available without
installing a generic executable into the user's global PATH.

=cut
PERL
        return $content;
    }

    my $content = <<'PERL';
#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use Developer::Dashboard::CLI::Query qw(run_query_command);

# main(\@ARGV)
# Runs the __NAME__ query command for Developer Dashboard.
# Input: command-line arguments from \@ARGV and optional STDIN.
# Output: prints the selected value, then exits.
run_query_command( command => '__NAME__', args => \@ARGV );

__END__

=pod

=head1 NAME

__NAME__ - private query command for Developer Dashboard

=head1 SYNOPSIS

  dashboard __NAME__ [path] [file]

=head1 DESCRIPTION

This private helper is staged under F<~/.developer-dashboard/cli/> so the main
C<dashboard> command can dispatch the __NAME__ query tool without installing a
generic executable into the user's global PATH.

=cut
PERL
    $content =~ s/__NAME__/$name/g;
    return $content;
}

# ensure_helpers(%args)
# Seeds the built-in private helper executables into the runtime CLI root.
# Input: path registry object.
# Output: array reference of written helper file paths.
sub ensure_helpers {
    my (%args) = @_;
    my $paths = $args{paths} || die 'Missing paths registry';

    my @written;
    for my $name ( helper_names() ) {
        my $target = helper_path( paths => $paths, name => $name );
        $paths->ensure_dir( $paths->cli_root );
        my $content = helper_content($name);

        open my $out, '>', $target or die "Unable to write $target: $!";
        print {$out} $content;
        close $out;
        $paths->secure_file_permissions( $target, executable => 1 );
        push @written, $target;
    }

    return \@written;
}

1;

__END__

=head1 NAME

Developer::Dashboard::InternalCLI - private runtime helper executable management

=head1 SYNOPSIS

  use Developer::Dashboard::InternalCLI;

  my $paths = Developer::Dashboard::PathRegistry->new(home => $ENV{HOME});
  Developer::Dashboard::InternalCLI::ensure_helpers(paths => $paths);

=head1 DESCRIPTION

This module manages the built-in private helper executables that Developer
Dashboard stages under F<~/.developer-dashboard/cli/> instead of exposing as
global system commands.

=head1 FUNCTIONS

=head2 helper_names, helper_aliases, canonical_helper_name, helper_content, helper_path, ensure_helpers

Build and seed the built-in private helper command files.

=cut
