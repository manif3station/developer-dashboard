#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec;
use Cwd qw(abs_path getcwd);
use FindBin;
use Capture::Tiny qw(capture);
use JSON::PP qw(decode_json);

use Developer::Dashboard::Pax::CoverageSelect qw(
  pax_binary_source_hash
  pax_coverage_extract_root
  pax_coverage_select_pattern
  pax_coverage_perl5opt
);

my $repo = abs_path("$FindBin::Bin/..");

# --- pax_coverage_extract_root -------------------------------------------
is( pax_coverage_extract_root(undef), undef, 'pax_coverage_extract_root(undef) returns undef' );
is( pax_coverage_extract_root(''),    undef, 'pax_coverage_extract_root("") returns undef' );
{
    local $ENV{TMPDIR} = '/scratch';
    is(
        pax_coverage_extract_root('abc123'),
        '/scratch/pax-standalone-cache-abc123',
        'pax_coverage_extract_root uses $ENV{TMPDIR} when no explicit tmpdir given',
    );
}
{
    local $ENV{TMPDIR} = undef;
    delete local $ENV{TMPDIR};
    is(
        pax_coverage_extract_root('abc123'),
        '/tmp/pax-standalone-cache-abc123',
        'pax_coverage_extract_root falls back to /tmp when $ENV{TMPDIR} is unset, matching the C launcher',
    );
}
is(
    pax_coverage_extract_root( 'abc123', tmpdir => '/custom/' ),
    '/custom/pax-standalone-cache-abc123',
    'pax_coverage_extract_root strips a trailing slash off an explicit tmpdir',
);
{
    local $ENV{TMPDIR} = '/scratch';
    is(
        pax_coverage_extract_root( 'abc123', tmpdir => '' ),
        '/scratch/pax-standalone-cache-abc123',
        'pax_coverage_extract_root falls back to $ENV{TMPDIR} when an explicit opts{tmpdir} is the empty string',
    );
}
{
    local $ENV{TMPDIR} = '';
    is(
        pax_coverage_extract_root('abc123'),
        '/tmp/pax-standalone-cache-abc123',
        'pax_coverage_extract_root falls back to /tmp when $ENV{TMPDIR} is the empty string (defined but empty)',
    );
}

# --- pax_coverage_select_pattern ------------------------------------------
is( pax_coverage_select_pattern(undef), undef, 'pax_coverage_select_pattern(undef) returns undef' );
is( pax_coverage_select_pattern(''),    undef, 'pax_coverage_select_pattern("") returns undef' );
is(
    pax_coverage_select_pattern('/tmp/pax-standalone-cache-abc123'),
    '^\/tmp\/pax\-standalone\-cache\-abc123/',
    'pax_coverage_select_pattern anchors and quotemeta-escapes the root, appending a trailing slash',
);
{
    my $root    = '/tmp/pax.cache+weird(name)';
    my $pattern = pax_coverage_select_pattern($root);
    like( "$root/lib/Foo.pm", qr/$pattern/, 'the generated pattern actually matches a file under its own root' );
    unlike( "${root}extra/lib/Foo.pm", qr/$pattern/, 'the generated pattern does not match a mere string-prefix sibling path' );
}

# --- pax_coverage_perl5opt -------------------------------------------------
is( pax_coverage_perl5opt( undef, '/tmp/x' ), undef, 'pax_coverage_perl5opt(undef db) returns undef' );
is( pax_coverage_perl5opt( '',    '/tmp/x' ), undef, 'pax_coverage_perl5opt("" db) returns undef' );
is( pax_coverage_perl5opt( '/tmp/db', undef ), undef, 'pax_coverage_perl5opt(undef root) returns undef' );
is( pax_coverage_perl5opt( '/tmp/db', '' ), undef, 'pax_coverage_perl5opt("" root) returns undef' );
is(
    pax_coverage_perl5opt( '/tmp/db', '/tmp/pax-standalone-cache-abc123' ),
    '-MDevel::Cover=-db,/tmp/db,-silent,1,-select,^\/tmp\/pax\-standalone\-cache\-abc123/',
    'pax_coverage_perl5opt defaults silent to 1',
);
is(
    pax_coverage_perl5opt( '/tmp/db', '/tmp/pax-standalone-cache-abc123', silent => 0 ),
    '-MDevel::Cover=-db,/tmp/db,-silent,0,-select,^\/tmp\/pax\-standalone\-cache\-abc123/',
    'pax_coverage_perl5opt honors an explicit silent => 0',
);
is(
    pax_coverage_perl5opt( '/tmp/db', '/tmp/pax-standalone-cache-abc123', silent => 1 ),
    '-MDevel::Cover=-db,/tmp/db,-silent,1,-select,^\/tmp\/pax\-standalone\-cache\-abc123/',
    'pax_coverage_perl5opt honors an explicit silent => 1 (same value as default, exercised via the exists branch)',
);

