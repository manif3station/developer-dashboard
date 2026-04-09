package Developer::Dashboard::Runtime::Result;

use strict;
use warnings;
use utf8;

our $VERSION = '2.12';

use Encode qw(encode);
use File::Basename qw(basename dirname);
use File::Temp qw(tempfile);
use Fcntl qw(F_GETFD F_SETFD FD_CLOEXEC SEEK_SET);
use JSON::XS qw(decode_json encode_json);

my $RESULT_FILE_HANDLE;
my $RESULT_FILE_PATH = '';

# current()
# Decodes the current RESULT environment variable into a hash reference.
# Input: none.
# Output: hash reference keyed by hook filename.
sub current {
    my $json = _current_json();
    return {} if !defined $json || $json eq '';
    my $data = decode_json($json);
    die 'RESULT must decode to a hash' if ref($data) ne 'HASH';
    return $data;
}

# set_current($data, %args)
# Serializes hook RESULT state back into the environment. Uses inline RESULT JSON
# while the payload stays small enough for safe exec(), then falls back to a
# file-backed RESULT_FILE channel when the payload grows too large.
# Input: hash reference of hook results plus an optional max_inline_bytes integer.
# Output: storage mode string: inline, file, or empty.
sub set_current {
    my ( $data, %args ) = @_;
    die 'RESULT state must be a hash' if ref($data) ne 'HASH';
    return clear_current() if !%{$data};

    my $json = encode_json($data);
    if ( length($json) <= _max_inline_bytes(%args) ) {
        _clear_result_file();
        $ENV{RESULT} = $json;
        delete $ENV{RESULT_FILE};
        return 'inline';
    }

    my ( $fh, $path ) = _open_result_file();
    print {$fh} $json;
    truncate( $fh, tell($fh) ) or die "Unable to truncate RESULT file $path: $!";
    seek( $fh, 0, SEEK_SET ) or die "Unable to rewind RESULT file $path: $!";

    _clear_result_file();
    $RESULT_FILE_HANDLE = $fh;
    $RESULT_FILE_PATH   = $path;
    delete $ENV{RESULT};
    $ENV{RESULT_FILE} = $path;
    return 'file';
}

