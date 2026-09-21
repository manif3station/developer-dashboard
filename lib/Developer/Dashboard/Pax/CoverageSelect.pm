package Developer::Dashboard::Pax::CoverageSelect;

use strict;
use warnings;

our $VERSION = '4.65';

use Exporter 'import';
use Capture::Tiny qw(capture);
use JSON::XS ();

our @EXPORT_OK = qw(
  pax_binary_source_hash
  pax_coverage_extract_root
  pax_coverage_select_pattern
  pax_coverage_perl5opt
);

# pax_binary_source_hash($binary_path)
# Runs a built PAX standalone binary's own --pax-standalone-inspect mode and
# reads back the content-addressed source_hash its manifest reports.
# Input: path to a compiled PAX standalone binary.
# Output: the manifest's source_hash string, or undef if the binary refused
# to answer or the manifest carried no hash.
sub pax_binary_source_hash {
    my ($binary_path) = @_;
    return if !defined $binary_path || $binary_path eq '';
    return if !-x $binary_path;
    my ( $stdout, $stderr, $exit ) = capture { system( $binary_path, '--pax-standalone-inspect' ) };
    # Capture::Tiny's capture() always returns a defined string for $stdout
    # (empty when nothing was written) - never undef - so an extra
    # `!defined $stdout` guard here would be a branch nothing can ever take.
    return if $exit != 0 || $stdout eq '';
    my $manifest = eval { JSON::XS::decode_json($stdout) };
    return if !$manifest || ref $manifest ne 'HASH';
    return $manifest->{source_hash};
}

# pax_coverage_extract_root($source_hash, %opts)
# Computes the on-disk root a PAX standalone binary extracts itself into for
# a given content-addressed source_hash - StandaloneImage.pm's own compiled
# launcher already makes this path stable and reused across runs (one
# extraction per distinct source_hash, cached under TMPDIR), never a fresh
# random path per invocation.
# Input: the manifest's source_hash string; optional %opts with tmpdir
# (defaults to $ENV{TMPDIR} or '/tmp', matching the launcher's own fallback).
# Output: the absolute extraction root path string, or undef if source_hash
# is missing/empty.
sub pax_coverage_extract_root {
    my ( $source_hash, %opts ) = @_;
    return if !defined $source_hash || $source_hash eq '';
    my $tmpdir = $opts{tmpdir};
    $tmpdir = $ENV{TMPDIR} if !defined $tmpdir || $tmpdir eq '';
    $tmpdir = '/tmp'       if !defined $tmpdir || $tmpdir eq '';
    $tmpdir =~ s{/+\z}{};
    return "$tmpdir/pax-standalone-cache-$source_hash";
}

# pax_coverage_select_pattern($extract_root)
# Builds the Devel::Cover -select regex text that overrides its default
# ignore-everything-already-in-@INC behavior for one PAX extraction root -
# quoted with quotemeta so the path itself is matched literally, never
# interpreted as regex metacharacters.
# Input: an extraction root path string (from pax_coverage_extract_root).
# Output: a regex-pattern string suitable for Devel::Cover's -select option.
sub pax_coverage_select_pattern {
    my ($extract_root) = @_;
    return if !defined $extract_root || $extract_root eq '';
    return '^' . quotemeta($extract_root) . '/';
}

# pax_coverage_perl5opt($db_path, $extract_root, %opts)
# Assembles the PERL5OPT string that, set before exec'ing a PAX standalone
# binary, makes Devel::Cover collect coverage for that binary's own
# extracted Pax/*.pm files (which its bundled inc/ search path would
# otherwise cause Devel::Cover to silently ignore as library code) into a
# named coverage database.
# Input: the target Devel::Cover -db path; an extraction root path (from
# pax_coverage_extract_root); optional %opts with silent (defaults to 1).
# Output: a ready-to-use PERL5OPT string, or undef if db_path or
# extract_root is missing/empty.
sub pax_coverage_perl5opt {
    my ( $db_path, $extract_root, %opts ) = @_;
    return if !defined $db_path     || $db_path eq '';
    return if !defined $extract_root || $extract_root eq '';
    my $silent  = exists $opts{silent} ? ( $opts{silent} ? 1 : 0 ) : 1;
    my $pattern = pax_coverage_select_pattern($extract_root);
    return "-MDevel::Cover=-db,$db_path,-silent,$silent,-select,$pattern";
}

1;

__END__

=head1 NAME

Developer::Dashboard::Pax::CoverageSelect - Devel::Cover -select helpers for PAX-compiled standalone binaries