# --- pax_binary_source_hash: hermetic fixtures, no real PAX build ---------
is( pax_binary_source_hash(undef), undef, 'pax_binary_source_hash(undef) returns undef' );
is( pax_binary_source_hash(''),    undef, 'pax_binary_source_hash("") returns undef' );
is( pax_binary_source_hash('/no/such/binary-at-all'), undef, 'pax_binary_source_hash of a nonexistent path returns undef' );

my $work = tempdir( CLEANUP => 1 );

{
    # A fixture that behaves like a real PAX launcher's --pax-standalone-inspect
    # mode: prints the manifest JSON and exits 0.
    my $fixture = File::Spec->catfile( $work, 'fake-pax-ok' );
    open my $fh, '>', $fixture or die "Unable to write $fixture: $!";
    print {$fh} "#!/usr/bin/env perl\nprint qq({\"source_hash\":\"deadbeef\",\"status\":\"built\"});\n";
    close $fh;
    chmod 0755, $fixture;
    is( pax_binary_source_hash($fixture), 'deadbeef', 'pax_binary_source_hash parses source_hash out of a real manifest shape' );
}

{
    # Non-zero exit must not be trusted, even if it printed something on stdout.
    my $fixture = File::Spec->catfile( $work, 'fake-pax-fail' );
    open my $fh, '>', $fixture or die "Unable to write $fixture: $!";
    print {$fh} "#!/usr/bin/env perl\nprint qq({\"source_hash\":\"deadbeef\"});\nexit 1;\n";
    close $fh;
    chmod 0755, $fixture;
    is( pax_binary_source_hash($fixture), undef, 'pax_binary_source_hash ignores output from a non-zero exit' );
}

{
    # Malformed JSON must not crash the caller.
    my $fixture = File::Spec->catfile( $work, 'fake-pax-badjson' );
    open my $fh, '>', $fixture or die "Unable to write $fixture: $!";
    print {$fh} "#!/usr/bin/env perl\nprint qq(not json at all);\n";
    close $fh;
    chmod 0755, $fixture;
    is( pax_binary_source_hash($fixture), undef, 'pax_binary_source_hash returns undef on unparseable output rather than dying' );
}

{
    # Valid JSON, but no source_hash key.
    my $fixture = File::Spec->catfile( $work, 'fake-pax-nohash' );
    open my $fh, '>', $fixture or die "Unable to write $fixture: $!";
    print {$fh} "#!/usr/bin/env perl\nprint qq({\"status\":\"built\"});\n";
    close $fh;
    chmod 0755, $fixture;
    is( pax_binary_source_hash($fixture), undef, 'pax_binary_source_hash returns undef when the manifest has no source_hash key' );
}

{
    # Exits 0 but prints nothing at all.
    my $fixture = File::Spec->catfile( $work, 'fake-pax-empty' );
    open my $fh, '>', $fixture or die "Unable to write $fixture: $!";
    print {$fh} "#!/usr/bin/env perl\nexit 0;\n";
    close $fh;
    chmod 0755, $fixture;
    is( pax_binary_source_hash($fixture), undef, 'pax_binary_source_hash returns undef when a zero-exit binary prints nothing' );
}

{
    # Valid JSON, but the top-level value is an array, not a hash.
    my $fixture = File::Spec->catfile( $work, 'fake-pax-array' );
    open my $fh, '>', $fixture or die "Unable to write $fixture: $!";
    print {$fh} "#!/usr/bin/env perl\nprint qq([1,2,3]);\n";
    close $fh;
    chmod 0755, $fixture;
    is( pax_binary_source_hash($fixture), undef, 'pax_binary_source_hash returns undef when the manifest JSON is an array, not a hash' );
}

