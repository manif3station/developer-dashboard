package Runtime::Result;

use strict;
use warnings;
use utf8;

our $VERSION = '1.46';

use Encode qw(encode);
use File::Basename qw(basename dirname);
use JSON::XS qw(decode_json);

# current()
# Decodes the current RESULT environment variable into a hash reference.
# Input: none.
# Output: hash reference keyed by hook filename.
sub current {
    my $json = $ENV{RESULT};
    return {} if !defined $json || $json eq '';
    my $data = decode_json($json);
    die 'RESULT must decode to a hash' if ref($data) ne 'HASH';
    return $data;
}

# names()
# Lists hook filenames currently stored in RESULT.
# Input: none.
# Output: sorted list of hook filename strings.
sub names {
    return sort keys %{ current() };
}

# has($name)
# Checks whether RESULT contains a record for a hook filename.
# Input: hook filename string.
# Output: boolean flag.
sub has {
    my ($name) = @_;
    return 0 if !defined $name || $name eq '';
    return exists current()->{$name} ? 1 : 0;
}

# entry($name)
# Returns the structured RESULT entry for one hook filename.
# Input: hook filename string.
# Output: hash reference or undef.
sub entry {
    my ($name) = @_;
    return if !defined $name || $name eq '';
    my $data = current();
    return $data->{$name};
}

# stdout($name)
# Returns captured stdout for one hook filename.
# Input: hook filename string.
# Output: stdout string or empty string.
sub stdout {
    my ($name) = @_;
    my $entry = entry($name);
    return '' if ref($entry) ne 'HASH' || !defined $entry->{stdout};
    return $entry->{stdout};
}

# stderr($name)
# Returns captured stderr for one hook filename.
# Input: hook filename string.
# Output: stderr string or empty string.
sub stderr {
    my ($name) = @_;
    my $entry = entry($name);
    return '' if ref($entry) ne 'HASH' || !defined $entry->{stderr};
    return $entry->{stderr};
}

# exit_code($name)
# Returns captured exit code for one hook filename.
# Input: hook filename string.
# Output: integer exit code or undef.
sub exit_code {
    my ($name) = @_;
    my $entry = entry($name);
    return if ref($entry) ne 'HASH';
    return $entry->{exit_code};
}

# last_name()
# Returns the last sorted hook filename currently present in RESULT.
# Input: none.
# Output: hook filename string or undef.
sub last_name {
    my @names = names();
    return $names[-1];
}

# last_entry()
# Returns the structured RESULT entry for the last sorted hook filename.
# Input: none.
# Output: hash reference or undef.
sub last_entry {
    my $name = last_name();
    return entry($name);
}

# report(%args)
# Builds a compact command hook report from the current RESULT payload.
# Input: optional command name override.
# Output: UTF-8 encoded formatted multi-line report string.
sub report {
    shift if @_ && defined $_[0] && !ref($_[0]) && $_[0] eq __PACKAGE__;
    my (%args) = @_;
    my @names = names();
    return '' if !@names;

    my $command = defined $args{command} && $args{command} ne ''
      ? $args{command}
      : _command_name();

    my @lines = (
        '----------------------------------------',
        sprintf( '%s Run Report', $command ),
        '----------------------------------------',
    );

    for my $name (@names) {
        my $exit_code = exit_code($name);
        my $icon = defined $exit_code && $exit_code == 0 ? '✅' : '🚨';
        push @lines, sprintf( '%s %s', $icon, $name );
    }

    push @lines, '----------------------------------------';
    return encode( 'UTF-8', join( "\n", @lines ) . "\n" );
}

# _command_name()
# Resolves the current dashboard command name for RESULT reports.
# Input: none.
# Output: short command name string.
sub _command_name {
    my $name = $ENV{DEVELOPER_DASHBOARD_COMMAND} || '';
    return $name if $name ne '';

    my $script = $0 || '';
    return 'dashboard' if $script eq '';
    my $base = basename($script);
    return $base if $base ne '' && $base ne '/' && $base ne '\\';

    my $parent = basename( dirname($script) );
    return $parent if $parent ne '' && $parent ne '/' && $parent ne '\\';
    return 'dashboard';
}

1;

__END__

=head1 NAME

Runtime::Result - helper accessors for dashboard hook RESULT JSON

=head1 SYNOPSIS

  use Runtime::Result;

  my $all    = Runtime::Result::current();
  my $stdout = Runtime::Result::stdout('00-first.pl');
  my $last   = Runtime::Result::last_entry();

=head1 DESCRIPTION

This module decodes the C<RESULT> environment variable populated by
C<dashboard> command hook execution and provides small helper accessors for
reading per-hook stdout, stderr, and exit codes from Perl hook scripts.

=head1 FUNCTIONS

=head2 current, names, has, entry, stdout, stderr, exit_code, last_name, last_entry, report

Decode and read the current C<RESULT> JSON payload.

=cut