=head1 SYNOPSIS

  use Developer::Dashboard::Pax::CoverageSelect qw(
    pax_binary_source_hash pax_coverage_extract_root
    pax_coverage_select_pattern pax_coverage_perl5opt
  );

  my $hash = pax_binary_source_hash('/path/to/hello-pax');
  my $root = pax_coverage_extract_root($hash);
  local $ENV{PERL5OPT} = pax_coverage_perl5opt('/tmp/pax-cover-db', $root);
  system('/path/to/hello-pax');
  # /tmp/pax-cover-db now carries real coverage for the binary's own
  # Pax/*.pm files, not zero rows.

=head1 DESCRIPTION

A PAX-compiled standalone binary (C<dashboard pax build>) execs a bundled
copy of perl with its own extracted code tree spliced onto C<PERL5LIB>
before the exec (see C<StandaloneImage.pm>'s C<extract_runtime>). Because
that splice happens the same way an ordinary C<-I>/C<PERL5LIB> library path
does, Devel::Cover's default startup behavior - snapshot C<@INC> early and
silently ignore any file loaded from a path already present there - treats
every one of the binary's own C<Pax/*.pm> files as ignorable library code,
even though they are exactly the code this project wants measured. The
result is a coverage report with zero rows for the whole C<lib/Developer/
Dashboard/Pax/> tree (DD-929), not merely low coverage.

The fix is not to make the extraction path stable - C<StandaloneImage.pm>
already computes it from a content-addressed C<source_hash> (a SHA-256 over
every packaged file's logical path and digest, sorted for determinism) and
reuses the same on-disk extraction across repeated runs of an unchanged
binary. The missing piece is telling Devel::Cover, at collection time, to
C<-select> that already-stable path explicitly - C<-select> overrides the
default ignore-everything-already-in-C<@INC> behavior, and once told the
same coverage run correctly reports real statement/branch/condition/
subroutine data for the extracted files.

This module supplies the small pieces a coverage-gate driver needs to do
that: read a built binary's own reported C<source_hash>
(C<pax_binary_source_hash>), compute the extraction root that hash implies
(C<pax_coverage_extract_root>, mirroring C<StandaloneImage.pm>'s own
C<pax-standalone-cache-E<lt>hashE<gt>> naming), build the literal-quoted
C<-select> pattern for it (C<pax_coverage_select_pattern>), and assemble
the full C<PERL5OPT> string to set before running the binary under
coverage (C<pax_coverage_perl5opt>).

=head1 METHODS

=head2 pax_binary_source_hash

Runs a built binary's C<--pax-standalone-inspect> mode and reads its
manifest's C<source_hash> field.

=head2 pax_coverage_extract_root

Computes the stable extraction root path for a given C<source_hash>.

=head2 pax_coverage_select_pattern

Builds a literal-quoted Devel::Cover C<-select> regex for one extraction
root.

=head2 pax_coverage_perl5opt

Assembles a ready-to-use C<PERL5OPT> string targeting one extraction root
and coverage database.

=head1 PURPOSE

This module exists to give a coverage-gate driver the exact, tested pieces
needed to make Devel::Cover measure a PAX-compiled binary's own C<Pax/>
code, instead of hand-rolling C<source_hash> parsing and C<PERL5OPT>
string assembly inline in a shell script every time.

=head1 WHY IT EXISTS

DD-929 found C<lib/Developer/Dashboard/Pax/*.pm> entirely absent (zero
rows, not low coverage) from every Devel::Cover run, root-caused to
Devel::Cover's default library-path ignore behavior rather than to any
instability in the extraction path itself - a distinction worth keeping
tested and documented rather than re-discovered by the next reader.

=head1 WHEN TO USE

Use these helpers from any coverage-gate driver that needs a PAX-compiled
binary's own C<Pax/*.pm> code measured, rather than treated as opaque
vendored/tested-upstream code.

=head1 HOW TO USE

Build the binary normally with C<dashboard pax build>, pass its path to
C<pax_binary_source_hash>, feed that hash to C<pax_coverage_extract_root>,
and pass the result to C<pax_coverage_perl5opt> together with the target
C<-db> path. Set the returned string as C<PERL5OPT> for exactly the
C<system>/C<exec> call that runs the binary, then restore or unset it -
this is a per-invocation coverage concern, not a standing environment
change.

=head1 WHAT USES IT

Intended for this project's own coverage-gate tooling when measuring
C<Pax/> code exercised via C<t/182>/C<t/183>/C<t/184>'s compiled-binary
fixtures.

=head1 EXAMPLES

Example 1:

  perl -Ilib -MDeveloper::Dashboard::Pax::CoverageSelect -e 1

Confirm that the module loads from a source checkout.

Example 2:

  prove -lv t/200-pax-coverage-select.t

Run this module's own dedicated coverage test, including a real built-
binary integration assertion.

=cut
