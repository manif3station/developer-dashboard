use strict;
use warnings;
use utf8;

# Micro-repro v7 for Jenkins build #108: t/05 tests 782 and 809 fail
# on Windows only, both seeing "hook-one\n\n" / "custom-hook\n\n"
# (two LFs) where one "\n" is expected.
#
# Micro v6 (build #109) proved the drain itself captures "hook-one\r\n"
# (the child perl's :crlf layer) and that the in-process RESULT
# round-trip and file round-trip preserve it byte-identically - so the
# extra newline is NOT in the drain, NOT in RESULT, and NOT in a file
# write/read done by the test process. But t/05's got is "\n\n", not
# "\r\n", so a conversion from "\r\n" to "\n\n" happens on the real
# d2 path in a stage v6 does not cover: either inside d2 before the
# second hook reads RESULT, or in the second hook (a child process)
# writing the file.
#
# This micro runs the REAL d2 jq with the REAL t/05 hook fixtures,
# but the second hook dumps the exact RESULT bytes it sees (escaped
# [CR]/[LF]) to its own stdout, so the test can see them. The test
# then reads the result file two ways - the normal slurp (as t/05
# does) and a :raw slurp (the actual file bytes) - and logs both
# escaped. Together the three byte dumps pin the conversion stage:
#  - HOOK2-SEES [CR][LF] + file raw [CR][CR][LF] + slurp [CR][LF]:
#    the value reaching the test is "\r\n", so #108's "\n\n" came
#    from somewhere else (re-examine #108).
#  - HOOK2-SEES [LF][LF]: the conversion is inside d2, before the
#    second hook reads RESULT (drain-in-d2 differs from v6's drain).
#  - HOOK2-SEES [CR][LF] + file raw [LF][LF]: the conversion is the
#    second hook's file write on Windows.
# All loops are bounded; every stage logs BEFORE/AFTER with wall-clock
# times, so a stuck stage is still named by its BEFORE line.

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so
# this process runs the tip's Perl modules exactly like the CLI
# subprocesses already do (same drift fix as t/05, commit cbf9855d).
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Developer::Dashboard::PerlEnv;
use Encode qw(decode);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use Time::HiRes qw(time);

use lib File::Spec->catdir( $FindBin::Bin, 'lib' );
use Local::NativeCommand qw(run_shell_command);

my $repo = getcwd();
my @built_perl_libs = grep { -d $_ } map { File::Spec->catdir( $repo, 'blib', $_ ) } qw(arch lib);
local $ENV{PERL5LIB} = join Developer::Dashboard::PerlEnv::path_separator(), grep { defined && $_ ne '' } ( @built_perl_libs, $ENV{PERL5LIB} || () );
local $ENV{DEVELOPER_DASHBOARD_BOOKMARKS};
local $ENV{DEVELOPER_DASHBOARD_CONFIGS};
local $ENV{DEVELOPER_DASHBOARD_CHECKERS};

my $perl      = $^X;
my $lib       = File::Spec->catdir( $repo, 'lib' );
my $dashboard = File::Spec->catfile( $repo, 'bin', 'd2' );

my $T0 = time();

sub _elapsed {
    return sprintf( '%.1fs', time() - $T0 );
}

sub _log {
    my ($msg) = @_;
    diag( '[' . _elapsed() . "] $msg" );
}

sub _show {
    my ($value) = @_;
    return 'undef' if !defined $value;
    my $shown = $value;
    $shown =~ s/\r/[CR]/g;
    $shown =~ s/\n/[LF]/g;
    $shown =~ s/\t/[TAB]/g;
    return "'$shown' (length " . length($value) . ')';
}

sub _run_logged {
    my ( $label, $cmd ) = @_;
    _log("BEFORE $label: $cmd");
    my $start = time();
    my ( $stdout, $stderr, $exit_code ) = run_shell_command($cmd);
    _log( sprintf( 'AFTER %s: exit=%d in %.1fs', $label, $exit_code, time() - $start ) );
    _log("$label stdout: $stdout") if defined $stdout && $stdout ne '';
    _log("$label stderr: $stderr") if defined $stderr && $stderr ne '';
    return ( decode( 'UTF-8', $stdout . $stderr ), $exit_code );
}

