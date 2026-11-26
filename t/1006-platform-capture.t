use strict;
use warnings;

use FindBin;
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use File::Spec;
use File::Temp qw(tempfile tempdir);
use Test::More;

use Developer::Dashboard::Platform ();

# _capture and _slurp_raw_file are private (not in @EXPORT_OK), so they
# are called by full package name throughout, never through an import
# and never as a method call (the arrow form would pass the package
# name as an extra argument).

# _capture: stdout is captured.
{
    my ( $out, $err, $rc )
        = Developer::Dashboard::Platform::_capture( sub { print "hello stdout\n"; } );
    is( $out, "hello stdout\n", 'stdout is captured' );
    is( $err, '',               'stderr is empty when only stdout is printed' );
    is( $rc,  0,                'rc is 0 on success' );
}

# _capture: stderr is captured.
{
    my ( $out, $err, $rc ) = Developer::Dashboard::Platform::_capture(
        sub { print STDERR "hello stderr\n"; } );
    is( $out, '',               'stdout is empty when only stderr is printed' );
    is( $err, "hello stderr\n", 'stderr is captured' );
    is( $rc,  0,                'rc is 0 when only stderr is printed' );
}

# _capture: both at once, kept separate, order kept inside each stream.
{
    my ( $out, $err, $rc ) = Developer::Dashboard::Platform::_capture( sub {
        print "out one\n";
        print STDERR "err one\n";
        print "out two\n";
        print STDERR "err two\n";
    } );
    is( $out, "out one\nout two\n", 'stdout is captured when both are printed' );
    is( $err, "err one\nerr two\n", 'stderr is captured when both are printed' );
    is( $rc,  0,                    'rc is 0 when both are printed' );
}

# _capture: a child process exiting 0.
{
    my ( $out, $err, $rc ) = Developer::Dashboard::Platform::_capture(
        sub { system( $^X, '-e', 'exit 0' ); } );
    is( $rc,  0,  'a child exiting 0 gives rc 0' );
    is( $out, '', 'a child exiting 0 prints nothing to stdout' );
    is( $err, '', 'a child exiting 0 prints nothing to stderr' );
}

# _capture: a child process exiting non-zero returns the raw wait
# status as $rc (3 << 8 = 768), exactly as Capture::Tiny returns it.
# The code ref runs a child through system(); calling exit() in the
# code ref itself would exit the test process.
{
    my ( $out, $err, $rc ) = Developer::Dashboard::Platform::_capture(
        sub { system( $^X, '-e', 'exit 3' ); } );
    is( $rc,  3 << 8, 'a child exiting 3 gives the raw wait status' );
    is( $out, '',     'a child exiting 3 prints nothing to stdout' );
    is( $err, '',     'a child exiting 3 prints nothing to stderr' );
}

# _capture: printed output plus a non-zero child.
{
    my ( $out, $err, $rc ) = Developer::Dashboard::Platform::_capture( sub {
        print "before exit\n";
        system( $^X, '-e', 'exit 3' );
    } );
    is( $out, "before exit\n", 'printed output is captured when the child exits non-zero' );
    is( $rc,  3 << 8,          'rc is the raw wait status when the child exits non-zero' );
}

# _capture: a spawned child writes through the redirected fd, so its
# output is captured too. This is the behaviour the explicit
# save/restore exists for: a localised glob would leave the child on
# the original fd 1.
{
    my ( $out, $err, $rc ) = Developer::Dashboard::Platform::_capture(
        sub { system( $^X, '-e', 'print "child-out\n"' ); } );
    is( $out, "child-out\n", 'a spawned child writes through the redirected fd' );
    is( $rc,  0,             'rc is 0 when the child exits 0' );
}

# _capture: a dying code ref. The die propagates with the original
# message, and both handles are restored afterwards, so a second
# capture straight after works on both streams.
{
    my $ok = eval {
        Developer::Dashboard::Platform::_capture(
            sub { print "before die\n"; die "boom\n"; } );
        1;
    };
    my $error = $@;
    ok( !$ok,         'a dying code ref makes _capture die' );
    is( $error, "boom\n", 'the original die message propagates' );
    my ( $out, $err, $rc ) = Developer::Dashboard::Platform::_capture( sub {
        print "after out\n";
        print STDERR "after err\n";
    } );
    is( $out, "after out\n", 'stdout works after a die' );
    is( $err, "after err\n", 'stderr works after a die' );
    is( $rc,  0,             'rc is 0 after a die' );
}

# _capture: empty output.
{
    my ( $out, $err, $rc )
        = Developer::Dashboard::Platform::_capture( sub { } );
    is( $out, '', 'empty output gives empty stdout' );
    is( $err, '', 'empty output gives empty stderr' );
    is( $rc,  0,  'empty output gives rc 0' );
}

# _capture: binary output is kept byte-exact. The temp files are
# opened in raw mode and slurped back raw, so NUL bytes, high bytes
# and CRLF pairs survive exactly as written.
{
    my $bytes = "\x00\x01\x02\xff\xfe\r\n\x80abc\n";
    my ( $out, $err, $rc )
        = Developer::Dashboard::Platform::_capture( sub { print $bytes; } );
    is( $out, $bytes, 'binary output is kept byte-exact' );
    is( $err, '',      'binary output leaves stderr empty' );
    is( $rc,  0,       'binary output gives rc 0' );
}

