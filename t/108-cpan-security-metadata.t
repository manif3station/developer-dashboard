use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);
use File::Spec;
use FindBin qw($RealBin);
use Test::More;

my $ROOT = abs_path( File::Spec->catdir( $RealBin, File::Spec->updir ) );
my $makefile = _slurp('Makefile.PL');
my $cpanfile = _slurp('cpanfile');
my $dist     = _slurp('dist.ini');
my $audit    = _slurp( File::Spec->catfile( 'script', 'cpan-audit-project' ) );
my $exclude  = _slurp('cpan-audit-exclusions.txt');
my $workflow = _slurp( File::Spec->catfile( '.github', 'workflows', 'test.yml' ) );
my $installer = _slurp('install.sh');
my $main_pod = _slurp( File::Spec->catfile( 'lib', 'Developer', 'Dashboard.pm' ) );
my $blank_env = _slurp( File::Spec->catfile( 'integration', 'blank-env', 'Dockerfile' ) );

my %secure_minimum = (
    'Archive::Tar'           => '3.10',
    'Archive::Zip'           => '1.61',
    'Capture::Tiny'          => '0.24',
    'Compress::Raw::Zlib'    => '2.220',
    'Cpanel::JSON::XS'       => '4.41',
    'Dancer2'                => '0.206000',
    'Digest::MD5'            => '2.25',
    'Digest::SHA'            => '5.96',
    'HTML::Parser'           => '3.84',
    'HTTP::Date'             => '6.08',
    'HTTP::Tiny'             => '0.095',
    'IO::Compress::Gzip'     => '2.220',
    'IO::Uncompress::Gunzip' => '2.220',
    'JSON::XS'               => '4.04',
    'LWP::Protocol::https'   => '6.07',
    'LWP::UserAgent'         => '6.83',
    'Plack'                  => '1.0054',
    'Socket'                 => '2.041',
    'Starman'                => '0.4018',
    'Storable'               => '3.41',
    'Template'               => '3.103',
    'XML::Parser'            => '2.48',
    'YAML'                   => '1.28',
    'YAML::XS'               => '0.903.0',
);

like( $makefile, qr/MIN_PERL_VERSION\s*=>\s*'5\.038'/, 'Makefile.PL keeps the installable Perl 5.38 floor (interpreter advisories are environmental; dependency pins carry the CVE gate)' );
like( $cpanfile, qr/requires\s+'perl'\s*,\s*'5\.038'\s*;/, 'cpanfile keeps the installable Perl 5.38 floor' );
like( $dist, qr/^perl = 5\.038$/m, 'dist.ini keeps the installable Perl 5.38 floor' );

