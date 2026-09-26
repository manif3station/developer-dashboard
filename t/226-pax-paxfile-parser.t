#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);

use lib 'lib';
use Developer::Dashboard::Pax::Paxfile;

# DD-1059: bring Pax/Paxfile.pm to 100 percent Devel::Cover on all four
# metrics (statement, branch, condition, subroutine). Baseline was 11.5
# percent - only the BEGIN block and package/use lines had ever run,
# because nothing in the suite exercised load_optional/load/_scalar.

my $dir = tempdir(CLEANUP => 1);

# AC: load_optional returns {} when the file does not exist, using the
# default path when none is given.
{
    chdir $dir or die "chdir $dir: $!";
    ok(!-f 'paxfile.yml', 'no paxfile.yml in the fresh tempdir');
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load_optional,
        {},
        'load_optional with no path and no file present returns {} (default path branch, missing-file branch)'
    );
}

# AC: load_optional returns {} when an explicit path does not exist.
{
    my $missing = "$dir/does-not-exist.yml";
    ok(!-f $missing, 'explicit path does not exist');
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load_optional($missing),
        {},
        'load_optional with an explicit missing path returns {} without calling load'
    );
}

# AC: load_optional delegates to load when the file exists.
{
    my $path = "$dir/present.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "name: demo\n";
    close $fh;
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load_optional($path),
        { name => 'demo' },
        'load_optional delegates to load when the file exists'
    );
}

# AC: load dies with a clear message when the file cannot be opened.
# A nonexistent path (ENOENT) fails open() unconditionally, including
# when running as root (unlike a chmod-0000 existing file, which root's
# own permission bypass would open successfully).
{
    my $unreadable = "$dir/does-not-exist-when-opened.yml";
    ok(!-e $unreadable, 'the path used for this open()-failure case does not exist at all');
    eval { Developer::Dashboard::Pax::Paxfile->load($unreadable) };
    like(
        $@,
        qr/\Qcannot read $unreadable\E/,
        'load dies with "cannot read PATH: ..." when open() fails'
    );
}

# AC: load skips blank lines and full-line comments.
{
    my $path = "$dir/blanks-and-comments.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "\n";
    print {$fh} "# a full-line comment\n";
    print {$fh} "   \n";
    print {$fh} "   # indented comment\n";
    print {$fh} "name: ok\n";
    close $fh;
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load($path),
        { name => 'ok' },
        'blank lines and comment-only lines (plain and indented) are skipped'
    );
}

# AC: load strips a trailing inline comment and trailing CR from a line.
{
    my $path = "$dir/inline-comment.yml";
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} "name: demo # trailing comment\r\n";
    close $fh;
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load($path),
        { name => 'demo' },
        'a trailing inline comment and a trailing CR are both stripped before parsing'
    );
}

# AC: a key with a value starts (or continues) as a plain scalar,
# clearing any prior open section.
{
    my $path = "$dir/scalar-after-section.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "deps:\n";
    print {$fh} "  - one\n";
    print {$fh} "name: demo\n";
    close $fh;
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load($path),
        { deps => ['one'], name => 'demo' },
        'a scalar key after a section line clears $section (section-then-scalar branch)'
    );
}

# AC: a key with an empty value opens a new list section, initialised
# to an empty arrayref even if no items ever follow.
{
    my $path = "$dir/empty-section.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "deps:\n";
    close $fh;
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load($path),
        { deps => [] },
        'a section header with no items yields an empty arrayref'
    );
}

# AC: multiple "- value" lines under one section all accumulate.
{
    my $path = "$dir/multi-item-section.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "deps:\n";
    print {$fh} "  - one\n";
    print {$fh} "  - two\n";
    print {$fh} "  - three\n";
    close $fh;
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load($path),
        { deps => [ 'one', 'two', 'three' ] },
        'multiple "- value" lines under one section all push onto the same arrayref'
    );
}

# AC: a "- value" line with no section currently open is unsupported
# syntax and dies.
{
    my $path = "$dir/orphan-item.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "- orphan\n";
    close $fh;
    eval { Developer::Dashboard::Pax::Paxfile->load($path) };
    like(
        $@,
        qr/unsupported paxfile\.yml syntax: - orphan/,
        'a "- value" line with no open section dies as unsupported syntax'
    );
}

