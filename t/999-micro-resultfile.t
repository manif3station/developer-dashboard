use strict;
use warnings;
use utf8;

# Micro-repro v9 for Jenkins build #114: v8 (build #113) named the real
# cause - chmod 0600 on a filehandle dies on Strawberry Perl ("The
# fchmod function is unimplemented"), so _open_channel_file died before
# the named-path branch ever ran. The loop-branch fix (chmod by path on
# Windows) is cherry-picked onto this probe branch, and v9 also fixes
# v8's two micro bugs: (1) stage-a-child.pl declared `my $fh` inside
# the `if` condition, so <$fh>/close $fh failed to compile (test 3);
# (2) the ENTRY_OK diag lines were not KEY=value, so _slurp_diag filed
# them under "ENTRY_OK stderr_len" and $probe->{ENTRY_OK} came back
# undef (tests 8/11). t/05 tests 824-828 fail
# on Windows only, byte-identically in builds #111/#112, even though build
# #112 ran with commit 23175f66 (Result.pm: $CHANNEL_USE_NAMED_PATH
# also true on MSWin32, so _open_channel_file should hand children the
# named tempfile path instead of /proc/self/fd/N). The probe hook and
# the final command print nothing; only the 32 streamed S chars from
# the oversized hook are captured. Two hypotheses:
#   H1: the fix never loads where it matters - a hook child loads
#       Result.pm from the node's stale blib (which still returns
#       /proc/self/fd/N), not the fresh checkout lib.
#   H2: the fix loads but the named tempfile still cannot be opened by
#       a child while the parent holds it (Windows file sharing, or
#       File::Temp UNLINK deleting the name under the child).
# Stage A isolates H2 without d2: the test process (fresh lib) calls
# set_current with an oversized payload, then a plain child perl opens
# $ENV{RESULT_FILE} and reports what it read. Stage B runs the REAL d2
# chain with t/05-identical fixtures (extensionless shebang scripts, NO
# `use lib` in the hooks) whose probe and final command dump diagnostics
# to files: which Result.pm they loaded ($INC), the live
# $CHANNEL_USE_NAMED_PATH, the RESULT_FILE value they saw, whether the
# path exists and opens, and the entry() result or the exact die text.
# All loops are bounded; every stage logs BEFORE/AFTER with wall-clock
# times, so a stuck stage is still named by its BEFORE line. Diagnostic
# output is printed with diag() BEFORE any ok() that could fail, so the
# fail-safe killing prove on the first failure still leaves the full
# evidence in the console.

use FindBin;
use File::Spec;

# Load the fresh checkout lib first, ahead of the node's blib build, so
# this process runs the tip's Perl modules exactly like the CLI
# subprocesses already do (same drift fix as t/05, commit cbf9855d).
use lib File::Spec->catdir( $FindBin::Bin, '..', 'lib' );

use Cwd qw(getcwd);
use Developer::Dashboard::PerlEnv;
use Developer::Dashboard::Runtime::Result ();
use Encode qw(decode);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::XS qw(encode_json);
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
my $IS_WINDOWS = $^O eq 'MSWin32';

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