for my $module ( sort keys %secure_minimum ) {
    my $version = $secure_minimum{$module};
    like(
        $makefile,
        qr/['"]\Q$module\E['"]\s*=>\s*['"]\Q$version\E['"]/,
        "Makefile.PL pins $module at its secure minimum $version",
    );
    like(
        $cpanfile,
        qr/requires\s+['"]\Q$module\E['"]\s*,\s*['"]\Q$version\E['"]\s*;/,
        "cpanfile pins $module at its secure minimum $version",
    );
    like(
        $dist,
        qr/^\Q$module\E = \Q$version\E$/m,
        "dist.ini pins $module at its secure minimum $version",
    );
}

like( $audit, qr/^#!\/usr\/bin\/env bash$/m, 'audit gate has a bash shebang so set -o pipefail is recognized' );
like( $audit, qr/BASH_VERSION/, 'audit gate detects being run under a non-bash shell and exits 2' );

like( $audit, qr/set -euo pipefail/, 'audit gate fails closed on command errors' );
unlike( $audit, qr/--exit-zero/, 'audit gate never suppresses an advisory exit status' );
like( $audit, qr/cpan-audit installed/, 'audit gate scans installed distributions rather than host-contaminated metadata ranges' );
like( $audit, qr/--perl/, 'audit gate includes the isolated Perl runtime in its scan' );
like( $audit, qr/--exclude-file/, 'audit gate consumes the reviewed advisory disposition file' );
like( $audit, qr/Plack::Middleware::XSendfile/, 'audit gate guards against Plack XSendfile use before applying its disposition' );
like( $audit, qr/File::Temp.*safe_level/s, 'audit gate guards activation of the vulnerable File::Temp safety checks before applying its disposition' );
like( $audit, qr/\$repo_root\/app\.psgi/, 'audit gate scans the shipped PSGI activation surface' );

my @exclusions = grep { /\S/ && !/^\s*#/ } split /\n/, $exclude;
is_deeply(
    \@exclusions,
    [ qw(CPANSA-Plack-2026-7381 CPANSA-File-Temp-2011-4116) ],
    'only exact reviewed no-fixed advisory IDs are excluded',
);

like( $workflow, qr/perl-version:\s*'5\.44'/, 'CI exercises the hardened Perl baseline' );
like( $workflow, qr/cpanm\s+--installdeps\s+--notest\s+-L\s+local\s+\./, 'CI installs project dependencies into an isolated local root' );
like( $workflow, qr/script\/cpan-audit-project\s+local\/lib\/perl5/, 'CI executes the project audit gate against that isolated root' );
like( $workflow, qr/script\/cpan-audit-declared-chain\s+local\/lib\/perl5/, 'CI audits the transitive closure of the declared chain, not only the modules cpanfile names' );
like( $workflow, qr/echo\s+"\$GITHUB_WORKSPACE\/audit-local\/bin"\s+>>\s+"\$GITHUB_PATH"/, 'CI adds cpan-audit to the preserved runner PATH' );
unlike( $workflow, qr/PATH:\s*\$\{\{\s*env\.PATH\s*\}\}/, 'CI does not replace the runner PATH with an unavailable env context value' );
like( $installer, qr/PERLBREW_PERL="\$\{DD_INSTALL_PERLBREW_PERL:-perl-5\.44\.0\}"/, 'bootstrap fallback builds the hardened Perl 5.44 runtime' );
like( $installer, qr/MIN_PERL_VERSION='5\.038'/, 'bootstrap accepts host Perl releases from 5.38 and only builds the perlbrew fallback below that floor' );
like( $main_pod, qr/older than the required\s+C<5\.44>/, 'installation documentation names the hardened Perl baseline' );
like( $main_pod, qr/perlbrew --notest install perl-5\.44\.0/, 'installation documentation names the hardened rescue Perl' );
like( $blank_env, qr/\AFROM\s+perl:5\.44-bookworm\@sha256:[0-9a-f]{64}\b/, 'blank-environment E2E uses a digest-pinned hardened Perl image' );

ok( -f File::Spec->catfile( $ROOT, 't', 'features', 'dd392-cve-remediation.feature' ), 'BDD feature for DD-392 is tracked' );

# Executable proof: the gate refuses to run under a non-bash shell.
my $gate = File::Spec->catfile( $ROOT, 'script', 'cpan-audit-project' );
my $sh_rc = 0;
{
    local $ENV{PATH} = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    local $ENV{PERL5LIB} = $ENV{PERL5LIB} // '';
    my $sh_out = `sh $gate /tmp/nonexistent-root 2>&1`;
    $sh_rc = ${^CHILD_ERROR_NATIVE} >> 8;
    isnt( $sh_rc, 0, 'audit gate refuses to execute under sh (no silent pipefail)' );
    like( $sh_out, qr/bash/, 'audit gate tells the caller it must run under bash' );
}

# Executable proof: the gate returns 2 on usage errors and never succeeds.
{
    my $bogus_rc = 0;
    my $bogus_out = `bash $gate /tmp/nonexistent-root 2>&1`;
    $bogus_rc = ${^CHILD_ERROR_NATIVE} >> 8;
    is( $bogus_rc, 2, 'audit gate exits 2 when the isolated root is missing' );
    like( $bogus_out, qr/Usage:/, 'audit gate prints a usage diagnostic on missing root' );
}

# Executable proof: quoted and bareword Plack builder activation invalidate the XSendfile disposition.
for my $activation ( q{enable 'XSendfile'}, q{enable XSendfile} ) {
    my $fixture = File::Spec->catfile( $ROOT, 'lib', 'T107XSendfileFixture.pm' );
    my $scan_root = File::Spec->catdir( $ROOT, '.t107-guard-root' );
    make_path($scan_root);
    _write_file( $fixture, "use Plack::Builder;\nbuilder { $activation; sub { [ 200, [], [] ] } };\n" );
    my ( $rc, $out ) = _run_gate($scan_root);
    isnt( $rc, 0, "audit gate rejects Plack builder activation: $activation" );
    like( $out, qr/CPANSA-Plack-2026-7381 exclusion invalid/, "$activation reports its exact advisory disposition" );
    unlink $fixture or die "unlink $fixture: $!";
    remove_tree($scan_root);
}

# Executable proof: every public constructor at MEDIUM/HIGH invalidates the File::Temp disposition.
for my $case (
    [ MEDIUM => 'tempfile' ],
    [ MEDIUM => 'tempdir' ],
    [ HIGH   => 'tempfile' ],
    [ HIGH   => 'tempdir' ],
) {
    my ( $level, $constructor ) = @$case;
    my $fixture = File::Spec->catfile( $ROOT, 'lib', 'T107FileTempFixture.pm' );
    my $scan_root = File::Spec->catdir( $ROOT, '.t107-guard-root' );
    make_path($scan_root);
    _write_file(
        $fixture,
        "use File::Temp qw($constructor);\n"
          . "File::Temp->safe_level( File::Temp::$level );\n"
          . "$constructor();\n",
    );
    my ( $rc, $out ) = _run_gate($scan_root);
    isnt( $rc, 0, "audit gate rejects File::Temp $level $constructor activation" );
    like( $out, qr/CPANSA-File-Temp-2011-4116 exclusion invalid/, "$level $constructor reports its exact advisory disposition" );
    unlink $fixture or die "unlink $fixture: $!";
    remove_tree($scan_root);
}

# Executable proof: a real vulnerable installed module remains fatal when it is
# not excluded. One case per module that %secure_minimum floors purely because
# of an advisory, so the declared pin is backed by a demonstrated detection at
# the exact affected version rather than by a version string in three files.
for my $case (
    {
        module   => 'HTTP::Tiny',
        file     => [ 'HTTP', 'Tiny.pm' ],
        dist     => 'HTTP-Tiny',
        version  => '0.086',
        advisory => 'CPANSA-HTTP-Tiny-2026-7017',
    },
    {
        module   => 'HTTP::Date',
        file     => [ 'HTTP', 'Date.pm' ],
        dist     => 'HTTP-Date',
        version  => '6.06',
        advisory => 'CPANSA-HTTP-Date-2026-14741',
    },
    {
        module   => 'HTML::Parser',
        file     => [ 'HTML', 'Parser.pm' ],
        dist     => 'HTML-Parser',
        version  => '3.83',
        advisory => 'CPANSA-HTML-Parser-2026-8829',
    },
    {
        module   => 'Cpanel::JSON::XS',
        file     => [ 'Cpanel', 'JSON', 'XS.pm' ],
        dist     => 'Cpanel-JSON-XS',
        version  => '4.38',
        advisory => 'CPANSA-Cpanel-JSON-XS-2026-9334',
    },
    {
        module   => 'YAML',
        file     => ['YAML.pm'],
        dist     => 'YAML',
        version  => '0.86',
        advisory => 'CPANSA-YAML-2019-01',
    },
) {
    my $bad = File::Spec->catdir( $ROOT, '.t107-bad-root' );
    my @file = @{ $case->{file} };
    my $leaf = pop @file;
    my $fixture = File::Spec->catfile( $bad, @file, $leaf );
    make_path( File::Spec->catdir( $bad, @file ) );
    _write_file( $fixture, "package $case->{module};\nour \$VERSION = '$case->{version}';\n1;\n" );
    my ( $bad_rc, $bad_out ) = _run_gate($bad);
    isnt( $bad_rc, 0, "audit gate is non-zero for a real vulnerable $case->{dist} fixture" );
    like(
        $bad_out,
        qr/\Q$case->{dist}\E.*\Q$case->{version}\E.*advisor/is,
        "audit output attributes failure to vulnerable $case->{dist} $case->{version}",
    );
    like( $bad_out, qr/\Q$case->{advisory}\E/, "vulnerable $case->{dist} fixture reports the expected advisory ID" );
    remove_tree($bad);
}

done_testing;

sub _slurp {
    my ($relative) = @_;
    my $path = File::Spec->catfile( $ROOT, split m{/}, $relative );
    return '' if !-f $path;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh or die "Unable to close $path: $!";
    return defined $content ? $content : '';
}

sub _run_gate {
    my ($root) = @_;
    local $ENV{PATH} = join ':',
        File::Spec->catdir( $ENV{HOME}, 'perl5', 'perlbrew', 'perls', 'perl-5.44.0', 'bin' ),
        File::Spec->catdir( $ENV{HOME}, 'perl5', 'bin' ),
        qw(/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin);
    local $ENV{PERL5LIB} = File::Spec->catdir( $ENV{HOME}, 'perl5', 'perlbrew', 'perls', 'perl-5.44.0', 'local', 'lib', 'perl5' );
    my $out = `bash $gate $root 2>&1`;
    my $rc = ${^CHILD_ERROR_NATIVE} >> 8;
    return ( $rc, $out );
}

sub _write_file {
    my ( $path, $content ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $content;
    close $fh or die "Unable to close $path: $!";
}

__END__

=head1 NAME

t/108-cpan-security-metadata.t - verify the DD-392 fail-closed CPAN vulnerability policy

=head1 PURPOSE

Verify synchronized secure dependency minimums, the hardened Perl baseline,
exact advisory exclusions, source non-applicability guards, and executable
fail-closed behavior for the project CPAN audit gate.

=head1 WHY IT EXISTS

Dependency metadata is copied across Makefile.PL, cpanfile, dist.ini, the
installer, and CI. A scanner-only test can miss drift or a gate that suppresses
its own exit status, so this acceptance test checks both declarations and real
shell execution.

=head1 WHEN TO USE

Run it whenever CPAN prerequisites, Perl bootstrap policy, audit exclusions, or
CI dependency installation changes.

=head1 HOW TO USE

Run C<prove -lv t/108-cpan-security-metadata.t> while iterating. Then run the
entire suite and the isolated C<script/cpan-audit-project> inventory before
advancing the CVE and TEST gates.

=head1 WHAT USES IT

The DD-392 acceptance gate, the normal C<prove -lr t> suite, CI, and release
verification use this test to keep security metadata synchronized.

=head1 EXAMPLES

Example 1:

  prove -lv t/108-cpan-security-metadata.t

Example 2:

  script/cpan-audit-project local/lib/perl5

=head1 AUTHOR

Developer Dashboard Contributors