# AC: a line matching neither key:value nor "- value", with NO section
# open, dies as unsupported syntax (the $section-undef short-circuit
# side of the "defined $section && ..." condition at line 39).
{
    my $path = "$dir/garbage-line.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "this is not valid syntax at all !!!\n";
    close $fh;
    eval { Developer::Dashboard::Pax::Paxfile->load($path) };
    like(
        $@,
        qr/unsupported paxfile\.yml syntax: this is not valid syntax at all !!!/,
        'a line matching neither a key nor a section item dies as unsupported syntax'
    );
}

# AC: a garbage line while a section IS open also dies as unsupported
# syntax (the $section-defined-but-no-match side of the same "defined
# $section && ..." condition at line 39 - the combination the previous
# two cases above do not reach between them).
{
    my $path = "$dir/garbage-line-with-section-open.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "deps:\n";
    print {$fh} "this is not a section item either\n";
    close $fh;
    eval { Developer::Dashboard::Pax::Paxfile->load($path) };
    like(
        $@,
        qr/unsupported paxfile\.yml syntax: this is not a section item either/,
        'a garbage line with a section already open still dies as unsupported syntax'
    );
}

# AC: re-declaring the same section name a second time does NOT reset
# the array already accumulated under it - the //= at line 31 only
# assigns when $data{$section} is still undef.
{
    my $path = "$dir/repeated-section-header.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "deps:\n";
    print {$fh} "  - one\n";
    print {$fh} "deps:\n";
    print {$fh} "  - two\n";
    close $fh;
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load($path),
        { deps => [ 'one', 'two' ] },
        'a repeated section header appends to the existing arrayref rather than resetting it'
    );
}

# AC: _scalar trims surrounding whitespace and strips matching double
# or single quotes, and leaves an unquoted value alone.
{
    my $path = "$dir/scalar-forms.yml";
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} qq{plain: bare-value\n};
    print {$fh} qq{dq: "double quoted"\n};
    print {$fh} qq{sq: 'single quoted'\n};
    print {$fh} qq{mismatched: "unterminated\n};
    close $fh;
    is_deeply(
        Developer::Dashboard::Pax::Paxfile->load($path),
        {
            plain       => 'bare-value',
            dq          => 'double quoted',
            sq          => 'single quoted',
            mismatched  => '"unterminated',
        },
        '_scalar strips matching double/single quotes, leaves plain and mismatched-quote values untouched'
    );
}

done_testing();

__END__

=head1 NAME

226-pax-paxfile-parser.t - full coverage regression test for Developer::Dashboard::Pax::Paxfile

=head1 DESCRIPTION

This test exercises every statement, branch, condition and subroutine in
Developer::Dashboard::Pax::Paxfile's paxfile.yml parser: the default-path
and missing-file behavior of load_optional, every line-parsing branch in
load (blank/comment lines, scalar keys, section headers, section items,
unsupported syntax, an open() failure), and the quote-stripping behavior
of _scalar.

=for comment FULL-POD-DOC START

=head1 PURPOSE

This test is the executable regression contract that closes DD-1059's
coverage gap for Paxfile.pm. Read it when you need to see exactly which
paxfile.yml shapes this parser accepts and rejects, instead of inferring
that from the module alone.

=head1 WHY IT EXISTS

Paxfile.pm had no dedicated test file before DD-1059, so real CI coverage
sat at 11.5 percent - only the package/use lines had ever run. This file
exists to make every parsing path (and its failure modes) an explicit,
checkable assertion rather than an assumption.

=head1 WHEN TO USE

Use this file when changing paxfile.yml's accepted syntax, the shape of
the hash/array structure load() returns, or _scalar's quote-stripping
rules - or when a focused CI/coverage failure points here.

=head1 HOW TO USE

Run it directly with C<prove -lv t/226-pax-paxfile-parser.t> while
iterating, then keep it green under C<prove -lr t> and confirm
C<cover -report -select_re '^lib/Developer/Dashboard/Pax/Paxfile\.pm$'>
still reads 100.0 on all four metrics before release.

=head1 WHAT USES IT

Developers during TDD, the full C<prove -lr t> suite, the Devel::Cover
gate for this file, and the release verification loop all rely on this
file to keep Paxfile.pm's parsing behavior from drifting unnoticed.

=head1 EXAMPLES

Example 1:

  prove -lv t/226-pax-paxfile-parser.t

Run the focused regression test by itself while changing Paxfile.pm.

Example 2:

  HARNESS_PERL_SWITCHES=-MDevel::Cover prove -lv t/226-pax-paxfile-parser.t

Exercise the same focused test while collecting coverage for Paxfile.pm.

Example 3:

  prove -lr t

Put the focused fix back through the whole repository suite before
calling the work finished.

=for comment FULL-POD-DOC END

=cut