# clear_current()
# Removes the active RESULT payload from both inline and file-backed channels.
# Input: none.
# Output: empty string.
sub clear_current {
    delete $ENV{RESULT};
    delete $ENV{RESULT_FILE};
    _clear_result_file();
    return '';
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

# _current_json()
# Loads the current RESULT payload from inline env JSON or the file-backed
# RESULT_FILE fallback used when exec() would overflow the kernel arg/env limit.
# Input: none.
# Output: JSON string or empty string.
sub _current_json {
    my $json = $ENV{RESULT};
    return $json if defined $json && $json ne '';

    my $path = $ENV{RESULT_FILE} || '';
    return '' if $path eq '';
    open my $fh, '<:raw', $path or die "Unable to read RESULT file $path: $!";
    local $/;
    my $file_json = <$fh>;
    close $fh or die "Unable to close RESULT file $path: $!";
    return defined $file_json ? $file_json : '';
}

# _max_inline_bytes(%args)
# Returns the maximum inline RESULT JSON size before file-backed fallback kicks
# in. This stays conservative so later exec() calls do not trip E2BIG.
# Input: optional max_inline_bytes override.
# Output: positive integer byte count.
sub _max_inline_bytes {
    my (%args) = @_;
    return $args{max_inline_bytes}
      if defined $args{max_inline_bytes} && $args{max_inline_bytes} =~ /\A\d+\z/;
    return $ENV{DEVELOPER_DASHBOARD_RESULT_INLINE_MAX}
      if defined $ENV{DEVELOPER_DASHBOARD_RESULT_INLINE_MAX}
      && $ENV{DEVELOPER_DASHBOARD_RESULT_INLINE_MAX} =~ /\A\d+\z/;
    return 65536;
}

# _open_result_file()
# Opens one inherited file descriptor that child hook/command exec() calls can
# read through RESULT_FILE without inflating the process environment.
# Input: none.
# Output: filehandle and portable fd-backed path string.
sub _open_result_file {
    my ( $fh, $path ) = tempfile( 'dashboard-result-XXXXXX', TMPDIR => 1, UNLINK => 1 );
    binmode $fh, ':raw';

    my $flags = fcntl( $fh, F_GETFD, 0 );
    die "Unable to inspect RESULT file descriptor flags: $!" if !defined $flags;
    fcntl( $fh, F_SETFD, $flags & ~FD_CLOEXEC )
      or die "Unable to clear close-on-exec for RESULT file descriptor: $!";

    my $fd = fileno($fh);
    my $fd_path = -e "/dev/fd/$fd" ? "/dev/fd/$fd" : "/proc/self/fd/$fd";
    return ( $fh, $fd_path );
}

# _clear_result_file()
# Releases the inherited RESULT_FILE handle when inline RESULT JSON is enough or
# when the payload is being cleared entirely.
# Input: none.
# Output: none.
sub _clear_result_file {
    return if !$RESULT_FILE_HANDLE;
    close $RESULT_FILE_HANDLE or die "Unable to close RESULT file handle for $RESULT_FILE_PATH: $!";
    undef $RESULT_FILE_HANDLE;
    $RESULT_FILE_PATH = '';
}

# _command_name()
# Resolves the current dashboard command name for RESULT reports.
# Derives the command name from $0 first, then falls back to
# DEVELOPER_DASHBOARD_COMMAND env var if $0 is not valid.
# Handles special case where $0 basename is 'run' (directory-backed custom command).
# Input: none.
# Output: short command name string.
sub _command_name {
    my $script = $0 || '';
    if ( $script eq '' ) {
        my $name = $ENV{DEVELOPER_DASHBOARD_COMMAND} || '';
        return $name if $name ne '';
        return 'dashboard';
    }

    my $normalized = $script;
    $normalized =~ s{[\\/]+\z}{} if $normalized !~ m{\A(?:[\\/]|[A-Za-z]:[\\/]?)\z};
    return 'dashboard' if $normalized eq '' || $normalized eq '/' || $normalized eq '\\' || $normalized =~ m{\A[A-Za-z]:[\\/]?\z};

    my $base = basename($normalized);
    return $base if $base ne '' && $base ne '/' && $base ne '\\' && $base ne 'run';

    my $parent = basename( dirname($normalized) );
    return $parent if $parent ne '' && $parent ne '/' && $parent ne '\\';

    my $name = $ENV{DEVELOPER_DASHBOARD_COMMAND} || '';
    return $name if $name ne '';
    return 'dashboard';
}

1;

__END__

=head1 NAME

Developer::Dashboard::Runtime::Result - helper accessors for dashboard hook RESULT JSON

=head1 SYNOPSIS

  use Developer::Dashboard::Runtime::Result;

  my $all    = Developer::Dashboard::Runtime::Result::current();
  my $mode   = Developer::Dashboard::Runtime::Result::set_current($all);
  my $stdout = Developer::Dashboard::Runtime::Result::stdout('00-first.pl');
  my $last   = Developer::Dashboard::Runtime::Result::last_entry();
  Developer::Dashboard::Runtime::Result::clear_current();

=head1 DESCRIPTION

This module decodes the hook-result payload populated by C<dashboard> command
hook execution. Small payloads stay inline in C<RESULT>. Oversized payloads
spill into C<RESULT_FILE> before later C<exec()> calls would hit the kernel
arg/env limit. The helper accessors hide that transport detail and provide one
consistent way to read per-hook stdout, stderr, and exit codes from Perl hook
scripts.

=head1 FUNCTIONS

=head2 current, set_current, clear_current, names, has, entry, stdout, stderr, exit_code, last_name, last_entry, report

Decode, write, clear, and report the current hook-result payload, whether it is
stored inline in C<RESULT> or spilled into C<RESULT_FILE>.

=for comment FULL-POD-DOC START

=head1 PURPOSE

Perl module in the Developer Dashboard codebase. This file reads and writes the RESULT payload shared between layered command hooks.
Open this file when you need the implementation, regression coverage, or runtime entrypoint for that responsibility rather than guessing which part of the tree owns it.

=head1 WHY IT EXISTS

It exists to keep this responsibility in reusable Perl code instead of hiding it in the thin C<dashboard> switchboard, bookmark text, or duplicated helper scripts. That separation makes the runtime easier to test, safer to change, and easier for contributors to navigate.

=head1 WHEN TO USE

Use this file when you are changing the underlying runtime behaviour it owns, when you need to call its routines from another part of the project, or when a failing test points at this module as the real owner of the bug.

=head1 HOW TO USE

Load C<Developer::Dashboard::Runtime::Result> from Perl code under C<lib/> or from a focused test, then use the public routines documented in the inline function comments and existing SYNOPSIS/METHODS sections. This file is not a standalone executable.

=head1 WHAT USES IT

This file is used by whichever runtime path owns this responsibility: the public C<dashboard> entrypoint, staged private helper scripts under C<share/private-cli/>, the web runtime, update flows, and the focused regression tests under C<t/>.

=head1 EXAMPLES

  perl -Ilib -MDeveloper::Dashboard::Runtime::Result -e 'print qq{loaded\n}'

That example is only a quick load check. For real usage, follow the public routines already described in the inline code comments and any existing SYNOPSIS section.

=for comment FULL-POD-DOC END

=cut