sub _slurp {
    my ($path) = @_;
    return undef if !-f $path;
    open my $fh, '<', $path or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub _slurp_raw {
    my ($path) = @_;
    return undef if !-f $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

{
    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT};
    delete $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT};

    my $runtime_jq = File::Spec->catfile( $home, '.developer-dashboard', 'cli', 'dd', 'jq' );
    my ( $init_out, $init_rc ) = _run_logged( 'init', "$perl -I'$lib' '$dashboard' init" );
    like( $init_out, qr/runtime_root/, 'micro d2 init works' );
    ok( -f $runtime_jq, 'micro d2 init seeds the jq helper' );

    my $jq_hook_root = File::Spec->catdir( $home, '.developer-dashboard', 'cli', 'jq.d' );
    make_path($jq_hook_root);

    my $jq_hook_one = File::Spec->catfile( $jq_hook_root, '00-first.pl' );
    open my $jq_hook_one_fh, '>', $jq_hook_one or die "Unable to write $jq_hook_one: $!";
    print {$jq_hook_one_fh} <<'PL';
#!/usr/bin/env perl
print "hook-one\n";
warn "hook-one-err\n";
PL
    close $jq_hook_one_fh;
    chmod 0755, $jq_hook_one or die "Unable to chmod $jq_hook_one: $!";

    my $jq_hook_result = File::Spec->catfile( $home, 'jq-hook-result.txt' );
    my $jq_hook_two = File::Spec->catfile( $jq_hook_root, '01-second.pl' );
    open my $jq_hook_two_fh, '>', $jq_hook_two or die "Unable to write $jq_hook_two: $!";
    print {$jq_hook_two_fh} <<"PL";
#!/usr/bin/env perl
use strict;
use warnings;
use lib '$repo/lib';
use Developer::Dashboard::Runtime::Result;
my \$v = Developer::Dashboard::Runtime::Result::stdout('00-first.pl');
my \$shown = defined \$v ? \$v : '';
\$shown =~ s/\\r/[CR]/g;
\$shown =~ s/\\n/[LF]/g;
print "HOOK2-SEES: '\$shown' (len " . ( defined \$v ? length(\$v) : -1 ) . ")\\n";
open my \$fh, '>', '$jq_hook_result' or die \$!;
print {\$fh} \$v;
close \$fh;
print "hook-two\\n";
warn "hook-two-err\\n";
PL
    close $jq_hook_two_fh;
    chmod 0755, $jq_hook_two or die "Unable to chmod $jq_hook_two: $!";

    my ( $jq_out, $jq_rc ) = _run_logged( 'jq-hooked', qq{printf '{"alpha":{"beta":2}}' | $perl -I'$lib' '$dashboard' jq alpha.beta} );
    is( $jq_rc, 0, 'micro d2 jq succeeds when command hook files exist' );
    my ($hook2_sees) = $jq_out =~ /HOOK2-SEES: '([^']*)' \(len (-?\d+)\)/;
    my ($hook2_len) = $jq_out =~ /HOOK2-SEES: '[^']*' \(len (-?\d+)\)/;
    _log( 'HOOK2-SEES line: ' . ( defined $hook2_sees ? "'$hook2_sees' (len $hook2_len)" : 'MISSING - the second hook never printed its dump' ) );
    ok( defined $hook2_sees, 'micro second hook reports the RESULT bytes it sees' );

    my $file_slurp = _slurp($jq_hook_result);
    _log( 'result file (slurp, as t/05 reads it): ' . _show($file_slurp) );
    my $file_raw = _slurp_raw($jq_hook_result);
    _log( 'result file (raw bytes): ' . _show($file_raw) );
    is( $file_slurp, "hook-one\n", 'micro second hook file holds exactly one trailing newline' );
}

done_testing();