# Like _run_logged, but the child streams a huge payload (the oversized
# hook stderr), so log only head/tail of each stream, never the whole
# thing. Returns decoded stdout, decoded stderr, exit code.
sub _run_logged_trunc {
    my ( $label, $cmd ) = @_;
    _log("BEFORE $label: $cmd");
    my $start = time();
    my ( $stdout, $stderr, $exit_code ) = run_shell_command($cmd);
    $stdout = decode( 'UTF-8', $stdout // '' );
    $stderr = decode( 'UTF-8', $stderr // '' );
    _log( sprintf( 'AFTER %s: exit=%d in %.1fs', $label, $exit_code, time() - $start ) );
    _log("$label stdout len=" . length($stdout) . ' head=' . _show( substr( $stdout, 0, 400 ) ));
    _log("$label stdout tail=" . _show( substr( $stdout, -400 ) )) if length($stdout) > 400;
    _log("$label stderr len=" . length($stderr) . ' head=' . _show( substr( $stderr, 0, 400 ) ));
    _log("$label stderr tail=" . _show( substr( $stderr, -400 ) )) if length($stderr) > 400;
    return ( $stdout, $stderr, $exit_code );
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

# Parses a diag file of KEY=value lines (values already escaped, no
# embedded newlines) into a hash reference. Returns undef when missing.
sub _slurp_diag {
    my ($path) = @_;
    my $content = _slurp($path);
    return undef if !defined $content;
    my %diag;
    for my $line ( split /\n/, $content ) {
        next if $line eq '';
        my ( $key, $value ) = split /=/, $line, 2;
        $diag{$key} = defined $value ? $value : '';
    }
    return \%diag;
}

my $E_LEN = 200_000;
my $workdir = tempdir( CLEANUP => 1 );

# ---- Stage A: in-process file channel + plain child read (H2) ----
{
    _log('STAGE A: set_current with an oversized payload, child reads RESULT_FILE');
    my $named = $Developer::Dashboard::Runtime::Result::CHANNEL_USE_NAMED_PATH;
    _log("CHANNEL_USE_NAMED_PATH in this process (fresh lib) = $named");
    my $data = { '01-big' => { stdout => 'S' x 32, stderr => 'E' x $E_LEN } };
    my $expect_json = encode_json($data);
    _log( 'expected payload JSON length=' . length($expect_json) );
    my $mode = Developer::Dashboard::Runtime::Result::set_current($data);
    _log("set_current mode=$mode");
    my $rf = $ENV{RESULT_FILE} // '';
    _log( 'RESULT_FILE=' . _show($rf) );
    _log( 'RESULT_FILE exists=' . ( -e $rf ? 1 : 0 ) . ' size=' . ( -s $rf // -1 ) );

    my $child = File::Spec->catfile( $workdir, 'stage-a-child.pl' );
    open my $child_fh, '>', $child or die "Unable to write $child: $!";
    print {$child_fh} <<'PL';
#!/usr/bin/env perl
use strict;
use warnings;
my $rf = $ENV{RESULT_FILE} // '';
if ( $rf eq '' ) {
    print "READ-FAIL: RESULT_FILE is empty\n";
    exit 0;
}
my $fh;
if ( !open $fh, '<:raw', $rf ) {
    print "READ-FAIL: open $rf: $!\n";
    exit 0;
}
local $/;
my $content = <$fh>;
close $fh;
print "READ-OK len=" . length( defined $content ? $content : '' ) . "\n";
PL
    close $child_fh;
    chmod 0755, $child or die "Unable to chmod $child: $!";

    my ( $child_out, $child_rc ) = _run_logged( 'stage-a-child', "$perl $child" );
    my ($child_len) = $child_out =~ /READ-OK len=(\d+)/;
    _log( 'stage-a child read length=' . ( defined $child_len ? $child_len : 'NONE - ' . _show($child_out) ) );

    ok( $mode eq 'file', 'stage A: oversized payload uses the file channel' );
    if ($IS_WINDOWS) {
        ok( $rf ne '' && $rf !~ m{/proc/self/fd} && $rf !~ m{/dev/fd/},
            'stage A: RESULT_FILE is a named tempfile path on Windows' );
    }
    else {
        ok( $rf ne '', 'stage A: RESULT_FILE is set' );
    }
    ok( defined $child_len && $child_len == length($expect_json),
        'stage A: a plain child process reads the full RESULT_FILE payload' );

    Developer::Dashboard::Runtime::Result::clear_current();
    delete $ENV{RESULT};
    delete $ENV{RESULT_FILE};
}

# ---- Stage B: the real d2 chain, t/05-identical fixtures (H1) ----
{
    my $home = tempdir( CLEANUP => 1 );
    local $ENV{HOME} = $home;
    local $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT};
    delete $ENV{DEVELOPER_DASHBOARD_ENTRYPOINT};

    my ( $init_out, $init_rc ) = _run_logged( 'init', "$perl -I'$lib' '$dashboard' init" );
    ok( $init_rc == 0, 'stage B: micro d2 init works' );

    my $probe_diag = File::Spec->catfile( $home, 'probe-diag.txt' );
    my $final_diag = File::Spec->catfile( $home, 'final-diag.txt' );

    my $cmd_path = File::Spec->catfile( $home, '.developer-dashboard', 'cli', 'micro-resultfile' );
    open my $cmd_fh, '>', $cmd_path or die "Unable to write $cmd_path: $!";
    print {$cmd_fh} <<"PL";
#!/usr/bin/env perl
use strict;
use warnings;
use IO::Handle ();
sub _esc { my (\$v) = \@_; \$v = '' if !defined \$v; \$v =~ s/\\r/[CR]/g; \$v =~ s/\\n/[LF]/g; return \$v; }
open my \$dfh, '>', '$final_diag' or die "diag open: \$!";
\$dfh->autoflush(1);
print {\$dfh} "SPAWNED\\n";
print {\$dfh} "RESULT=" . (defined \$ENV{RESULT} ? 'len ' . length(\$ENV{RESULT}) : 'undef') . "\\n";
print {\$dfh} "RESULT_FILE=" . _esc(\$ENV{RESULT_FILE}) . "\\n";
my \$loaded = eval { require Developer::Dashboard::Runtime::Result; 1 };
print {\$dfh} "REQUIRE=" . (\$loaded ? 'ok' : 'FAIL: ' . _esc(\$@)) . "\\n";
if (\$loaded) {
    print {\$dfh} "INC=" . _esc(\$INC{'Developer/Dashboard/Runtime/Result.pm'}) . "\\n";
    print {\$dfh} "NAMED_PATH=" . \$Developer::Dashboard::Runtime::Result::CHANNEL_USE_NAMED_PATH . "\\n";
    my \$rf = \$ENV{RESULT_FILE} // '';
    print {\$dfh} "RF_EXISTS=" . (-e \$rf ? 1 : 0) . " RF_SIZE=" . (-s \$rf // -1) . "\\n";
    my \$entry;
    if (eval { \$entry = Developer::Dashboard::Runtime::Result::current(); 1 }) {
        my \$e = \$entry->{'01-big'} || {};
        print {\$dfh} "ENTRY_OK=stdout_len=" . length(\$e->{stdout} // '') . " stderr_len=" . length(\$e->{stderr} // '') . "\\n";
        print "stdout=", length(\$e->{stdout} // ''), "\\n";
        print "stderr=", length(\$e->{stderr} // ''), "\\n";
        print "result_file=", ((\$ENV{RESULT_FILE} || '') ne '' ? 1 : 0), "\\n";
    }
    else {
        print {\$dfh} "ENTRY_FAIL: " . _esc(\$@) . "\\n";
        print "final-FAILED\\n";
    }
}
else {
    print "final-FAILED\\n";
}
close \$dfh;
PL
    close $cmd_fh;
    chmod 0755, $cmd_path or die "Unable to chmod $cmd_path: $!";

    my $hook_root = File::Spec->catdir( $home, '.developer-dashboard', 'cli', 'micro-resultfile.d' );
    make_path($hook_root);

    my $hook_big = File::Spec->catfile( $hook_root, '01-big' );
    open my $hook_big_fh, '>', $hook_big or die "Unable to write $hook_big: $!";
    print {$hook_big_fh} <<'PL';
#!/usr/bin/env perl
use strict;
use warnings;
print 'S' x 32;
print STDERR 'E' x 200000;
PL
    close $hook_big_fh;
    chmod 0755, $hook_big or die "Unable to chmod $hook_big: $!";

    my $hook_probe = File::Spec->catfile( $hook_root, '02-probe' );
    open my $hook_probe_fh, '>', $hook_probe or die "Unable to write $hook_probe: $!";
    print {$hook_probe_fh} <<"PL";
#!/usr/bin/env perl
use strict;
use warnings;
use IO::Handle ();
sub _esc { my (\$v) = \@_; \$v = '' if !defined \$v; \$v =~ s/\\r/[CR]/g; \$v =~ s/\\n/[LF]/g; return \$v; }
open my \$dfh, '>', '$probe_diag' or die "diag open: \$!";
\$dfh->autoflush(1);
print {\$dfh} "SPAWNED\\n";
print {\$dfh} "RESULT=" . (defined \$ENV{RESULT} ? 'len ' . length(\$ENV{RESULT}) : 'undef') . "\\n";
print {\$dfh} "RESULT_FILE=" . _esc(\$ENV{RESULT_FILE}) . "\\n";
my \$loaded = eval { require Developer::Dashboard::Runtime::Result; 1 };
print {\$dfh} "REQUIRE=" . (\$loaded ? 'ok' : 'FAIL: ' . _esc(\$@)) . "\\n";
if (\$loaded) {
    print {\$dfh} "INC=" . _esc(\$INC{'Developer/Dashboard/Runtime/Result.pm'}) . "\\n";
    print {\$dfh} "NAMED_PATH=" . \$Developer::Dashboard::Runtime::Result::CHANNEL_USE_NAMED_PATH . "\\n";
    my \$rf = \$ENV{RESULT_FILE} // '';
    print {\$dfh} "RF_EXISTS=" . (-e \$rf ? 1 : 0) . " RF_SIZE=" . (-s \$rf // -1) . "\\n";
    my \$entry;
    if (eval { \$entry = Developer::Dashboard::Runtime::Result::entry('01-big'); 1 }) {
        print {\$dfh} "ENTRY_OK=stderr_len=" . length(\$entry->{stderr} // '') . "\\n";
        print 'probe-stderr=', length(\$entry->{stderr} // ''), "\\n";
    }
    else {
        print {\$dfh} "ENTRY_FAIL: " . _esc(\$@) . "\\n";
        print "probe-FAILED\\n";
    }
}
else {
    print "probe-FAILED\\n";
}
close \$dfh;
PL
    close $hook_probe_fh;
    chmod 0755, $hook_probe or die "Unable to chmod $hook_probe: $!";

    my ( $d2_out, $d2_err, $d2_rc ) = _run_logged_trunc( 'd2-micro-resultfile', "$perl -I'$lib' '$dashboard' micro-resultfile" );

    my $probe = _slurp_diag($probe_diag);
    my $final = _slurp_diag($final_diag);
    _log( 'probe diag: ' . ( defined $probe ? join( ' | ', map { "$_=$probe->{$_}" } sort keys %{$probe} ) : 'MISSING - the probe hook never wrote its diag file' ) );
    _log( 'final diag: ' . ( defined $final ? join( ' | ', map { "$_=$final->{$_}" } sort keys %{$final} ) : 'MISSING - the final command never wrote its diag file' ) );

    ok( defined $probe, 'stage B: the probe hook ran and wrote diagnostics' );
    ok( defined $probe && ( $probe->{REQUIRE} // '' ) eq 'ok',
        'stage B: the probe hook loads Result.pm' );
    if ($IS_WINDOWS) {
        ok( defined $probe && ( $probe->{RESULT_FILE} // '' ) !~ m{/proc/self/fd} && ( $probe->{RESULT_FILE} // '' ) !~ m{/dev/fd/},
            'stage B: the probe hook sees a named tempfile RESULT_FILE on Windows' );
    }
    else {
        ok( defined $probe && ( $probe->{RESULT_FILE} // '' ) ne '',
            'stage B: the probe hook sees RESULT_FILE' );
    }
    ok( defined $probe && ( $probe->{ENTRY_OK} // '' ) =~ /stderr_len=$E_LEN\b/,
        'stage B: the probe hook reads the oversized RESULT entry' );
    ok( defined $final, 'stage B: the final command ran and wrote diagnostics' );
    ok( defined $final && ( $final->{REQUIRE} // '' ) eq 'ok',
        'stage B: the final command loads Result.pm' );
    ok( defined $final && ( $final->{ENTRY_OK} // '' ) =~ /stdout_len=32\b/ && ( $final->{ENTRY_OK} // '' ) =~ /stderr_len=$E_LEN\b/,
        'stage B: the final command reads the oversized RESULT entry' );
    is( $d2_rc, 0, 'stage B: d2 micro-resultfile exits 0' );
    like( $d2_out, qr/probe-stderr=$E_LEN\n/, 'stage B: probe output reaches the test' );
}

done_testing();