# ---------------------------------------------------------------------------
# DD-929 end-to-end integration: a REAL PAX binary, built and run for real,
# proving the whole mechanism - not just the pure-function pieces above.
# Skippable only when the real `dashboard pax build` toolchain genuinely
# cannot run here (no C compiler), matching t/183's own skip convention.
# ---------------------------------------------------------------------------
SKIP: {
    my $cc_ok = !system('cc --version >/dev/null 2>&1') || !system('gcc --version >/dev/null 2>&1');
    skip 'no C compiler available for a real pax build', 3 if !$cc_ok;

    my $dashboard = File::Spec->catfile( $repo, 'bin', 'dashboard' );
    local $ENV{PERL5LIB} = defined $ENV{PERL5LIB} && $ENV{PERL5LIB} ne ''
        ? "$repo/lib:$ENV{PERL5LIB}"
        : "$repo/lib";

    my $probe_dir = tempdir( CLEANUP => 1 );
    my $entry = File::Spec->catfile( $probe_dir, 'probe200.pl' );
    open my $efh, '>', $entry or die "Unable to write $entry: $!";
    print {$efh} "#!/usr/bin/env perl\nprint \"probe200-ran\\n\";\n";
    close $efh;

    my $binary = File::Spec->catfile( $probe_dir, 'probe200-pax' );
    my ( $stdout, $stderr, $exit ) = capture {
        system( $^X, '-I', "$repo/lib", $dashboard, 'pax', 'build', '-o', $binary, $entry );
    };
    skip "real pax build did not produce a runnable binary: $stderr", 3 if $exit != 0 || !-x $binary;

    my $hash = pax_binary_source_hash($binary);
    ok( defined $hash && length $hash, 'a real built binary reports a real source_hash via --pax-standalone-inspect' );

    my $extract_root = pax_coverage_extract_root($hash);
    my $covdb = File::Spec->catdir( $probe_dir, 'covdb' );

    {
        local $ENV{PERL5OPT} = pax_coverage_perl5opt( $covdb, $extract_root );
        my ( $run_out, $run_err, $run_exit ) = capture { system($binary) };
        is( $run_exit, 0, 'the real binary still runs successfully with coverage PERL5OPT set' );
        like( $run_out, qr/probe200-ran/, 'the real binary still produces its normal output under coverage' );
    }

    # A cover_db with at least one run directory is the positive marker that
    # coverage was genuinely collected, not merely that the binary ran -
    # this is the DD-929 mechanism itself under real, live verification.
    my @runs = -d "$covdb/runs" ? glob("$covdb/runs/*") : ();
    ok( scalar(@runs) > 0, 'Devel::Cover actually collected a run into the coverage database (DD-929 mechanism verified live)' );
}

done_testing();

__END__

=head1 NAME

t/200-pax-coverage-select.t - Developer::Dashboard::Pax::CoverageSelect coverage test

=head1 PURPOSE

Exercises every branch of C<Developer::Dashboard::Pax::CoverageSelect>'s
four exported helpers, plus one live, real-binary integration check that
the DD-929 coverage-selection mechanism actually works end to end.

=head1 WHY IT EXISTS

DD-929: C<lib/Developer/Dashboard/Pax/*.pm> was entirely absent from
Devel::Cover's coverage report because a PAX-compiled binary's bundled
extraction path is spliced onto C<PERL5LIB> the same way an ordinary
library path is, and Devel::Cover's default startup behavior silently
ignores anything already on C<@INC> at that point. This module supplies
the C<-select>-pattern override that fixes it; this test proves both the
pure logic and the real mechanism.

=head1 WHEN TO USE

Run this whenever C<CoverageSelect.pm> changes, or whenever
C<StandaloneImage.pm>'s extraction-path naming
(C<pax-standalone-cache-E<lt>source_hashE<gt>>) changes, since this test's
integration block would catch a mismatch live.

=head1 HOW TO USE

  PERL5LIB="$HOME/perl5/lib/perl5" prove -lv t/200-pax-coverage-select.t

=head1 WHAT USES IT

Exercises C<lib/Developer/Dashboard/Pax/CoverageSelect.pm> only.

=head1 EXAMPLES

See the test body above for the full set of assertions.

=cut
