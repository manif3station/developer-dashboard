use strict;
use warnings;
use utf8;

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so this
# process runs the tip's Perl modules exactly like the CLI subprocesses
# already do (prove's -I only names the blib). Same pattern as t/995.
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Capture::Tiny qw(capture);
use Developer::Dashboard::CLI::OpenFileGrep qw(grep_matching_files);
use File::Temp qw(tempdir);
use Test::More;

plan tests => 6;

diag 'before: build fixture dir with a needle file';
my $dir = tempdir( CLEANUP => 1 );
my $target = File::Spec->catfile( $dir, 'content-match.txt' );
open my $fh, '>', $target or die "Unable to write $target: $!";
print {$fh} "needle is in the file body\n";
close $fh or die "Unable to close $target: $!";
diag "after: fixture dir is $dir, target is $target";

# Test 1 - control: a plain Perl-native content search finds the needle.
# Must pass on every leg; if this fails the fixture is bad, not the product.
diag 'before: control - Perl-native search of the fixture dir';
my $native_found = 0;
opendir my $dh, $dir or die "Unable to open $dir: $!";
while ( my $entry = readdir $dh ) {
    next if $entry !~ /\.txt\z/;
    my $path = File::Spec->catfile( $dir, $entry );
    open my $ifh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $body = <$ifh>;
    close $ifh;
    $native_found = 1 if defined $body && $body =~ /needle/;
}
closedir $dh;
diag "after: control - native search found needle: $native_found";
ok( $native_found, 'control: Perl-native search finds the needle file' );

# Test 2 - does a bare `grep` resolve in this process's environment?
# The product shells out to a bare `grep` via list-form system(), which
# resolves through the PATH of the process that runs the CLI. The new
# Windows box has grep.exe on disk (Git usr/bin) but that directory is
# not on the PATH the Jenkins agent carries, so this is expected to fail
# on Windows and pass on Unix.
diag 'before: run bare grep --version via list-form system';
my ( $v_out, $v_err, $v_code, $v_errno );
( $v_out, $v_err, $v_code ) = capture {
    my $status = system 'grep', '--version';
    $v_errno = $! if $status == -1;
    return $status == -1 ? -1 : ( $status >> 8 );
};
diag "after: grep --version exit=$v_code errno=[$v_errno] stdout=[$v_out] stderr=[$v_err]";
ok( $v_code == 0, 'bare grep resolves and runs (--version exits 0)' );

# Test 3 - the exact system call the product makes, observed raw.
diag 'before: run grep -H -n -nr needle <dir> via list-form system';
my ( $g_out, $g_err, $g_code, $g_errno );
( $g_out, $g_err, $g_code ) = capture {
    my $status = system 'grep', '-H', '-n', '-nr', 'needle', $dir;
    $g_errno = $! if $status == -1;
    return $status == -1 ? -1 : ( $status >> 8 );
};
diag "after: grep -nr exit=$g_code errno=[$g_errno] stdout=[$g_out] stderr=[$g_err]";
ok( $g_code == 0, 'direct grep -nr exits 0 on the fixture dir' );
like( $g_out, qr/content-match\.txt/, 'direct grep -nr output names the matching file' );

# Test 4 - the module call the CLI dispatches to, observed directly.
diag 'before: call grep_matching_files(args => [-nr, needle, dir])';
my @matches;
my $call_error = '';
{
    local $@;
    my $ok = eval { @matches = grep_matching_files( args => [ '-nr', 'needle', $dir ] ); 1 };
    $call_error = $@ if !$ok;
}
diag "after: grep_matching_files returned [@matches] error=[$call_error]";
is_deeply( \@matches, [$target], 'grep_matching_files returns the needle file' );

# Test 5 - the CLI-level repro: the exact `d2 of --print grep -nr` run
# from t/05 tests 683/684, list-form so no shell is involved.
diag 'before: run the d2 CLI of --print grep -nr needle <dir>';
my $lib_dir = File::Spec->catdir( $FindBin::Bin, '..', 'lib' );
my $dashboard = File::Spec->catfile( $FindBin::Bin, '..', 'bin', 'd2' );
my ( $c_out, $c_err, $c_code );
( $c_out, $c_err, $c_code ) = capture {
    my $status = system $^X, "-I$lib_dir", $dashboard, 'of', '--print', 'grep', '-nr', 'needle', $dir;
    return $status == -1 ? -1 : ( $status >> 8 );
};
diag "after: d2 of --print grep -nr exit=$c_code stdout=[$c_out] stderr=[$c_err]";
is( $c_out, "$target\n", 'd2 of --print grep -nr prints the matching file' );

=pod

=head1 NAME

t/996-micro-of-grep-nr.t - Micro-probe for the t/05 `d2 of grep -nr` Windows-only failure

=head1 DESCRIPTION

Solo #345 failed on Windows only at t/05 tests 683/684/685: C<d2 of
--print grep -nr needle DIR> exits 1 and prints C<No files found>, while
the identical run passes on all three Unix legs. The sibling test 682
(C<d2 open-file --print DIR alpha>) passes on Windows, so only the
content-search path fails. This micro decides which layer breaks: the
C<grep> binary not resolving in the Jenkins agent's PATH (the new
Windows box has grep.exe on disk under Git usr/bin, but that directory
is not on PATH), grep running but finding no match, or grep running and
matching but the output parser rejecting the result.

=head1 PURPOSE

Pin down the exact mechanism behind the Windows-only t/05 tests
683/684/685 failure so the fix lands in the right place (product-side
PATH handling or native search, vs test-side fixture) instead of being
guessed.

=head1 WHY IT EXISTS

The failure only surfaced now because round 34's Windows leg died at
test 296 and tests 297+ never ran there; each fix lets the leg reach
further. The product calls a bare system C<grep> via list-form
C<system()> in C<Developer::Dashboard::CLI::OpenFileGrep>, which
resolves through PATH only - the old Windows box had Git usr/bin on
PATH, the new one does not, and Strawberry's c/bin ships no grep.exe.
That must be proven in the Jenkins environment, not assumed from SSH,
because the SSH session PATH and the Jenkins agent PATH can differ.

=head1 WHEN TO USE

Run as a Jenkins solo while investigating the solo #345 t/05 tests
683/684/685 failure. Remove in a cleanup commit when the investigation
ends, like every other micro.

=head1 HOW TO USE

Trigger as a Jenkins solo: TEST_FILE=t/996-micro-of-grep-nr.t on
branch windows/loop6-combined. Never run by hand against the nodes.

=head1 WHAT USES IT

Nothing in production uses this file. It is a throwaway investigation
micro for the testing-v1 loop.

=head1 EXAMPLES

A solo run proves the mechanism when the Unix legs pass all five
tests and the Windows leg shows test 2 failing with exit -1 (grep does
not resolve), test 3 failing the same way, test 4 dying with C<Unable
to execute grep>, and test 5 printing C<No files found> - the exact
t/05 shape. If instead test 2 passes on Windows and test 3 fails with
exit 1, the binary resolves but the search itself finds nothing, which
points at path handling rather than PATH.

=cut