# _capture: the return is exactly three values, and the code ref's own
# return value is discarded, not passed through.
{
    my @got = Developer::Dashboard::Platform::_capture( sub { return 42; } );
    is( scalar @got, 3, '_capture returns three values' );
    is( $got[2],     0, 'rc is 0 when the code returns a value' );
}

# _capture: the caller's own $? is unchanged after the call (the DD-597
# guard). The code ref sets $? only inside the localised scope.
{
    system( $^X, '-e', 'exit 5' );
    my $before = $?;
    Developer::Dashboard::Platform::_capture( sub { print "guarded\n"; } );
    is( $?, $before, 'the caller's $? is unchanged after _capture' );
}

# _slurp_raw_file: an existing file returns its content, byte-exact.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'content.txt' );
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} "first line\nsecond line\n";
    close $fh or die "close $path: $!";
    is( Developer::Dashboard::Platform::_slurp_raw_file($path),
        "first line\nsecond line\n", 'an existing file returns its content' );
    my $crlf = File::Spec->catfile( $dir, 'crlf.txt' );
    open my $fh2, '>:raw', $crlf or die "write $crlf: $!";
    print {$fh2} "a\r\nb\r\n";
    close $fh2 or die "close $crlf: $!";
    is( Developer::Dashboard::Platform::_slurp_raw_file($crlf),
        "a\r\nb\r\n", 'CRLF bytes are returned byte-exact' );
    my $nonl = File::Spec->catfile( $dir, 'nonewline.txt' );
    open my $fh3, '>:raw', $nonl or die "write $nonl: $!";
    print {$fh3} "no newline";
    close $fh3 or die "close $nonl: $!";
    is( Developer::Dashboard::Platform::_slurp_raw_file($nonl),
        "no newline", 'content without a trailing newline is returned as-is' );
}

# _slurp_raw_file: a missing file returns an empty string.
{
    my $dir = tempdir( CLEANUP => 1 );
    is( Developer::Dashboard::Platform::_slurp_raw_file(
            File::Spec->catfile( $dir, 'missing.txt' ) ),
        '', 'a missing file returns an empty string' );
}

# _slurp_raw_file: an empty file returns an empty string.
{
    my $dir = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'empty.txt' );
    open my $fh, '>:raw', $path or die "write $path: $!";
    close $fh or die "close $path: $!";
    is( Developer::Dashboard::Platform::_slurp_raw_file($path),
        '', 'an empty file returns an empty string' );
}

done_testing();

__END__

=head1 NAME

t/1006-platform-capture.t - capture and raw slurp in Platform.pm

=head1 PURPOSE

Pin the behaviour of the two private helpers in
Developer::Dashboard::Platform that capture output without loading
Capture::Tiny: _capture, which runs a code ref with stdout and stderr
redirected to temp files, and _slurp_raw_file, which reads one file
back as raw bytes.

=head1 WHY IT EXISTS

The lightweight hot path (d2 ps1 / d2 paths) must never load
Capture::Tiny, so the capture is done by hand with temp files and
handle redirection. Neither helper was called by any existing test,
so their behaviour was unpinned and their coverage was zero. These
tests pin the existing behaviour first, so a later change to either
helper has something to catch it.

=head1 WHEN TO USE

Run it directly with C<prove -lv t/1006-platform-capture.t> while
working on Platform.pm, or as part of the full suite. Re-run it after
any change to _capture or _slurp_raw_file, and after any change to
the callers that rely on the captured output (the Windows ACL
functions and the hot path).

=head1 HOW TO USE

The file calls Developer::Dashboard::Platform::_capture and
Developer::Dashboard::Platform::_slurp_raw_file by full package name,
because neither sub is exported. The _capture checks drive a code ref
and read back the (stdout, stderr, rc) list: prints to each stream,
both at once, a child exiting 0 and a child exiting 3 (through
system(), never exit() in the code ref itself), a spawned child
printing through the redirected fd, a dying code ref with the handles
proved working afterwards, empty output, binary output kept
byte-exact, the three-value return shape, and the caller's $? left
unchanged. The _slurp_raw_file checks use a temp dir: an existing
file returns its content byte-exact, a missing file returns an empty
string, and an empty file returns an empty string. Fixture files are
written in raw mode so they have LF on every platform.

=head1 WHAT USES IT

Nothing in the product uses this file. It exercises
Developer::Dashboard::Platform::_capture and
Developer::Dashboard::Platform::_slurp_raw_file, which the Windows
ACL functions and the hot path rely on. The t/30-dashboard-loader.t
file guards the hot path against loading Capture::Tiny.

=head1 EXAMPLES

    # stdout and stderr are captured separately.
    my ( $out, $err, $rc )
        = Developer::Dashboard::Platform::_capture( sub { print "hi\n"; } );
    is( $out, "hi\n", 'stdout is captured' );

    # A non-zero child exit comes back as the raw wait status.
    my ( undef, undef, $rc ) = Developer::Dashboard::Platform::_capture(
        sub { system( $^X, '-e', 'exit 3' ); } );
    is( $rc, 3 << 8, 'raw wait status' );

    # A missing file slurps to an empty string.
    is( Developer::Dashboard::Platform::_slurp_raw_file('/no/such/file'),
        '', 'missing file returns empty string' );

=cut
