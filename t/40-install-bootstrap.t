#!/usr/bin/env perl

use strict;
use warnings;

use Capture::Tiny qw(capture);
use Cwd ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use Test::More;

use lib File::Spec->catdir( $RealBin, File::Spec->updir, 'lib' );
use Developer::Dashboard::InternalCLI ();

# On Windows the install.sh scenarios run through Git for Windows' sh (see
# _posix_shell_binary). Two spelling differences are levelled here so every
# check below compares the same strings on every platform:
# 1. Paths are spelled with "/" throughout this file (temp directories and
#    File::Spec joins), exactly as install.sh builds "$HOME/.bashrc";
#    Windows accepts either separator, and a backslash would be eaten by
#    the shell stubs and their sed replacements.
# 2. Text that comes back from the shell names the temp directory the
#    shell's way (/c/Users/... or /tmp/...); it is turned back into the
#    native spelling that File::Temp handed out.
my ( $TEMP_NATIVE, $TEMP_MSYS );
if ( $^O eq 'MSWin32' ) {
    ( $TEMP_NATIVE = File::Spec->tmpdir ) =~ tr{\\}{/};
    $TEMP_MSYS = _msys_path($TEMP_NATIVE);
    no warnings qw(redefine prototype);
    *main::tempdir = sub { ( my $dir = File::Temp::tempdir(@_) ) =~ tr{\\}{/}; return $dir };
    *File::Spec::Win32::catfile = sub { shift; return join '/', @_ };
    *File::Spec::Win32::catdir  = sub { shift; return join '/', @_ };
    my $capture = \&Capture::Tiny::capture;
    *main::capture = sub (&;@) {
        my @result = $capture->(@_);
        $result[$_] = _native_spelling( $result[$_] ) for 0, 1;
        return @result;
    };
}

my $root = File::Spec->catdir( $RealBin, File::Spec->updir );
my $install_sh = File::Spec->catfile( $root, 'install.sh' );
# The same script as the POSIX shell is asked to run it (Git for Windows'
# sh on Windows wants /c/dir, not C:\dir).
my $install_sh_for_sh = _msys_path($install_sh);
my $install_ps = File::Spec->catfile( $root, 'install.ps1' );
my $aptfile    = File::Spec->catfile( $root, 'aptfile' );
my $apkfile    = File::Spec->catfile( $root, 'apkfile' );
my $dnfile     = File::Spec->catfile( $root, 'dnfile' );
my $brewfile   = File::Spec->catfile( $root, 'brewfile' );
my $default_bootstrap_repository = 'https://github.com/manif3station/developer-dashboard.git';
my $perlbrew_app_dist_url = 'https://cpan.metacpan.org/authors/id/G/GU/GUGOD/App-perlbrew-1.02.tar.gz';
my $perlbrew_app_dist_basename = 'App-perlbrew-1.02.tar.gz';
my $dashboard_entrypoint = _slurp( File::Spec->catfile( $root, 'bin', 'd2' ) );

ok( -f $install_sh, 'install.sh exists at the repo root' );
ok( -f $install_ps, 'install.ps1 exists at the repo root' );
ok( -f $aptfile, 'aptfile exists at the repo root' );
ok( -f $apkfile, 'apkfile exists at the repo root' );
ok( -f $dnfile, 'dnfile exists at the repo root' );
ok( -f $brewfile, 'brewfile exists at the repo root' );
like( _slurp(File::Spec->catfile( $root, 'Makefile.PL' )), qr/VERSION_FROM\s*=>\s*'lib\/Developer\/Dashboard\/Version\.pm'/, 'Makefile.PL uses lightweight filesystem version metadata so checkout installs work on Windows and XSLoader receives the actual distribution version' );
like( _slurp(File::Spec->catfile( $root, 'Makefile.PL' )), qr/use\s+File::ShareDir::Install\s+qw\(install_share\);/, 'Makefile.PL loads File::ShareDir::Install so packaged installs can refresh shipped helper assets under auto/share/dist' );
like( _slurp(File::Spec->catfile( $root, 'Makefile.PL' )), qr/install_share\s+dist\s*=>\s*'share';/, 'Makefile.PL explicitly installs the repo share tree so packaged helper assets stay in sync with the tarball' );
unlike( _slurp(File::Spec->catfile( $root, 'Makefile.PL' )), qr/package\s+MY;\s*use\s+File::ShareDir::Install\s+qw\(postamble\);/s, 'Makefile.PL does not import and redefine the File::ShareDir::Install postamble in package MY' );
like( _slurp(File::Spec->catfile( $root, 'Makefile.PL' )), qr/File::ShareDir::Install::postamble\(\s*\$self\s*\)/, 'Makefile.PL chains the share-dir installer postamble before its checkout bootstrap hook' );
like( _slurp(File::Spec->catfile( $root, 'Makefile.PL' )), qr/install\s+::\s*\n\t\$\(NOECHO\)\s+\$\(PERL\)\s+-e\s+"1;"/, 'Makefile.PL gives the Windows gmake install target an explicit no-op recipe so it does not synthesize install from install.sh' );
like( _slurp(File::Spec->catfile( $root, 'Makefile.PL' )), qr/pure_install\s+::\s+install-private-cli-tools/, 'Makefile.PL runs the private helper staging hook from pure_install instead of a recipe-less install target' );
like(
    $dashboard_entrypoint,
    qr/sub _builtin_helper_command/,
    'bin/d2 resolves built-in helpers through the command-aware switchboard helper dispatcher',
);
like(
    $dashboard_entrypoint,
    qr/is_windows\(\)\s*&&\s*Developer::Dashboard::InternalCLI::_helper_uses_dashboard_core\(\$helper\)/,
    'bin/d2 routes Windows core-backed built-ins through the shared _dashboard-core helper directly',
);
like(
    $dashboard_entrypoint,
    qr/Developer::Dashboard::InternalCLI::ensure_dashboard_core/,
    'bin/d2 stages the shared _dashboard-core helper before direct Windows built-in dispatch',
);
{
    my $makefile_text = _slurp( File::Spec->catfile( $root, 'Makefile.PL' ) );
    like(
        $makefile_text,
        qr/for my \$\$cmd \(qw\(([^)]*)\)\)/s,
        'Makefile.PL declares the checkout bootstrap helper seed list explicitly',
    );
    my ($helper_list) = $makefile_text =~ /for my \$\$cmd \(qw\(([^)]*)\)\)/s;
    my @seeded_helpers = split /\s+/, $helper_list || '';
    my @expected_helpers = ( '_dashboard-core', Developer::Dashboard::InternalCLI::helper_names() );
    is_deeply(
        \@seeded_helpers,
        \@expected_helpers,
        'Makefile.PL checkout bootstrap seeds the full current private helper set into the home runtime',
    );
}

{
    # Windows gmake runs the staging one-liner with no HOME in the process
    # environment and a perl whose getpwuid dies as unimplemented, so the
    # recipe must fall back to USERPROFILE exactly like bin/d2 does.
    my $makefile_text = _slurp( File::Spec->catfile( $root, 'Makefile.PL' ) );
    my ($staging_code) = $makefile_text =~ /install-private-cli-tools :\n\t\$\(NOECHO\) \$\(PERL\) -e '([^']+)'/;
    ok( defined $staging_code, 'Makefile.PL carries the single-quoted install-private-cli-tools staging one-liner' );
    $staging_code =~ s/\$\$/\$/g;
    my $windows_like_prelude = 'BEGIN { *CORE::GLOBAL::getpwuid = sub ($) { die "The getpwuid function is unimplemented" }; } ';
    my $profile_home = tempdir( CLEANUP => 1 );
    my ( $stdout, $stderr, $exit ) = capture {
        local %ENV = %ENV;
        delete $ENV{HOME};
        $ENV{USERPROFILE} = $profile_home;
        my $previous_dir = Cwd::getcwd();
        chdir $root or die "Unable to chdir to $root: $!";
        system( $^X, _perl_source_file( $windows_like_prelude . $staging_code ) );
        my $status = $?;
        chdir $previous_dir or die "Unable to chdir back to $previous_dir: $!";
        $status;
    };
    is( $exit >> 8, 0, 'the helper staging one-liner succeeds on a Windows-like host with no HOME and an unimplemented getpwuid' )
      or diag $stderr;
    is( $stderr, '', 'the helper staging one-liner stays warning-clean without HOME' );
    my $staged_core = File::Spec->catfile( $profile_home, '.developer-dashboard', 'cli', '_dashboard-core' );
    my $staged_upgrade = File::Spec->catfile( $profile_home, '.developer-dashboard', 'cli', 'upgrade' );
    ok( -f $staged_core, 'the staging one-liner resolves USERPROFILE as home and seeds _dashboard-core under it' );
    ok( -f $staged_upgrade, 'the staging one-liner seeds the new upgrade helper under the USERPROFILE home' );
}

{
    # With neither home variable set and a getpwuid that dies as unimplemented,
    # the staging recipe must report its own explicit error instead of letting
    # the passwd lookup abort the install or silently staging helpers into a
    # relative directory inside the build tree.
    my $makefile_text = _slurp( File::Spec->catfile( $root, 'Makefile.PL' ) );
    my ($staging_code) = $makefile_text =~ /install-private-cli-tools :\n\t\$\(NOECHO\) \$\(PERL\) -e '([^']+)'/;
    $staging_code =~ s/\$\$/\$/g;
    my $windows_like_prelude = 'BEGIN { *CORE::GLOBAL::getpwuid = sub ($) { die "The getpwuid function is unimplemented" }; } ';
    my $sandbox = tempdir( CLEANUP => 1 );
    my ( $stdout, $stderr, $exit ) = capture {
        local %ENV = %ENV;
        delete $ENV{HOME};
        delete $ENV{USERPROFILE};
        my $previous_dir = Cwd::getcwd();
        chdir $sandbox or die "Unable to chdir to $sandbox: $!";
        system( $^X, _perl_source_file( $windows_like_prelude . $staging_code ) );
        my $status = $?;
        chdir $previous_dir or die "Unable to chdir back to $previous_dir: $!";
        $status;
    };
    isnt( $exit >> 8, 0, 'the helper staging one-liner fails when no home directory is resolvable' );
    like( $stderr, qr/Unable to resolve a home directory/,
        'the staging one-liner reports its own missing-home error' );
    unlike( $stderr, qr/unimplemented/,
        'the staging one-liner never lets the unimplemented passwd lookup surface' );
    ok( !-d File::Spec->catdir( $sandbox, '.developer-dashboard' ),
        'the staging one-liner stages nothing into the build directory when home is unresolvable' );
}

{
    my ( $stdout, $stderr, $exit ) = capture {
        system( _posix_shell_binary('sh'), '-n', $install_sh );
    };
    is( $exit >> 8, 0, 'install.sh passes POSIX shell syntax validation' )
      or diag $stdout . $stderr;
}

{
    my $install_sh_text = _slurp($install_sh);
    unlike(
        $install_sh_text,
        qr/CPAN_TARGET="\$\{DD_INSTALL_CPAN_TARGET:-Developer::Dashboard\}"/,
        'install.sh no longer defaults Unix-like streamed installs to the stale CPAN module name',
    );
    like(
        $install_sh_text,
        qr{\Q$default_bootstrap_repository\E},
        'install.sh knows the canonical GitHub repository for the default streamed Unix-like checkout target',
    );
    like(
        $install_sh_text,
        qr/git clone --depth 1 --branch master/,
        'install.sh clones the current GitHub master checkout when no explicit Unix-like install target override is set',
    );
    like(
        $install_sh_text,
        qr/run_cpanm --notest \./,
        'install.sh installs the resolved local checkout with cpanm dot for default Unix-like bootstrap targets',
    );
}

{
    my $install_ps_text = _slurp($install_ps);
    like( $install_ps_text, qr/Set-StrictMode -Version Latest/, 'install.ps1 enables strict PowerShell mode' );
    like( $install_ps_text, qr/\$ErrorActionPreference = 'Stop'/, 'install.ps1 treats PowerShell errors as fatal' );
    like( $install_ps_text, qr/^\& \{/m, 'install.ps1 wraps its body in a script block so the streamed irm ... | iex path stays valid' );
    like( $install_ps_text, qr/Developer Dashboard install progress/, 'install.ps1 prints the Windows progress board title' );
    like( $install_ps_text, qr/winget/, 'install.ps1 uses winget to bootstrap missing Windows packages' );
    like( $install_ps_text, qr/--source',\s*'winget'/, 'install.ps1 pins Windows package installs to the winget source so a broken msstore source does not block bootstrap installs' );
    like( $install_ps_text, qr/source\s+reset|winget source reset/s, 'install.ps1 includes a winget source repair path for bootstrap failures' );
    like( $install_ps_text, qr/Format-ExitCode/, 'install.ps1 formats native Windows exit codes so winget failures show their HRESULT value' );
    like( $install_ps_text, qr/System\.BitConverter.*ToUInt32/s, 'install.ps1 formats negative HRESULT exit codes through BitConverter instead of a failing direct uint32 cast' );
    like( $install_ps_text, qr/function Set-TlsSecurityProtocol/, 'install.ps1 defines a shared TLS hardening helper for Windows bootstrap downloads' );
    like( $install_ps_text, qr/SecurityProtocolType\]::Tls12/, 'install.ps1 explicitly enables TLS 1.2 for bootstrap web requests' );
    like( $install_ps_text, qr/function Download-RemoteFile/, 'install.ps1 defines a shared resilient file downloader for Windows bootstrap assets' );
    like( $install_ps_text, qr/function Get-RemoteJson/, 'install.ps1 defines a shared resilient JSON downloader for Windows bootstrap metadata' );
    like( $install_ps_text, qr/function Get-WindowsBootstrapArchitecture/, 'install.ps1 detects the effective Windows bootstrap architecture before choosing vendor fallback assets' );
    like( $install_ps_text, qr/PROCESSOR_ARCHITEW6432.*PROCESSOR_ARCHITECTURE/s, 'install.ps1 checks both WOW64 and native processor environment variables when resolving Windows architecture' );
    like( $install_ps_text, qr/ARM64.*return 'arm64'/s, 'install.ps1 maps ARM64 Windows hosts explicitly during bootstrap architecture detection' );
    like( $install_ps_text, qr/function Invoke-InstallerCommand/, 'install.ps1 defines a dedicated installer runner for GUI and MSI bootstrap packages' );
    like( $install_ps_text, qr/Start-Process\s+-FilePath\s+\$FilePath\s+-ArgumentList\s+\$Arguments\s+-PassThru\s+-Wait/s, 'install.ps1 waits for GUI and MSI installers through Start-Process instead of piping them like console commands' );
    like( $install_ps_text, qr/curl\.exe|curl/, 'install.ps1 can fall back to curl when Invoke-WebRequest is unreliable inside the Windows guest' );
    like( $install_ps_text, qr/WebClient/, 'install.ps1 can fall back to System\.Net\.WebClient when both Invoke-WebRequest and curl are unavailable or broken' );
    like( $install_ps_text, qr/Install-WindowsPackageFallback/, 'install.ps1 defines an explicit fallback installer path when winget source repair still cannot install a required package' );
    like( $install_ps_text, qr/function Resolve-GitForWindowsInstallerUrl/, 'install.ps1 resolves the latest Git for Windows installer URL dynamically instead of trusting a brittle static redirect' );
    like( $install_ps_text, qr/git-for-windows\/git\/releases\/latest/, 'install.ps1 uses the official Git for Windows latest release page as the source of truth for the fallback installer asset' );
    like( $install_ps_text, qr/git-for-windows\/git\/releases\/download/, 'install.ps1 builds the final Git for Windows fallback asset URL from the resolved release tag and installer filename' );
    like( $install_ps_text, qr/Git-64-bit\.exe/, 'install.ps1 can fall back to the official Git for Windows installer download when winget remains broken' );
    like( $install_ps_text, qr/Git-\[0-9\]\[\^"''<\]\*-arm64\\\.exe/, 'install.ps1 can fall back to the official Git for Windows ARM64 installer download on Windows ARM hosts' );
    like( $install_ps_text, qr/strawberryperl\.com\/releases\.json/, 'install.ps1 resolves Strawberry Perl fallback installers from the official release feed' );
    like( $install_ps_text, qr/MSWin32-x64-multi-thread/, 'install.ps1 targets the supported Strawberry Perl release architecture from the official release feed' );
    like( $install_ps_text, qr/arm64'.*MSWin32-x64-multi-thread/s, 'install.ps1 maps Windows ARM hosts to the official Strawberry Perl x64 build when no ARM-native Strawberry Perl release exists' );
    like( $install_ps_text, qr/nodejs\.org\/dist\/index\.json/, 'install.ps1 resolves Node.js LTS fallback installers from the official Node release index' );
    like( $install_ps_text, qr/function Resolve-NodeLtsPackage/, 'install.ps1 resolves a Windows-architecture-aware Node.js fallback package instead of assuming one MSI shape' );
    like( $install_ps_text, qr/win-arm64-zip/, 'install.ps1 supports the official Node.js ARM64 ZIP fallback for Windows ARM hosts' );
    like( $install_ps_text, qr/function Install-PortableNodeZip/, 'install.ps1 defines a portable Node.js ZIP installer for Windows ARM fallback installs' );
    like( $install_ps_text, qr/Expand-Archive -LiteralPath \$ZipPath -DestinationPath \$extractRoot -Force/, 'install.ps1 extracts the official Node.js ZIP fallback under the user-space install root on Windows ARM hosts' );
    like( $install_ps_text, qr/Add-ProcessPathSegment -PathSegment \$nodeBin/, 'install.ps1 activates the portable Node.js fallback by prepending its runtime directory to PATH' );
    unlike( $install_ps_text, qr/Invoke-RestMethod\s+-Uri\s+'https:\/\/strawberryperl\.com\/releases\.json'/, 'install.ps1 no longer hard-codes Invoke-RestMethod for the Strawberry Perl release feed' );
    unlike( $install_ps_text, qr/Invoke-RestMethod\s+-Uri\s+'https:\/\/nodejs\.org\/dist\/index\.json'/, 'install.ps1 no longer hard-codes Invoke-RestMethod for the Node.js release index' );
    unlike( $install_ps_text, qr/Invoke-WebRequest\s+-Uri\s+'https:\/\/github\.com\/git-for-windows\/git\/releases\/latest\/download\/Git-64-bit\.exe'/, 'install.ps1 no longer hard-codes Invoke-WebRequest for the stale Git fallback installer download URL' );
    unlike( $install_ps_text, qr/Invoke-WebRequest\s+-Uri\s+'https:\/\/cpanmin\.us\/'/, 'install.ps1 no longer hard-codes Invoke-WebRequest for the cpanm bootstrap script download' );
    like( $install_ps_text, qr/msiexec\.exe/, 'install.ps1 uses msiexec for MSI-based Windows fallback installers' );
    like( $install_ps_text, qr/2>&1 \| ForEach-Object \{ Write-Host \$\_ \}/, 'install.ps1 streams native command output to the host instead of leaking it into helper return values' );
    like( $install_ps_text, qr/\$previousErrorActionPreference\s*=\s*\$ErrorActionPreference/s, 'install.ps1 snapshots PowerShell error handling before streaming native command stderr' );
    like( $install_ps_text, qr/\$ErrorActionPreference\s*=\s*'Continue'/s, 'install.ps1 downgrades native stderr records while streaming command output so git and winget progress do not abort the bootstrap' );
    like( $install_ps_text, qr/Refresh-ProcessPathFromEnvironment/, 'install.ps1 refreshes the current PATH after winget installs new tools' );
    like( $install_ps_text, qr/cpanmin\.us/, 'install.ps1 bootstraps cpanm for Windows installs from the standalone cpanmin.us script' );
    unlike( $install_ps_text, qr/'local::lib'\s*,\s*'App::cpanminus'/, 'install.ps1 no longer tries to self-install App::cpanminus while the downloaded cpanm script is still running on Windows' );
    like( $install_ps_text, qr{https://github\.com/manif3station/developer-dashboard\.git}, 'install.ps1 knows the canonical GitHub repository for the streamed Windows bootstrap source' );
    like( $install_ps_text, qr/git\s+clone/s, 'install.ps1 clones the current GitHub master source for the default streamed Windows install target' );
    like( $install_ps_text, qr/Push-Location\s+\$effectiveCpanTarget/s, 'install.ps1 installs the default cloned Windows checkout from inside the local checkout directory' );
    like( $install_ps_text, qr/Sync-LocalLibEnvironmentFromPerl/, 'install.ps1 delegates local::lib environment setup to perl so Windows install paths stay canonical' );
    like(
        $install_ps_text,
        qr/'--notest',\s*'--local-lib-contained',\s*\$InstallRoot,\s*'local::lib',\s*'File::ShareDir::Install'/s,
        'install.ps1 bootstraps the checkout configure prerequisite into the private Windows install root before it installs the checkout',
    );
    like( $install_ps_text, qr/--notest',\s*'--local-lib-contained',\s*\$InstallRoot,\s*'\.'/s, 'install.ps1 runs cpanm against dot with an explicit local-lib target for the default cloned Windows checkout' );
    like( $install_ps_text, qr/--notest',\s*'--local-lib-contained',\s*\$InstallRoot,\s*\$effectiveCpanTarget/s, 'install.ps1 runs cpanm against explicit Windows targets with the same local-lib target' );
    like( $install_ps_text, qr/Sync-LocalLibEnvironmentFromPerl\s+-PerlPath\s+\$perlPath\s+-TargetInstallRoot\s+\$InstallRoot/s, 'install.ps1 reapplies the perl-reported local::lib environment after bootstrapping local::lib on Windows' );
    like( $install_ps_text, qr/function Ensure-GnuMakeCommand/, 'install.ps1 defines a GNU make shim helper for Windows skill Makefiles' );
    like( $install_ps_text, qr/Resolve-CommandPath\s+-Names\s+@\(\s*'gmake\.exe'.*?'mingw32-make\.exe'.*?'make\.exe'/s, 'install.ps1 resolves GNU make from the Strawberry Windows toolchain before creating the shim' );
    like( $install_ps_text, qr/Join-Path\s+\$shimDir\s+'make\.cmd'/s, 'install.ps1 writes a stable make.cmd shim into the user-space Windows bin directory' );
    like( $install_ps_text, qr/%\*/, 'install.ps1 forwards Windows make arguments through the shim without shell mangling' );
    like( $install_ps_text, qr/Ensure-GnuMakeCommand\s+-TargetInstallRoot\s+\$InstallRoot/s, 'install.ps1 wires GNU make setup into the Windows Perl bootstrap flow' );
    like( $install_ps_text, qr/cpanm, local::lib, GNU make, and configure prereqs ready/, 'install.ps1 reports GNU make readiness in the Windows Perl bootstrap progress detail' );
    like( $install_ps_text, qr/Ensure-ProfileContains\s+-TargetProfile\s+\$ProfilePath\s+-Block\s+\$profileBlock\s+-Marker\s+'Developer Dashboard bootstrap'/s, 'install.ps1 replaces the managed Developer Dashboard profile block instead of appending duplicate stale Windows bootstrap chunks' );
    like( $install_ps_text, qr/# >>> Developer Dashboard bootstrap >>>/, 'install.ps1 wraps the managed PowerShell profile block in a stable begin marker' );
    like( $install_ps_text, qr/# <<< Developer Dashboard bootstrap <<</, 'install.ps1 wraps the managed PowerShell profile block in a stable end marker' );
    like( $install_ps_text, qr/\[Regex\]::Escape\(\$beginMarker\)/, 'install.ps1 escapes the managed begin marker with the .NET regex API before replacing older profile blocks' );
    like( $install_ps_text, qr/\[Regex\]::Escape\(\$endMarker\)/, 'install.ps1 escapes the managed end marker with the .NET regex API before replacing older profile blocks' );
    unlike( $install_ps_text, qr/\\Q\$beginMarker\\E|\\Q\$endMarker\\E/, 'install.ps1 avoids Perl-style \\Q...\\E regex quoting that PowerShell does not support in [Regex]::Replace' );
    like( $install_ps_text, qr/legacyManagedPattern/, 'install.ps1 strips legacy unmarked Developer Dashboard profile blocks from earlier Windows bootstrap failures' );
    like( $install_ps_text, qr/\`\$ddCacheRoot = Join-Path\s+\`\$env:HOME\s+'\.developer-dashboard\\cache'/s, 'install.ps1 resolves the managed PowerShell cache root from env:HOME, matching the Perl-side home resolution, without invoking Perl during profile startup' );
    unlike( $install_ps_text, qr/\`\$ddCacheRoot = Join-Path\s+\`\$HOME\s/s, 'install.ps1 does not resolve the managed PowerShell cache root from the PowerShell-only HOME variable, which can diverge from the HOME that Perl writes the cache under' );
    like( $install_ps_text, qr/function Resolve-DashboardRuntimeHome/s, 'install.ps1 has a dedicated resolver for the HOME that the Perl runtime uses for its cache root' );
    like( $install_ps_text, qr/\$env:HOME = Resolve-DashboardRuntimeHome/s, 'install.ps1 seeds env:HOME for its own session so the Perl runtime and the generated profile agree on the cache root' );
    like( $install_ps_text, qr/\$powershellCacheRoot = Join-Path\s+\$env:HOME\s+'\.developer-dashboard\\cache'/s, 'install.ps1 validates the same env:HOME-derived cache root that the generated profile will read' );
    like( $install_ps_text, qr/if\s+\(\[string\]::IsNullOrWhiteSpace\(\`\$env:HOME\)\)\s*\{\s*\`\$env:HOME = '\$profileRuntimeHome'/s, 'install.ps1 bakes the install-time runtime home into the managed profile block as a last-resort seed so the cache root is never joined against an empty HOME' );
    like( $install_ps_text, qr/Join-Path\s+\`\$ddCacheRoot\s+'powershell-env\.ps1'/s, 'install.ps1 points the managed profile at the cached local-lib environment script' );
    like( $install_ps_text, qr/Join-Path\s+\`\$ddCacheRoot\s+'powershell-bootstrap\.ps1'/s, 'install.ps1 points the managed profile at the cached d2 shell bootstrap script' );
    like( $install_ps_text, qr/\.\s+\`\$ddEnvironmentCache.*?\.\s+\`\$ddBootstrapCache/s, 'install.ps1 dot-sources the cached environment before the cached shell bootstrap' );
    like( $install_ps_text, qr/Run 'd2 shell ps' to refresh them/, 'install.ps1 gives an actionable warning when either PowerShell startup cache file is unavailable' );
    like( $install_ps_text, qr/if\s+\(\[string\]::IsNullOrWhiteSpace\(\`\$env:HOME\)\s+-and\s+-not\s+\[string\]::IsNullOrWhiteSpace\(\`\$HOME\)\)\s*\{\s*\`\$env:HOME = \`\$HOME/s, 'install.ps1 seeds env:HOME from PowerShell HOME inside the managed profile block for future sessions' );
    like( $install_ps_text, qr/\$profilePerlRuntimePaths\s*=\s*\@/s, 'install.ps1 captures the resolved Strawberry Perl runtime directories before writing the managed PowerShell profile block' );
    like( $install_ps_text, qr/\$profileExtraRuntimePaths\s*=\s*\@/s, 'install.ps1 captures extra Windows runtime directories such as portable Node.js before writing the managed PowerShell profile block' );
    like( $install_ps_text, qr/\`\$ddPerlRuntimePaths\s*=\s*\@/s, 'install.ps1 writes the Strawberry Perl runtime directories into the managed PowerShell profile block for future sessions' );
    like( $install_ps_text, qr/\`\$ddExtraRuntimePaths\s*=\s*\@/s, 'install.ps1 writes any extra portable Windows runtime directories into the managed PowerShell profile block for future sessions' );
    like( $install_ps_text, qr/foreach\s+\(\`\$ddPerlRuntimePath in \`\$ddPerlRuntimePaths\)/s, 'install.ps1 prepends the persisted Strawberry Perl runtime directories in future PowerShell sessions before resolving dashboard' );
    like( $install_ps_text, qr/foreach\s+\(\`\$ddExtraRuntimePath in \`\$ddExtraRuntimePaths\)/s, 'install.ps1 also prepends any persisted portable Windows runtime directories in future PowerShell sessions' );
    unlike( $install_ps_text, qr/\$ddDashboardCandidate in \@\(\s*\(Join-Path\s+\`\$ddPerlBin\s+'dashboard\.bat'\),\s*\(Join-Path\s+\`\$ddPerlBin\s+'dashboard\.cmd'\),\s*\(Join-Path\s+\`\$ddPerlBin\s+'dashboard'\),\s*\(\(Get-Command dashboard -ErrorAction SilentlyContinue\)\.Source\)\s*\)/s, 'install.ps1 does not resolve d2 commands inside the generated PowerShell profile block' );
    unlike( $install_ps_text, qr/\$ddShellBootstrap\s*=\s*&\s+\`\$ddPerlCommand\.Source\s+\`\$ddDashboardCommand\s+shell\s+ps/s, 'install.ps1 does not launch Perl plus d2 shell ps from the generated PowerShell profile' );
    unlike( $install_ps_text, qr/\$ddShellBootstrapText\s*=\s*Join-ScriptText\s+-Value\s+\`\$ddShellBootstrap/s, 'install.ps1 does not leak installer-only Join-ScriptText helper calls into the generated PowerShell profile block' );
    unlike( $install_ps_text, qr/\$ddShellBootstrapText\s*=\s*\(\(@\(\`\$ddShellBootstrap \| Where-Object \{ .*? \} \| ForEach-Object \{ .*? \}\)\) -join \[Environment\]::NewLine\)/s, 'install.ps1 no longer normalizes live d2 shell output inside the generated PowerShell profile block' );
    unlike( $install_ps_text, qr/Invoke-Expression\s+\`\$ddShellBootstrapText/s, 'install.ps1 does not evaluate live d2 shell output during PowerShell profile startup' );
    like( $install_ps_text, qr/Invoke-NativeCommand\s+-Label\s+'d2 init'\s+-FilePath\s+\$dashboardCommand\s+-Arguments\s+\@\(\'init\'\).*?&\s+\$perlPath\s+\$dashboardCommand\s+shell\s+ps/s, 'install.ps1 initializes the dashboard runtime before asking perl plus the installed d2 command for its PowerShell bootstrap on Windows' );
    like( $install_ps_text, qr/\$dashboardShellBootstrapText\s*=\s*Join-ScriptText\s+-Value\s+\$dashboardShellBootstrap/s, 'install.ps1 normalizes the current-session d2 shell ps output into one script string' );
    like( $install_ps_text, qr/\$powershellEnvironmentCache\s*=\s*Join-Path\s+\$powershellCacheRoot\s+'powershell-env\.ps1'/s, 'install.ps1 resolves the generated PowerShell environment cache before installing the managed profile block' );
    like( $install_ps_text, qr/\$powershellBootstrapCache\s*=\s*Join-Path\s+\$powershellCacheRoot\s+'powershell-bootstrap\.ps1'/s, 'install.ps1 resolves the generated PowerShell bootstrap cache before installing the managed profile block' );
    like( $install_ps_text, qr/&\s+\$perlPath\s+\$dashboardCommand\s+shell\s+ps.*?Test-Path\s+-LiteralPath\s+\$powershellEnvironmentCache\s+-PathType\s+Leaf.*?Test-Path\s+-LiteralPath\s+\$powershellBootstrapCache\s+-PathType\s+Leaf.*?Ensure-ProfileContains/s, 'install.ps1 generates and validates both non-empty PowerShell caches before writing the managed profile block' );
    like( $install_ps_text, qr/PowerShell startup cache generation failed.*?d2 shell ps/s, 'install.ps1 stops with a cache-refresh diagnostic instead of installing a profile backed by missing cache files' );
    like( $install_ps_text, qr/Language\.Parser\]::ParseFile.*?powershellEnvironmentCache.*?powershellBootstrapCache/s, 'install.ps1 parses both generated PowerShell caches before installing the managed profile block' );
    like( $install_ps_text, qr/catch\s*\{.*?PowerShell startup cache files could not be loaded.*?d2 shell ps/s, 'install.ps1 generated profile reports an actionable refresh instruction when a non-empty cache file is corrupt' );
    unlike( $install_ps_text, qr/Invoke-Expression\s+\(&\s+\$dashboardCommand\s+shell\s+ps\)/, 'install.ps1 no longer invokes d2 shell ps directly without checking for empty output' );
    unlike( $install_ps_text, qr/\$CpanTarget\s*=\s*if\s*\(\[string\]::IsNullOrWhiteSpace\(\$env:DD_INSTALL_CPAN_TARGET\)\)\s*\{\s*'Developer::Dashboard'\s*\}/, 'install.ps1 no longer defaults streamed Windows installs to the stale CPAN module name' );
    like( $install_ps_text, qr/cpanm.*--notest/s, 'install.ps1 installs Developer Dashboard with cpanm --notest on Windows' );
    like( $install_ps_text, qr/d2 init/, 'install.ps1 initializes the dashboard runtime after the Windows install' );
    like( $install_ps_text, qr/\bshell\s+ps\b/, 'install.ps1 activates the PowerShell bootstrap after installation' );
    like( $install_ps_text, qr/Set-ExecutionPolicy\s+-Scope\s+CurrentUser\s+-ExecutionPolicy\s+RemoteSigned\s+-Force/s, 'install.ps1 enables a CurrentUser PowerShell execution policy that can load the generated profile in future sessions' );
    like( $install_ps_text, qr/ExecutionPolicyOverride/, 'install.ps1 treats the benign CurrentUser execution-policy override warning explicitly during streamed bootstrap runs' );
    like( $install_ps_text, qr/kept the saved CurrentUser policy and continued/s, 'install.ps1 explains when a more specific PowerShell execution-policy scope keeps the current session in Bypass while the saved CurrentUser policy still succeeds' );
    like( $install_ps_text, qr/Get-ExecutionPolicy\s+-Scope\s+CurrentUser/s, 'install.ps1 inspects the current-user execution policy before changing it' );
    like( $install_ps_text, qr/-Mlocal::lib=\$normalizedInstallRoot/s, 'install.ps1 asks perl local::lib for canonical Windows environment values instead of composing INSTALL_BASE manually' );
    unlike( $install_ps_text, qr/-Mlocal::lib=\`\$ddInstallRootForward/s, 'install.ps1 does not refresh local::lib from perl in future PowerShell sessions' );
}

my @apt_packages  = _manifest_lines($aptfile);
my @apk_packages  = _manifest_lines($apkfile);
my @dnf_packages  = _manifest_lines($dnfile);
my @brew_packages = _manifest_lines($brewfile);
ok( scalar grep { $_ eq 'tmux' } @apt_packages,  'aptfile includes tmux because d2 workspace depends on it' );
ok( scalar grep { $_ eq 'tmux' } @apk_packages,  'apkfile includes tmux because d2 workspace depends on it' );
ok( scalar grep { $_ eq 'tmux' } @dnf_packages,  'dnfile includes tmux because d2 workspace depends on it' );
ok( scalar grep { $_ eq 'tmux' } @brew_packages, 'brewfile includes tmux because d2 workspace depends on it' );
my @expected_apt_bootstrap_steps = _expected_apt_bootstrap_steps(
    packages => \@apt_packages,
);
my @expected_apk_bootstrap_steps = _expected_apk_bootstrap_steps(
    packages => \@apk_packages,
);
my @expected_dnf_bootstrap_steps = _expected_dnf_bootstrap_steps(
    packages => \@dnf_packages,
);

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $target = File::Spec->catfile( $home, 'Developer-Dashboard.tar.gz' );
    my $fake_perl = File::Spec->catfile( $fake_bin, 'perl' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                  value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'fedora' },
        { key => 'DD_INSTALL_CPAN_TARGET', value => $target },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh succeeds on Fedora hosts with mocked system commands' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            @expected_dnf_bootstrap_steps,
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            "cpanm --no-wget --notest $target",
            'd2 init',
        ],
        'install.sh follows the Fedora bootstrap flow in manifest order',
    );

    my $bashrc = File::Spec->catfile( $home, '.bashrc' );
    my $profile = File::Spec->catfile( $home, '.profile' );
    ok( -f $bashrc, 'install.sh creates or updates ~/.bashrc for Fedora bash users' );
    ok( -f $profile, 'install.sh creates ~/.profile as the activation entry point for Fedora bash users' );
    my $bashrc_text = _slurp($bashrc);
    my $local_lib_line = qq{eval "\$("$fake_perl" -I "$home/perl5/lib/perl5" -Mlocal::lib)"};
    like(
        $bashrc_text,
        qr/\Q$local_lib_line\E/,
        'install.sh wires the local::lib bootstrap into ~/.bashrc for Fedora bash users',
    );
    like(
        $bashrc_text,
        qr/eval "\$\(\"[^\"]*\/d2" shell bash\)"/,
        'install.sh appends the Developer Dashboard bash shell bootstrap to ~/.bashrc on Fedora',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $target = File::Spec->catfile( $home, 'Developer-Dashboard.tar.gz' );
    my $fake_perl = File::Spec->catfile( $fake_bin, 'perl' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                  value => '/bin/sh' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'alpine' },
        { key => 'DD_INSTALL_CPAN_TARGET', value => $target },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh succeeds on Alpine hosts with mocked system commands' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            @expected_apk_bootstrap_steps,
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            "cpanm --no-wget --notest $target",
            'd2 init',
        ],
        'install.sh follows the Alpine bootstrap flow in manifest order',
    );

    my $profile = File::Spec->catfile( $home, '.profile' );
    ok( -f $profile, 'install.sh creates ~/.profile for Alpine sh users' );
    my $profile_text = _slurp($profile);
    my $local_lib_line = qq{eval "\$("$fake_perl" -I "$home/perl5/lib/perl5" -Mlocal::lib)"};
    like(
        $profile_text,
        qr/\Q$local_lib_line\E/,
        'install.sh wires the local::lib bootstrap into ~/.profile for Alpine sh users',
    );
    like(
        $profile_text,
        qr/eval "\$\(\"[^\"]*\/d2" shell sh\)"/,
        'install.sh appends the Developer Dashboard sh shell bootstrap to ~/.profile on Alpine',
    );
    like(
        $stdout,
        qr/Shell setup was written to: \Q$profile\E/s,
        'install.sh reports the Alpine rc file it updated',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $target = File::Spec->catfile( $home, 'Developer-Dashboard.tar.gz' );
    my $fake_perl = File::Spec->catfile( $fake_bin, 'perl' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                  value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'ubuntu' },
        { key => 'DD_INSTALL_CPAN_TARGET', value => $target },
      );

    my $existing_bashrc = File::Spec->catfile( $home, '.bashrc' );
    open my $existing_bashrc_fh, '>', $existing_bashrc or die "Unable to seed $existing_bashrc: $!";
    binmode $existing_bashrc_fh;
    print {$existing_bashrc_fh} <<'BASHRC';
[ -z "$PS1" ] && return
BASHRC
    close $existing_bashrc_fh or die "Unable to close $existing_bashrc: $!";

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh succeeds on Debian-family hosts with mocked system commands' )
      or diag $stdout . $stderr;
    like(
        $stdout,
        qr/Developer Dashboard install progress/,
        'install.sh prints a visible progress board before running Debian-family bootstrap work',
    );
    is(
        scalar( () = $stdout =~ /Developer Dashboard install progress/g ),
        1,
        'install.sh prints the progress board header once and then emits step transitions without redrawing the whole board',
    );
    if ( _shell_runs_as_root() ) {
        unlike(
            $stdout,
            qr/sudo will ask for your operating-system account password, not a Developer Dashboard password/s,
            'install.sh skips the sudo password explanation when it is already running as root',
        );
    }
    else {
        like(
            $stdout,
            qr/sudo will ask for your operating-system account password, not a Developer Dashboard password/s,
            'install.sh explains the sudo password prompt before requesting system package access',
        );
    }

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            @expected_apt_bootstrap_steps,
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            "cpanm --no-wget --notest $target",
            'd2 init',
        ],
        'install.sh follows the Debian-family bootstrap flow in manifest order',
    );

    my $bashrc = File::Spec->catfile( $home, '.bashrc' );
    my $profile = File::Spec->catfile( $home, '.profile' );
    ok( -f $bashrc, 'install.sh creates or updates ~/.bashrc for bash users' );
    ok( -f $profile, 'install.sh creates ~/.profile as the activation entry point for bash users' );
    my $bashrc_text = _slurp($bashrc);
    my $profile_text = _slurp($profile);
    my $local_lib_line = qq{eval "\$("$fake_perl" -I "$home/perl5/lib/perl5" -Mlocal::lib)"};
    like(
        $bashrc_text,
        qr/\Q$local_lib_line\E/,
        'install.sh wires the local::lib bootstrap through the resolved Perl interpreter on PATH',
    );
    like(
        $bashrc_text,
        qr/eval "\$\(\"[^\"]*\/d2" shell bash\)"/,
        'install.sh appends the Developer Dashboard bash shell bootstrap to ~/.bashrc',
    );
    ok(
        $bashrc_text =~ qr/\Q$local_lib_line\E\n.*eval "\$\(\"[^\"]*\/d2" shell bash\)".*\ncase \$- in/s
          || $bashrc_text =~ qr/\Q$local_lib_line\E\n.*eval "\$\(\"[^\"]*\/d2" shell bash\)".*\n\[ -z "\$PS1" \] && return/s,
        'install.sh keeps dashboard-managed bash bootstrap lines ahead of the non-interactive return guard in ~/.bashrc',
    );
    like(
        $profile_text,
        qr/if \[ -f "\$HOME\/\.bashrc" \]; then\s+\. "\$HOME\/\.bashrc"\s+fi/s,
        'install.sh bridges ~/.profile to ~/.bashrc for future bash shells',
    );
    like(
        $stdout,
        qr/Shell setup was written to: \Q$bashrc\E/s,
        'install.sh reports the exact rc file it updated',
    );
    like(
        $stdout,
        qr/Shell activation entry point: \Q$profile\E/s,
        'install.sh reports the shell entry point to source after a piped install',
    );
    like(
        $stdout,
        qr/This installer ran in a child sh process, so your current shell has not loaded the new PATH yet\./s,
        'install.sh explains why the parent shell cannot see dashboard immediately after a piped run',
    );
    like(
        $stdout,
        qr/Run this now in your current shell:\s+\. "\Q$profile\E"/s,
        'install.sh prints the exact source command for the caller shell',
    );
    like(
        $stdout,
        qr/Then verify with:\s+d2 version/s,
        'install.sh tells the user how to verify the command is available after activation',
    );
    unlike(
        $stdout . $stderr,
        qr{/dev/tty: No such device or address},
        'install.sh does not probe /dev/tty during piped installs',
    );

    my ( $again_out, $again_err, $again_exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $again_exit >> 8, 0, 'install.sh remains idempotent for the selected shell rc file' )
      or diag $again_out . $again_err;
    my $bashrc_again = _slurp($bashrc);
    is(
        scalar( () = $bashrc_again =~ /\Q$local_lib_line\E/g ),
        1,
        'install.sh does not duplicate the local::lib bootstrap line on repeat runs',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $shell_runner = File::Spec->catfile( $fake_bin, 'shell-runner' );
    _write_executable(
        $shell_runner,
        <<"SH",
#!/bin/sh
printf '%s\\n' "shell-runner \$*" >> "$log"
exit 0
SH
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                     value => $home },
        { key => 'PATH',                     value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                    value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE',   value => 'ubuntu' },
        { key => 'DD_INSTALL_SHELL_COMMANDS', value => 'd2 version; d2 version; d2 skills install browser' },
        { key => 'DD_INSTALL_SHELL_BIN',     value => $shell_runner },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh can run post-install commands through the activated shell environment' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    like(
        join( "\n", @log_lines ),
        qr/shell-runner -ilc \. "\Q$home\/.profile\E" .*d2 version; d2 version; d2 skills install browser/s,
        'install.sh dispatches post-install commands through the activated bash shell entry point',
    );
    like(
        $stdout,
        qr/Running post-install activation commands through bash\./,
        'install.sh explains that it is executing the post-install shell commands',
    );
    like(
        $stdout,
        qr/Post-install activation commands completed\./,
        'install.sh confirms that the post-install shell commands completed',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $fake_bash = File::Spec->catfile( $fake_bin, 'bash' );
    _write_executable(
        $fake_bash,
        <<"SH",
#!/bin/sh
printf '%s\\n' "fake-bash \$*" >> "$log"
exit 0
SH
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                       value => $home },
        { key => 'PATH',                       value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                      value => '' },
        { key => 'DD_INSTALL_PREFERRED_SHELL', value => 'bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE',     value => 'ubuntu' },
        { key => 'DD_INSTALL_SHELL_COMMANDS',  value => 'd2 version' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh can run post-install commands when SHELL is unset in a blank container' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    like(
        join( "\n", @log_lines ),
        qr/fake-bash -ilc \. "\Q$home\/.profile\E" .*d2 version/s,
        'install.sh resolves the bash bootstrap target as the post-install runner instead of falling back to sh when SHELL is unset',
    );
    like(
        $stdout,
        qr/Running post-install activation commands through bash\./,
        'install.sh still reports the bash bootstrap target for blank-container runs',
    );
    like(
        $stdout,
        qr/Post-install activation commands completed\./,
        'install.sh completes the post-install shell commands without a target-runner dialect mismatch',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $shell_runner = File::Spec->catfile( $fake_bin, 'shell-runner' );
    _write_executable(
        $shell_runner,
        <<"SH",
#!/bin/sh
printf '%s\\n' "shell-runner \$*" >> "$log"
exit 0
SH
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                      value => $home },
        { key => 'PATH',                      value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                     value => '/bin/sh' },
        { key => 'DD_INSTALL_OS_OVERRIDE',    value => 'alpine' },
        { key => 'DD_INSTALL_SHELL_COMMANDS', value => 'd2 version; d2 version' },
        { key => 'DD_INSTALL_SHELL_BIN',      value => $shell_runner },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh can run post-install commands through the activated sh environment' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    like(
        join( "\n", @log_lines ),
        qr/shell-runner -ic \. "\Q$home\/.profile\E" .*d2 version; d2 version/s,
        'install.sh dispatches post-install commands through the activated sh shell entry point',
    );
    like(
        $stdout,
        qr/Running post-install activation commands through sh\./,
        'install.sh explains that it is executing the post-install shell commands for sh users',
    );
    like(
        $stdout,
        qr/Post-install activation commands completed\./,
        'install.sh confirms that the sh post-install shell commands completed',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                      value => $home },
        { key => 'PATH',                      value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                     value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE',    value => 'ubuntu' },
        { key => 'DD_INSTALL_BOOTSTRAP_CHECKOUT_DIR', value => $checkout },
        { key => 'FAKE_NODEJS_PROVIDES_NPM',  value => '1' },
        { key => 'FAKE_NPM_PACKAGE_CONFLICTS', value => '1' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh skips the distro npm package when nodejs already provides npm and npx' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            _expected_apt_bootstrap_steps(
                packages             => \@apt_packages,
                nodejs_provides_npm => 1,
            ),
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --no-wget --notest .',
            'd2 init',
        ],
        'install.sh avoids the conflicting Debian npm package when nodejs already ships the full Node toolchain and installs the local checkout directly',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                  value => '/bin/zsh' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'darwin' },
        { key => 'DD_INSTALL_BOOTSTRAP_CHECKOUT_DIR', value => $checkout },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh succeeds on macOS hosts with mocked Homebrew commands' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            'brew install ' . join( ' ', @brew_packages ),
            'brew --prefix perl',
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            'brew --prefix openssl@3',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --no-wget --notest .',
            'd2 init',
        ],
        'install.sh follows the macOS bootstrap flow in manifest order and installs the local checkout directly',
    );

    my $zshrc = File::Spec->catfile( $home, '.zshrc' );
    ok( -f $zshrc, 'install.sh creates or updates ~/.zshrc for zsh users' );
    like(
        _slurp($zshrc),
        qr/eval "\$\(\"[^\"]*\/d2" shell zsh\)"/,
        'install.sh appends the Developer Dashboard zsh shell bootstrap to ~/.zshrc',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    my $bootstrap_tmpdir = File::Spec->catdir( $home, 'installer-tmp' );
    make_path($bootstrap_tmpdir);
    local $ENV{TMPDIR} = $bootstrap_tmpdir;
    _seed_fake_install_commands(
        fake_bin         => $fake_bin,
        log              => $log,
        fake_brew_on_path => 0,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _path_hiding_command('brew') },
        { key => 'SHELL',                  value => '/bin/zsh' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'darwin' },
        { key => 'DD_INSTALL_BOOTSTRAP_CHECKOUT_DIR', value => $checkout },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh bootstraps Homebrew on blank macOS hosts before installing brew packages' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            'curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o '
              . File::Spec->catfile( $bootstrap_tmpdir, 'developer-dashboard-homebrew-install.sh' ),
            '/bin/bash -c ' . File::Spec->catfile( $bootstrap_tmpdir, 'developer-dashboard-homebrew-install.sh' ),
            'brew install ' . join( ' ', @brew_packages ),
            'brew --prefix perl',
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            'brew --prefix openssl@3',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --no-wget --notest .',
            'd2 init',
        ],
        'install.sh downloads and runs the Homebrew bootstrap before the normal macOS package flow and installs the local checkout directly when brew is missing',
    );
    like(
        $stdout,
        qr/Bootstrapping Homebrew because brew is missing on this macOS host\./,
        'install.sh explains the Homebrew bootstrap step on blank macOS hosts',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                       value => $home },
        { key => 'PATH',                       value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                      value => '/bin/sh' },
        { key => 'DD_INSTALL_PREFERRED_SHELL', value => '/bin/zsh' },
        { key => 'DD_INSTALL_OS_OVERRIDE',     value => 'darwin' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh succeeds when sh runs the installer for a zsh user' )
      or diag $stdout . $stderr;

    my $zshrc = File::Spec->catfile( $home, '.zshrc' );
    my $profile = File::Spec->catfile( $home, '.profile' );
    ok( -f $zshrc, 'install.sh still targets ~/.zshrc when the preferred shell is zsh even if sh runs the installer' );
    like(
        _slurp($zshrc),
        qr/eval "\$\(\"[^\"]*\/d2" shell zsh\)"/,
        'install.sh appends the zsh bootstrap to ~/.zshrc when the preferred shell is zsh',
    );
    unlike(
        ( -f $profile ? _slurp($profile) : '' ),
        qr/eval "\$\(\"[^\"]*\/d2" shell sh\)"/,
        'install.sh does not leak the fallback sh bootstrap into ~/.profile for zsh users',
    );
    like(
        $stdout,
        qr/Shell setup was written to: \Q$zshrc\E/s,
        'install.sh reports the zsh rc file when the preferred shell is zsh',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                  value => '/bin/sh' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'debian' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh succeeds with POSIX sh users' )
      or diag $stdout . $stderr;

    my $profile = File::Spec->catfile( $home, '.profile' );
    ok( -f $profile, 'install.sh falls back to ~/.profile for generic POSIX sh users' );
    like(
        _slurp($profile),
        qr/eval "\$\(\"[^\"]*\/d2" shell sh\)"/,
        'install.sh appends the Developer Dashboard POSIX shell bootstrap to ~/.profile',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    my $script_copy = _slurp($install_sh);
    my $scratch = tempdir( CLEANUP => 1 );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                  value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'ubuntu' },
        { key => 'DD_INSTALL_BOOTSTRAP_CHECKOUT_DIR', value => $checkout },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        open my $pipe, '|-', _posix_shell_binary('sh'), _sh_script("cd '$scratch' && $env_prefix sh -s") or die "Unable to start streamed installer: $!";
        binmode $pipe;
        print {$pipe} $script_copy;
        close $pipe or die "Streamed installer exited non-zero: $?";
    };
    is( $exit >> 8, 0, 'install.sh succeeds when streamed through sh stdin without repo manifests on disk' )
      or diag $stdout . $stderr;

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            @expected_apt_bootstrap_steps,
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            "git clone --depth 1 --branch master $default_bootstrap_repository $checkout",
            'cpanm --no-wget --notest .',
            'd2 init',
        ],
        'streamed install.sh falls back to the embedded Debian-family manifest content and installs the default dashboard checkout from GitHub master',
    );
    like(
        $stdout,
        qr/Run this now in your current shell:\s+\. "\Q$home\/.profile\E"/s,
        'streamed install.sh prints an activation command that targets the shell entry point',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                  value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'debian' },
        { key => 'FAKE_PERL_MEETS_MIN',    value => '0' },
        { key => 'DD_INSTALL_BOOTSTRAP_CHECKOUT_DIR', value => $checkout },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh bootstraps perlbrew when the system Perl is too old on Debian-family hosts' )
      or diag $stdout . $stderr;
    unlike(
        $stdout,
        qr/Append the following piece of code to the end of your ~\/\.profile/s,
        'install.sh suppresses raw perlbrew profile instructions and keeps shell setup guidance in its own output',
    );
    like(
        $stdout,
        qr/Updated \Q$home\/.bashrc\E so perlbrew metadata and perl-5\.44\.0 load automatically in new shells\./,
        'install.sh reports which rc file it updated for perlbrew bootstrap',
    );

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            @expected_apt_bootstrap_steps,
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            'perl -MConfig -e print $Config{archname}',
            'perlbrew init',
            'perlbrew list',
            'perlbrew --notest install perl-5.44.0',
            'perlbrew install-cpanm',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --no-wget --notest .',
            'd2 init',
        ],
        'install.sh switches to perlbrew before the local::lib bootstrap when Debian ships an older Perl and then installs the local checkout directly',
    );

    my $bashrc = File::Spec->catfile( $home, '.bashrc' );
    my $profile = File::Spec->catfile( $home, '.profile' );
    my $bashrc_text = _slurp($bashrc);
    my $profile_text = _slurp($profile);
    like(
        $bashrc_text,
        qr/export PERLBREW_HOME="\Q$home\E\/perl5\/perlbrew"/,
        'install.sh records PERLBREW_HOME in the active shell rc file',
    );
    like(
        $bashrc_text,
        qr/export PATH="\Q$home\E\/perl5\/perlbrew\/perls\/perl-5\.44\.0\/bin:\$PATH"/,
        'install.sh records the perlbrew Perl path in the active shell rc file',
    );
    like(
        $bashrc_text,
        qr/eval "\$\(\"[^\"]*\/d2" shell bash\)"/,
        'install.sh appends the Developer Dashboard bash shell bootstrap after the perlbrew rescue path',
    );
    like(
        $profile_text,
        qr/if \[ -f "\$HOME\/\.bashrc" \]; then\s+\. "\$HOME\/\.bashrc"\s+fi/s,
        'install.sh keeps the bash login shell entry point wired to ~/.bashrc when perlbrew is needed',
    );
}

{
    my $home = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log = File::Spec->catfile( $home, 'install.log' );
    my $checkout = File::Spec->catfile( $home, 'default-dashboard-checkout' );
    _seed_fake_install_commands(
        fake_bin                        => $fake_bin,
        log                             => $log,
        fake_perlbrew_on_path           => 0,
        fake_cpanm_installs_local_perlbrew => 1,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _path_hiding_command('perlbrew') },
        { key => 'SHELL',                  value => '/bin/sh' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'alpine' },
        { key => 'FAKE_PERL_MEETS_MIN',    value => '0' },
        { key => 'DD_INSTALL_BOOTSTRAP_CHECKOUT_DIR', value => $checkout },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh'");
    };
    is( $exit >> 8, 0, 'install.sh can invoke a locally bootstrapped perlbrew on Alpine without losing @INC' )
      or diag $stdout . $stderr;
    unlike(
        $stdout . $stderr,
        qr/Can't locate App\/perlbrew\.pm/,
        'install.sh no longer loses the local App::perlbrew install when bootstrapping Perl on Alpine',
    );
    unlike(
        $stdout . $stderr,
        qr/Use of uninitialized value \$err in numeric eq \(==\) at .*IO\/Socket\/IP\.pm line 739\./,
        'install.sh avoids the Alpine IO::Socket::IP warning while bootstrapping App::perlbrew',
    );
    unlike(
        $stdout . $stderr,
        qr/retry-connrefused|BusyBox v[0-9.]+ .*multi-call binary|unrecognized option: retry-connrefused/,
        'install.sh avoids BusyBox wget when Alpine cpanm resolves bootstrap modules',
    );

    my @log_lines = _log_lines($log);
    is_deeply(
        \@log_lines,
        [
            _expected_apk_bootstrap_steps( packages => \@apk_packages ),
            'perl -e exit(($] >= 5.038) ? 0 : 1)',
            'perl -MConfig -e print $Config{archname}',
            "curl -fsSL $perlbrew_app_dist_url -o $home/perl5/bootstrap-cache/$perlbrew_app_dist_basename",
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 $home/perl5/bootstrap-cache/$perlbrew_app_dist_basename",
            'perlbrew init',
            'perlbrew list',
            'perlbrew --notest install perl-5.44.0',
            'patchperl apply perl-5.44.0',
            'perlbrew install-cpanm',
            "cpanm --no-wget --notest --local-lib-contained $home/perl5 local::lib App::cpanminus File::ShareDir::Install",
            "perl -I $home/perl5/lib/perl5 -Mlocal::lib",
            'cpanm --no-wget --notest .',
            'd2 init',
        ],
        'install.sh activates the local App::perlbrew install before invoking perlbrew on Alpine and then installs the local checkout directly',
    );

    my $profile = File::Spec->catfile( $home, '.profile' );
    my $profile_text = _slurp($profile);
    like(
        $profile_text,
        qr/eval "\$\(\"[^\"]*\/d2" shell sh\)"/,
        'install.sh keeps the shell bootstrap in the active Alpine profile after the perlbrew rescue path',
    );
    unlike(
        $profile_text,
        qr/\. "\Q$home\E\/perl5\/perlbrew\/etc\/bashrc"/,
        'install.sh keeps the Alpine sh profile free of the perlbrew bashrc snippet',
    );
}

# install.sh arguments. No argument is the existing path, covered by every
# scenario above. An unknown argument must be settled before a single tool
# runs, so each scenario here seeds the full set of fake tools and then
# checks that none of them was called and no shell rc file was written.
# --jenkins alone is the test-node route, covered further down.
for my $case (
    {
        label  => 'an unknown argument',
        args   => q{'--no-such-option'},
        exit   => 2,
        stderr => qr/install\.sh: unknown argument: --no-such-option\n.*Usage: install\.sh \[--jenkins\]/s,
    },
    {
        label  => 'a second argument after --jenkins',
        args   => q{'--jenkins' 'extra'},
        exit   => 2,
        stderr => qr/install\.sh: unknown argument: --jenkins extra\n.*Usage: install\.sh \[--jenkins\]/s,
    },
  )
{
    my $home     = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log      = File::Spec->catfile( $home, 'install.log' );
    _seed_fake_install_commands(
        fake_bin => $fake_bin,
        log      => $log,
    );

    my $env_prefix = join ' ',
      map { sprintf q{%s='%s'}, $_->{key}, _msys_path( $_->{value} ) } (
        { key => 'HOME',                   value => $home },
        { key => 'PATH',                   value => _msys_path($fake_bin) . ':' . _base_path() },
        { key => 'SHELL',                  value => '/bin/bash' },
        { key => 'DD_INSTALL_OS_OVERRIDE', value => 'debian' },
      );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh' $case->{args}");
    };
    is( $exit >> 8, $case->{exit}, "install.sh given $case->{label} stops with exit $case->{exit}" )
      or diag $stdout . $stderr;
    like( $stderr, $case->{stderr}, "install.sh given $case->{label} says why on standard error" );
    is( $stdout, '', "install.sh given $case->{label} prints nothing on standard output, so the normal install never started" );
    is_deeply( [ _log_lines($log) ], [], "install.sh given $case->{label} calls no package manager, perlbrew, cpanm or d2" );
    my @written = grep { -e File::Spec->catfile( $home, $_ ) } qw(.bashrc .profile .bash_profile .zshrc .zprofile perl5 .developer-dashboard);
    is_deeply( \@written, [], "install.sh given $case->{label} writes no shell rc file and creates nothing under the home directory" );
}

# install.sh --jenkins: the Jenkins test-node route. Every scenario runs
# against fake tools only (see _seed_fake_jenkins_commands), so nothing is
# downloaded, built or installed for real.
my @jenkins_list     = _plain_lines( File::Spec->catfile( $root, 'share', 'jenkins', 'modules-unix.txt' ) );
my @jenkins_compiled = _plain_lines( File::Spec->catfile( $root, 'share', 'jenkins', 'modules-compiled.txt' ) );
my @jenkins_rc_names = qw(.bashrc .profile .bash_profile .zshrc .zprofile .developer-dashboard);
my $jenkins_install_prefix = 'cpanm --no-wget --notest --mirror https://cpan.metacpan.org --mirror https://backpan.perl.org ';

{
    my $home     = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log      = File::Spec->catfile( $fake_bin, 'install.log' );
    _seed_fake_install_commands( fake_bin => $fake_bin, log => $log );
    _seed_fake_jenkins_commands( fake_bin => $fake_bin, log => $log, perlbrew_on_path => 1 );
    my $env_prefix = _jenkins_env_prefix(
        HOME                       => $home,
        PATH                       => _msys_path($fake_bin) . ':' . _base_path(),
        DD_INSTALL_OS_OVERRIDE     => 'debian',
        DD_INSTALL_DEBIAN_VERSION_ID => '13',
    );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh' --jenkins");
    };
    is( $exit >> 8, 0, 'install.sh --jenkins succeeds on a Debian-family host with fake tools' )
      or diag $stdout . $stderr;
    like( $stdout, qr/^install\.sh --jenkins: DONE\. /m, 'install.sh --jenkins ends with one clear DONE line on a Debian-family host' );
    unlike( $stderr, qr/FAILED/, 'install.sh --jenkins prints no FAILED line when it finishes' );

    my @log_lines = _log_lines($log);
    is(
        scalar( grep { $_ eq 'perlbrew install perl-5.38.2 --notest -j 6' } @log_lines ),
        1,
        'install.sh --jenkins asks perlbrew for perl-5.38.2 with -j from the CPU count',
    );
    ok(
        scalar( grep { m{\Acurl -fsSL https://install\.perlbrew\.pl -o \S+/jenkins-perlbrew-install\.sh\z} } @log_lines )
          && scalar( grep { m{\A/bin/bash \S+/jenkins-perlbrew-install\.sh\z} } @log_lines ),
        'install.sh --jenkins installs its own perlbrew from the installer even when a perlbrew is already on PATH',
    );
    ok(
        scalar( grep { $_ eq 'perl -e exit($] == 5.038002 ? 0 : 1)' } @log_lines ),
        'install.sh --jenkins asks the built Perl whether it is exactly 5.38.2',
    );
    ok(
        scalar( grep { m{\Acurl -fsSL https://cpanmin\.us -o \S+/jenkins-cpanm-bootstrap\.pl\z} } @log_lines ),
        'install.sh --jenkins downloads the cpanm bootstrap to a file instead of piping it',
    );
    ok(
        scalar( grep { m{\Aperl \S+/jenkins-cpanm-bootstrap\.pl --notest App::cpanminus\@1\.7049\z} } @log_lines ),
        'install.sh --jenkins installs cpanm 1.7049 with the built Perl',
    );
    is_deeply(
        [ grep { index( $_, 'cpanm --no-wget --notest ' ) == 0 } @log_lines ],
        [ map { $jenkins_install_prefix . $_ } @jenkins_list ],
        'install.sh --jenkins calls cpanm --notest once for each line of the pinned list, in list order',
    );
    is_deeply(
        [ grep { index( $_, 'cpanm --no-wget --test-only ' ) == 0 } @log_lines ],
        [ map { 'cpanm --no-wget --test-only ' . $_ } @jenkins_compiled ],
        'install.sh --jenkins runs the own tests of each compiled distribution, in list order',
    );
    is_deeply(
        [ grep { index( $_, 'cpanm --no-wget --uninstall ' ) == 0 } @log_lines ],
        [ map { 'cpanm --no-wget --uninstall -f ' . $_ } qw(Test::LeakTrace Test::Requires Test::Warnings Test::Fatal B::COW) ],
        'install.sh --jenkins removes the test-only helpers the compiled tests pull in',
    );
    ok(
        scalar( grep { m{\Aapt-get install -y build-essential ca-certificates curl git libcrypt-dev libexpat1-dev libssl-dev pkg-config zlib1g-dev openjdk-21-jre-headless make\z} } @log_lines ),
        'install.sh --jenkins installs the small package set, Java 21 and make on a Debian-family host, not the full manifest',
    );
    is_deeply(
        [ grep { m{\Aapt-get install -y .*?(?:cpanminus|perlbrew|nodejs|npm|perl|tmux)(?:\s|\z)} } @log_lines ],
        [],
        'install.sh --jenkins installs no manifest extra on a Debian-family host: no cpanminus, perlbrew, nodejs, npm, perl or tmux',
    );
    is_deeply(
        [ grep { m{\A(?:d2 |cpanm .*local::lib|cpanm .* \.\z)} } @log_lines ],
        [],
        'install.sh --jenkins does not install or initialise the dashboard',
    );
    is_deeply(
        [ grep { -e File::Spec->catfile( $home, $_ ) } @jenkins_rc_names ],
        [],
        'install.sh --jenkins writes no shell rc file and no dashboard runtime',
    );
    is_deeply(
        [ grep { m{\A(?:sudo -n )?(?:systemsetup|pmset|sntp) } } @log_lines ],
        [],
        'install.sh --jenkins leaves the macOS-only settings step out on a Debian-family host',
    );
    ok( -d File::Spec->catdir( $home, 'jenkins' ), 'install.sh --jenkins creates the agent remote root under the home directory' );

    my $first_run_lines = scalar @log_lines;
    my ( $stdout_again, $stderr_again, $exit_again ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh' --jenkins");
    };
    is( $exit_again >> 8, 0, 'install.sh --jenkins succeeds again on a finished node' )
      or diag $stdout_again . $stderr_again;
    like( $stdout_again, qr/^install\.sh --jenkins: DONE\. /m, 'install.sh --jenkins still ends DONE on a finished node' );
    my @second_run = _log_lines($log);
    splice @second_run, 0, $first_run_lines;
    is_deeply(
        [ grep { m{\A(?:perlbrew install |perl \S+jenkins-cpanm-bootstrap|cpanm --no-wget --(?:notest|test-only|uninstall) )} } @second_run ],
        [],
        'install.sh --jenkins builds, installs and tests nothing a second time on a finished node',
    );
    is_deeply(
        [ grep { $_ =~ /install\.perlbrew\.pl/ } @second_run ],
        [],
        'install.sh --jenkins does not download the perlbrew installer a second time on a finished node',
    );
}

{
    my $home     = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log      = File::Spec->catfile( $fake_bin, 'install.log' );
    _seed_fake_install_commands( fake_bin => $fake_bin, log => $log, fake_perlbrew_on_path => 0 );
    _seed_fake_jenkins_commands( fake_bin => $fake_bin, log => $log, perlbrew_on_path => 0 );
    my $env_prefix = _jenkins_env_prefix(
        HOME                   => $home,
        PATH                   => _msys_path($fake_bin) . ':' . _path_hiding_command('perlbrew'),
        DD_INSTALL_OS_OVERRIDE => 'darwin',
    );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh' --jenkins");
    };
    is( $exit >> 8, 0, 'install.sh --jenkins succeeds on a macOS host with fake tools' )
      or diag $stdout . $stderr;
    like( $stdout, qr/^install\.sh --jenkins: DONE\. /m, 'install.sh --jenkins ends with one clear DONE line on a macOS host' );

    my @log_lines = _log_lines($log);
    is_deeply(
        [ grep { m{\A(?:systemsetup|pmset|sntp) } } @log_lines ],
        [
            'systemsetup -setnetworktimeserver time.apple.com',
            'systemsetup -setusingnetworktime on',
            'pmset -a powernap 0 sleep 0 disksleep 0 displaysleep 0 standby 0 hibernatemode 0 autopoweroff 0',
            'sntp -sS time.apple.com',
        ],
        'install.sh --jenkins runs the time-server and no-sleep settings step on a macOS host',
    );
    ok(
        scalar( grep { $_ eq 'brew install curl expat git pkgconf openjdk@21 openssl@3 make' } @log_lines ),
        'install.sh --jenkins installs the small package set, Java 21, OpenSSL 3 and make on a macOS host, not the full manifest',
    );
    is_deeply(
        [ grep { m{\Abrew install .*?(?:cpanminus|node|perl|tmux)(?:\s|\z)} } @log_lines ],
        [],
        'install.sh --jenkins installs no manifest extra on a macOS host: no cpanminus, node, perl or tmux',
    );
    ok(
        scalar( grep { m{\Acurl -fsSL https://install\.perlbrew\.pl -o \S+/jenkins-perlbrew-install\.sh\z} } @log_lines )
          && scalar( grep { m{\A/bin/bash \S+/jenkins-perlbrew-install\.sh\z} } @log_lines ),
        'install.sh --jenkins downloads the perlbrew installer to a file and runs it when perlbrew is missing',
    );
    is(
        scalar( grep { $_ eq 'perlbrew install perl-5.38.2 --notest -j 6' } @log_lines ),
        1,
        'install.sh --jenkins builds perl-5.38.2 with the perlbrew it installed under the home directory, with -j from the CPU count',
    );
    ok(
        scalar( grep { $_ eq 'brew --prefix openssl@3' } @log_lines ),
        'install.sh --jenkins points native builds at Homebrew openssl@3 on a macOS host',
    );
    is_deeply(
        [ grep { index( $_, 'cpanm --no-wget --notest ' ) == 0 } @log_lines ],
        [ map { $jenkins_install_prefix . $_ } @jenkins_list ],
        'install.sh --jenkins installs the whole pinned list in list order on a macOS host',
    );
    is_deeply(
        [ ( grep { -e File::Spec->catfile( $home, $_ ) } @jenkins_rc_names ), ( grep { m{\Ad2 } } @log_lines ) ],
        [],
        'install.sh --jenkins writes no shell rc file and never calls d2 on a macOS host',
    );
}

{
    # The --jenkins route creates its work folder under TMPDIR, so a
    # TMPDIR that holds a space must not break it.
    my $home     = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log      = File::Spec->catfile( $fake_bin, 'install.log' );
    _seed_fake_install_commands( fake_bin => $fake_bin, log => $log );
    _seed_fake_jenkins_commands( fake_bin => $fake_bin, log => $log, perlbrew_on_path => 1 );
    my $spaced_tmp = File::Spec->catdir( $home, 'with space' );
    make_path($spaced_tmp);
    my $env_prefix = _jenkins_env_prefix(
        HOME                       => $home,
        TMPDIR                     => $spaced_tmp,
        PATH                       => _msys_path($fake_bin) . ':' . _base_path(),
        DD_INSTALL_OS_OVERRIDE     => 'debian',
        DD_INSTALL_DEBIAN_VERSION_ID => '13',
    );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh' --jenkins");
    };
    is( $exit >> 8, 0, 'install.sh --jenkins succeeds when TMPDIR holds a space' )
      or diag $stdout . $stderr;
    like( $stdout, qr/^install\.sh --jenkins: DONE\. /m, 'install.sh --jenkins ends with one clear DONE line when TMPDIR holds a space' );
    ok(
        scalar( grep { $_ eq 'perlbrew install perl-5.38.2 --notest -j 6' } _log_lines($log) ),
        'install.sh --jenkins runs the whole route through a TMPDIR that holds a space',
    );
}

for my $case (
    {
        label    => 'a built Perl that is not 5.38.2',
        platform => 'debian',
        extra    => [ FAKE_JENKINS_PERL_WRONG => '1', DD_INSTALL_DEBIAN_VERSION_ID => '13' ],
        stderr   => qr/is not Perl 5\.38\.2; refusing to go on/,
        installs => 0,
    },
    {
        label    => 'a pinned distribution that fails to build',
        platform => 'debian',
        extra    => [ FAKE_JENKINS_CPANM_FAILS_ON => $jenkins_list[2], DD_INSTALL_DEBIAN_VERSION_ID => '13' ],
        stderr   => qr/Unable to install pinned distribution \Q$jenkins_list[2]\E/,
        installs => 3,
    },
    {
        label    => 'Debian 12',
        platform => 'debian',
        extra    => [ DD_INSTALL_DEBIAN_VERSION_ID => '12' ],
        stderr   => qr/install\.sh --jenkins supports Debian 13 and later; this machine is Debian 12\./,
        installs => 0,
        untouched => 1,
    },
    {
        label    => 'a platform it does not support',
        platform => 'fedora',
        extra    => [],
        stderr   => qr/install\.sh --jenkins supports macOS, Debian and Ubuntu only; this machine is 'fedora'\./,
        installs => 0,
        untouched => 1,
    },
  )
{
    my $home     = tempdir( CLEANUP => 1 );
    my $fake_bin = tempdir( CLEANUP => 1 );
    my $log      = File::Spec->catfile( $fake_bin, 'install.log' );
    _seed_fake_install_commands( fake_bin => $fake_bin, log => $log );
    _seed_fake_jenkins_commands( fake_bin => $fake_bin, log => $log, perlbrew_on_path => 1 );
    my $env_prefix = _jenkins_env_prefix(
        HOME                   => $home,
        PATH                   => _msys_path($fake_bin) . ':' . _base_path(),
        DD_INSTALL_OS_OVERRIDE => $case->{platform},
        @{ $case->{extra} },
    );

    my ( $stdout, $stderr, $exit ) = capture {
        _sh_c("$env_prefix '$install_sh_for_sh' --jenkins");
    };
    is( $exit >> 8, 1, "install.sh --jenkins refuses to go on with $case->{label}" )
      or diag $stdout . $stderr;
    like( $stderr, $case->{stderr}, "install.sh --jenkins says why it stopped with $case->{label}" );
    like( $stderr, qr/^install\.sh --jenkins: FAILED \(exit 1\)\./m, "install.sh --jenkins ends with one clear FAILED line with $case->{label}" );
    unlike( $stdout, qr/DONE/, "install.sh --jenkins prints no DONE line with $case->{label}" );
    my @log_lines = _log_lines($log);
    is(
        scalar( grep { index( $_, 'cpanm --no-wget --notest ' ) == 0 } @log_lines ),
        $case->{installs},
        "install.sh --jenkins makes $case->{installs} pinned install calls with $case->{label}",
    );
    if ( $case->{untouched} ) {
        is_deeply( \@log_lines, [], "install.sh --jenkins calls no tool at all with $case->{label}" );
        is_deeply(
            [ grep { -e File::Spec->catfile( $home, $_ ) } @jenkins_rc_names, 'perl5', 'jenkins' ],
            [],
            "install.sh --jenkins creates nothing under the home directory with $case->{label}",
        );
    }
}

{
    my $install_sh_text = _slurp($install_sh);
    my ($jenkins_build_jobs) = $install_sh_text =~ /(jenkins_build_jobs\(\) \{.*?\n\})/s;
    ok( defined $jenkins_build_jobs, 'install.sh defines jenkins_build_jobs for the --jenkins route' );
    like(
        $jenkins_build_jobs,
        qr/printf '\%s\\n' '4'/,
        'install.sh --jenkins falls back to 4 build jobs when the CPU count cannot be read',
    );
    my ($jenkins_ensure_perlbrew) = $install_sh_text =~ /(jenkins_ensure_perlbrew\(\) \{.*?\n\})/s;
    ok( defined $jenkins_ensure_perlbrew, 'install.sh defines jenkins_ensure_perlbrew for the --jenkins route' );
    unlike(
        $jenkins_ensure_perlbrew,
        qr/command -v perlbrew/,
        'install.sh --jenkins never takes a perlbrew from PATH; it only uses the one under the home directory',
    );
}

# jenkins_dist_installed and jenkins_installed_pathnames: the two .meta
# readers in install.sh. Real cpanm writes install.json with no trailing
# newline, so the read-back must take one pathname per file: catting them
# all together merges them into one line and a single sed pass keeps only
# the last pathname (R84: the fresh-node proof found 1 of 119, podlators).
# The layout differs between machines, so both .meta locations are read:
# directly under the site folder and under the arch folder. A distribution
# recorded in both places is counted once by the final check (sort -u).
{
    my $install_sh_text = _slurp($install_sh);
    my ($dist_installed) = $install_sh_text =~ /(jenkins_dist_installed\(\) \{.*?\n\})/s;
    my ($pathnames) = $install_sh_text =~ /(jenkins_installed_pathnames\(\) \{.*?\n\})/s;
    ok( defined $dist_installed, 'install.sh defines jenkins_dist_installed for the --jenkins route' );
    ok( defined $pathnames, 'install.sh defines jenkins_installed_pathnames for the --jenkins route' );
    if ( defined $dist_installed && defined $pathnames ) {
        my $dir  = tempdir( CLEANUP => 1 );
        my $site = File::Spec->catdir( $dir, 'site_perl', '5.38.2' );
        # Each install.json is written with NO trailing newline, exactly
        # as the real cpanm writes it; a newline here would hide the
        # read-back merging the files into one line.
        my $write_meta = sub {
            my ( $base, $dist, $pathname ) = @_;
            my $meta_dir = File::Spec->catdir( $base, '.meta', $dist );
            make_path($meta_dir);
            my $path = File::Spec->catfile( $meta_dir, 'install.json' );
            open my $fh, '>', $path or die "Unable to write $path: $!";
            binmode $fh;
            print {$fh} qq|{"dist":"$dist","pathname":"$pathname"}|;
            close $fh or die "Unable to close $path: $!";
        };
        $write_meta->( $site, 'DistA-1.00', 'A/AA/AUTHOR/DistA-1.00.tar.gz' );
        $write_meta->( File::Spec->catdir( $site, 'fake-arch' ), 'DistB-2.00', 'B/BB/AUTHOR/DistB-2.00.tar.gz' );
        $write_meta->( $site, 'Podlators-1.00', 'P/PO/AUTHOR/Podlators-1.00.tar.gz' );
        $write_meta->( File::Spec->catdir( $site, 'fake-arch' ), 'Podlators-1.00', 'P/PO/AUTHOR/Podlators-1.00.tar.gz' );
        my $spaced_site = File::Spec->catdir( $dir, 'site with space', '5.38.2' );
        $write_meta->( $spaced_site, 'DistC-3.00', 'C/CC/AUTHOR/DistC-3.00.tar.gz' );

        my $func_file = File::Spec->catfile( $dir, 'jenkins-meta-funcs.sh' );
        open my $ffh, '>', $func_file or die "Unable to write $func_file: $!";
        binmode $ffh;
        print {$ffh} $dist_installed, "\n", $pathnames, "\n";
        close $ffh or die "Unable to close $func_file: $!";

        my $run_meta = sub {
            my ( $site_dir, $snippet ) = @_;
            # PATH holds _base_path() so grep and sed are found on Windows,
            # where they live only in Git's /usr/bin; off Windows it is the
            # caller's PATH, so this is a no-op there.
            my $command = sprintf q{PATH='%s'; . '%s'; JENKINS_SITE_DIR='%s'; %s},
              _base_path(), _msys_path($func_file), _msys_path($site_dir), $snippet;
            return capture { _sh_c($command) };
        };
        my $check_installed = sub {
            my ( $site_dir, $pathname ) = @_;
            return $run_meta->(
                $site_dir,
                sprintf q{jenkins_dist_installed '%s'; rc=$?; if [ "$rc" -eq 0 ]; then echo INSTALLED; else echo "MISSING rc=$rc"; fi},
                $pathname,
            );
        };

        my ( $out, $err );
        ( $out, $err ) = $check_installed->( $site, 'A/AA/AUTHOR/DistA-1.00.tar.gz' );
        like( $out, qr/^INSTALLED$/m, 'jenkins_dist_installed finds a distribution recorded directly under the site folder' );
        ( $out, $err ) = $check_installed->( $site, 'B/BB/AUTHOR/DistB-2.00.tar.gz' );
        like( $out, qr/^INSTALLED$/m, 'jenkins_dist_installed finds a distribution recorded under the arch folder' );
        ( $out, $err ) = $check_installed->( $site, 'Z/ZZ/AUTHOR/DistZ-9.00.tar.gz' );
        like( $out, qr/^MISSING rc=1$/m, 'jenkins_dist_installed reports a distribution with no record as missing' );
        ( $out, $err ) = $check_installed->( File::Spec->catdir( $dir, 'no-such-site' ), 'A/AA/AUTHOR/DistA-1.00.tar.gz' );
        like( $out, qr/^MISSING rc=1$/m, 'jenkins_dist_installed reports missing when the site folder does not exist, and never lets the glob stay literal' );
        my $empty_site = File::Spec->catdir( $dir, 'empty-site', '5.38.2' );
        make_path($empty_site);
        ( $out, $err ) = $check_installed->( $empty_site, 'A/AA/AUTHOR/DistA-1.00.tar.gz' );
        like( $out, qr/^MISSING rc=1$/m, 'jenkins_dist_installed reports missing when the site folder holds no .meta entries' );
        ( $out, $err ) = $check_installed->( $spaced_site, 'C/CC/AUTHOR/DistC-3.00.tar.gz' );
        like( $out, qr/^INSTALLED$/m, 'jenkins_dist_installed finds a distribution when the site path holds a space' );

        # R90: one grep per call, not one per file. The pinned list calls
        # this once per distribution, so a per-file grep is 7,021 grep
        # invocations for 119 distributions. A counting fake grep proves
        # the rewrite greps all four install.json files in one invocation:
        # the missing distribution is asked for, so every file is scanned.
        my $fake_bin = File::Spec->catdir( $dir, 'counting-grep-bin' );
        make_path($fake_bin);
        my $count_file = File::Spec->catfile( $dir, 'grep-count.txt' );
        my ( $real_grep_out, undef, $real_grep_status ) = capture { _sh_c( sprintf q{PATH='%s'; command -v grep}, _base_path() ) };
        $real_grep_out =~ s/\s+\z//;
        ok( $real_grep_status == 0 && $real_grep_out ne '', 'a real grep is on PATH for the counting fake' );
        if ( $real_grep_status == 0 && $real_grep_out ne '' ) {
            _write_executable(
                File::Spec->catfile( $fake_bin, 'grep' ),
                "#!/bin/sh\nprintf '%s\\n' \"grep \$*\" >> \"\$GREP_COUNT_FILE\"\nexec \"\$REAL_GREP\" \"\$\@\"\n",
            );
            # REAL_GREP and GREP_COUNT_FILE are exported: the fake grep is a
            # child process, and a plain assignment never reaches it. PATH
            # holds the counting fake bin plus _base_path(), the way the
            # scenario commands build it, so grep is found on Windows too.
            my $count_command = sprintf q{PATH='%s'; export REAL_GREP='%s' GREP_COUNT_FILE='%s'; . '%s'; JENKINS_SITE_DIR='%s'; jenkins_dist_installed '%s'; echo "rc=$?"},
              _msys_path($fake_bin) . ':' . _base_path(), _msys_path($real_grep_out), _msys_path($count_file), _msys_path($func_file), _msys_path($site), 'Z/ZZ/AUTHOR/DistZ-9.00.tar.gz';
            ( $out, $err ) = capture { _sh_c($count_command) };
            like( $out, qr/^rc=1$/m, 'jenkins_dist_installed still reports a distribution with no record as missing when grep is counted' );
            my $grep_calls = -f $count_file ? scalar( split /\n/, _slurp($count_file) ) : 0;
            is( $grep_calls, 1, 'jenkins_dist_installed runs one grep per call over all four install.json files, not one per file' );
        }

        ( $out, $err ) = $run_meta->( $site, q{jenkins_installed_pathnames} );
        is_deeply(
            [ sort split /\n/, $out ],
            [
                'A/AA/AUTHOR/DistA-1.00.tar.gz',
                'B/BB/AUTHOR/DistB-2.00.tar.gz',
                'P/PO/AUTHOR/Podlators-1.00.tar.gz',
                'P/PO/AUTHOR/Podlators-1.00.tar.gz',
            ],
            'jenkins_installed_pathnames lists every pathname from install.json files with no trailing newlines, from both .meta locations',
        );
        ( $out, $err ) = $run_meta->( $site, q{jenkins_installed_pathnames | LC_ALL=C sort -u} );
        is_deeply(
            [ split /\n/, $out ],
            [
                'A/AA/AUTHOR/DistA-1.00.tar.gz',
                'B/BB/AUTHOR/DistB-2.00.tar.gz',
                'P/PO/AUTHOR/Podlators-1.00.tar.gz',
            ],
            'jenkins_installed_pathnames piped through sort -u counts a distribution recorded in both places once',
        );
        ( $out, $err ) = $run_meta->( File::Spec->catdir( $dir, 'no-such-site' ), q{jenkins_installed_pathnames; echo "rc=$?"} );
        is( $out, "rc=0\n", 'jenkins_installed_pathnames lists nothing when the site folder does not exist' );
    }
}

# jenkins_java_command: on macOS the Java path comes from brew --prefix,
# and a failed lookup must fail fast with an actionable message instead of
# silently becoming /bin/java (R86: the second Q review on PR #93).
{
    my $install_sh_text = _slurp($install_sh);
    my ($java_command) = $install_sh_text =~ /(jenkins_java_command\(\) \{.*?\n\})/s;
    ok( defined $java_command, 'install.sh defines jenkins_java_command for the --jenkins route' );
    like(
        $install_sh_text,
        qr/jenkins_java=\$\(jenkins_java_command\) \|\|\s+fail "Java \$JENKINS_JAVA_MAJOR was not found"/,
        'install.sh --jenkins fails the final check when the Java command cannot be found',
    );
    if ( defined $java_command ) {
        my $dir      = tempdir( CLEANUP => 1 );
        my $good_dir = File::Spec->catdir( $dir, 'fake-homebrew', 'opt', 'openjdk@21' );
        make_path($good_dir);
        my $fake_bin = File::Spec->catdir( $dir, 'fake-bin' );
        make_path($fake_bin);
        # The fake brew answers --prefix from an environment variable, so
        # each case below can say what the lookup found: nothing, a path
        # that is not a directory, or a real directory.
        _write_executable(
            File::Spec->catfile( $fake_bin, 'brew' ),
            "#!/bin/sh\nprintf '%s\\n' \"\$FAKE_BREW_PREFIX\"\nexit \${FAKE_BREW_EXIT:-0}\n",
        );

        my $func_file = File::Spec->catfile( $dir, 'jenkins-java-func.sh' );
        open my $ffh, '>', $func_file or die "Unable to write $func_file: $!";
        binmode $ffh;
        print {$ffh} $java_command, "\n";
        close $ffh or die "Unable to close $func_file: $!";

        my $run_java = sub {
            my ( $prefix, $brew_exit ) = @_;
            # FAKE_BREW_PREFIX and FAKE_BREW_EXIT are exported: the fake
            # brew is a child process, and a plain assignment never
            # reaches it.
            my $command = sprintf q{PATH='%s':"$PATH"; PLATFORM='darwin'; JENKINS_JAVA_MAJOR='21'; export FAKE_BREW_PREFIX='%s' FAKE_BREW_EXIT='%s'; . '%s'; jenkins_java_command},
              _msys_path($fake_bin), $prefix, $brew_exit, _msys_path($func_file);
            return capture { _sh_c($command) };
        };

        my ( $out, $err, $exit );
        ( $out, $err, $exit ) = $run_java->( '', 0 );
        is( $exit >> 8, 1, 'jenkins_java_command fails when brew --prefix finds nothing' );
        like( $err, qr/Homebrew openjdk\@21 was not found; install it with 'brew install openjdk\@21'/, 'jenkins_java_command says how to install Java when brew --prefix finds nothing' );
        is( $out, '', 'jenkins_java_command prints no Java path when brew --prefix finds nothing' );
        ( $out, $err, $exit ) = $run_java->( File::Spec->catdir( $dir, 'no-such-prefix' ), 0 );
        is( $exit >> 8, 1, 'jenkins_java_command fails when the brew prefix is not a directory' );
        like( $err, qr/is not a directory; reinstall it with 'brew reinstall openjdk\@21'/, 'jenkins_java_command says how to repair Java when the brew prefix is not a directory' );
        ( $out, $err, $exit ) = $run_java->( _msys_path($good_dir), 0 );
        is( $exit >> 8, 0, 'jenkins_java_command succeeds when brew --prefix names a real directory' );
        is( $out, _native_spelling( _msys_path($good_dir) . "/bin/java\n" ), 'jenkins_java_command prints the Java path under the brew prefix' );

        # On a non-macOS platform the Java path comes from PATH, and a
        # missing java must fail fast instead of printing the literal
        # string 'java' and letting the final check fail later (R93: the
        # fourth Q review on PR #93). 'debian' is a supported --jenkins
        # platform that takes the non-macOS branch.
        my $fake_bin_no_java = File::Spec->catdir( $dir, 'fake-bin-no-java' );
        make_path($fake_bin_no_java);
        my $fake_bin_with_java = File::Spec->catdir( $dir, 'fake-bin-with-java' );
        make_path($fake_bin_with_java);
        # The fake java only needs to be found by 'command -v'; it never runs.
        _write_executable(
            File::Spec->catfile( $fake_bin_with_java, 'java' ),
            "#!/bin/sh\nexit 0\n",
        );

        my $run_java_nondarwin = sub {
            my ($java_bin) = @_;
            # PATH holds only the fake bin here: _base_path() is left out
            # on purpose, because on Unix it is the caller's PATH, which
            # holds a real java and would defeat the absent case. The
            # function needs nothing from PATH but the java it looks for.
            my $command = sprintf q{PATH='%s'; PLATFORM='debian'; JENKINS_JAVA_MAJOR='21'; . '%s'; jenkins_java_command},
              _msys_path($java_bin), _msys_path($func_file);
            return capture { _sh_c($command) };
        };

        ( $out, $err, $exit ) = $run_java_nondarwin->($fake_bin_no_java);
        is( $exit >> 8, 1, 'jenkins_java_command fails when java is absent from PATH on a non-macOS platform' );
        is( $out, '', 'jenkins_java_command prints no Java path when java is absent from PATH on a non-macOS platform' );
        ( $out, $err, $exit ) = $run_java_nondarwin->($fake_bin_with_java);
        is( $exit >> 8, 0, 'jenkins_java_command succeeds when java is on PATH on a non-macOS platform' );
        is( $out, _native_spelling( _msys_path($fake_bin_with_java) . "/java\n" ), 'jenkins_java_command prints the Java path from PATH on a non-macOS platform' );
    }
}

{
    my @public_files = (
        $install_sh,
        map { File::Spec->catfile( $root, 'share', 'jenkins', $_ ) }
          qw(modules-unix.txt modules-compiled.txt modules-windows.txt modules-compiled-windows.txt),
    );
    my ( @addresses, @home_paths );
    for my $file (@public_files) {
        my $number = 0;
        for my $line ( split /\n/, _raw_text($file) ) {
            $number++;
            push @addresses,  "$file line $number" if $line =~ /(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])/;
            push @home_paths, "$file line $number" if $line =~ m{/(?:Users|home)/[A-Za-z0-9_]};
        }
    }
    is_deeply( \@addresses,  [], 'install.sh and the Jenkins lists hold no IP address' );
    is_deeply( \@home_paths, [], 'install.sh and the Jenkins lists hold no /Users/<name> or /home/<name> path' );
}

# install.ps1 -Jenkins: the Jenkins test-node route for Windows. These are
# text reads of install.ps1, the same way the rest of install.ps1 is
# checked in this file, so they run the same on every platform and start
# no PowerShell anywhere.
{
    my $install_ps_raw = _raw_text($install_ps);
    my ( $before_route, $route, $after_route ) =
      $install_ps_raw =~ /\A(.*)^# >>> Jenkins test-node route >>>\r?\n(.*)^# <<< Jenkins test-node route <<<\r?\n(.*)\z/ms;
    ok( defined $route, 'install.ps1 keeps the Jenkins test-node route between its two marker lines' );
    $_ = defined $_ ? $_ : '' for $before_route, $route, $after_route;
    my $normal_path = $before_route . $after_route;

    like( $route, qr/\[string\]\$argument -ieq '-Jenkins'/, 'install.ps1 takes a -Jenkins switch' );
    like( $route, qr/\$flag = \$env:DD_INSTALL_JENKINS\b.*?\$flag\.Trim\(\) -eq '1'/s, 'install.ps1 takes DD_INSTALL_JENKINS=1 for the piped form' );
    like(
        $route,
        qr/throw "install\.ps1: DD_INSTALL_JENKINS must be 1 or unset, not '\$flag'\. Nothing was installed or changed\."/,
        'install.ps1 refuses any other value of DD_INSTALL_JENKINS before anything is installed',
    );
    unlike( $normal_path, qr/Jenkins/i, 'install.ps1 names Jenkins nowhere outside the Jenkins test-node route' );
    like(
        $route . $after_route,
        qr/^if \(Test-JenkinsRequested -Arguments \$args\) \{\s+Invoke-JenkinsNodeSetup\s+return\s+\}\s+Show-ProgressBoard\s+Set-StepStatus -Id 'detect_profile' -Status 'running'/m,
        'install.ps1 leaves through the Jenkins route before the first step of the normal install',
    );

    like( $route, qr/^\$JenkinsStrawberryRoot = 'C:\\Strawberry'\r?$/m, 'install.ps1 -Jenkins pins Strawberry Perl to C:\\Strawberry' );
    like( $route, qr/^\$JenkinsPerlNumber = '5\.038002'\r?$/m, 'install.ps1 -Jenkins pins Perl to exactly 5.38.2' );
    like(
        $route,
        qr/\$versionCode = 'exit\(\$\] == ' \+ \$JenkinsPerlNumber \+ ' \? 0 : 1\)'.*?throw "\$JenkinsPerlPath is not Perl \$JenkinsPerlShort; refusing to go on"/s,
        'install.ps1 -Jenkins refuses to go on unless the Perl reports exactly the pinned version',
    );
    like( $route, qr/^\$JenkinsStrawberryBuild = '5\.38\.2\.2'\r?$/m, 'install.ps1 -Jenkins pins the Strawberry Perl build' );
    like( $route, qr/^\$JenkinsStrawberryMsiName = 'strawberry-perl-5\.38\.2\.2-64bit\.msi'\r?$/m, 'install.ps1 -Jenkins names the one pinned Strawberry Perl installer' );
    unlike( $route, qr/Resolve-StrawberryPerlMsiUrl|Ensure-WingetPackage|winget/, 'install.ps1 -Jenkins never takes the latest Strawberry Perl and never calls winget' );
    like( $route, qr/refusing to install over it/, 'install.ps1 -Jenkins refuses to install over a folder that is already at the pinned root' );

    like( $route, qr/\$JenkinsJavaMajor = '21'/, 'install.ps1 -Jenkins pins Java to major version 21' );
    like( $route, qr/-match \('version "' \+ \$JenkinsJavaMajor \+ '\\\.'\)/, 'install.ps1 -Jenkins checks what the Java itself reports' );

    like( $route, qr/^\$JenkinsGitVersionFull = '2\.56\.1\.windows\.1'\r?$/m, 'install.ps1 -Jenkins pins Git for Windows to 2.56.1.windows.1' );
    like(
        $route,
        qr/^\$JenkinsGitInstallerUrl = 'https:\/\/github\.com\/git-for-windows\/git\/releases\/download\/v2\.56\.1\.windows\.1\/Git-2\.56\.1-64-bit\.exe'\r?$/m,
        'install.ps1 -Jenkins downloads Git for Windows from the one pinned installer URL',
    );
    unlike( $route, qr/Resolve-GitForWindowsInstallerUrl/, 'install.ps1 -Jenkins never resolves the latest Git for Windows' );
    like(
        $route,
        qr/Install-JenkinsStrawberryPerl\n\s+\$gitPath = Install-JenkinsGit\n\s+\$javaPath = Resolve-JenkinsJavaPath/s,
        'install.ps1 -Jenkins installs Git for Windows right after Strawberry Perl',
    );
    like(
        $route,
        qr/function Resolve-JenkinsGitPath \{.*?if \(Test-JenkinsGitVersion -GitPath \$candidate\) \{\s+return \$candidate\s+\}/s,
        'install.ps1 -Jenkins only accepts a git that reports the pinned version',
    );
    like(
        $route,
        qr/function Resolve-JenkinsGitPath \{.*?if \(-not \[string\]::IsNullOrWhiteSpace\(\$env:ProgramFiles\)\) \{\s+\$defaultGitPath = Join-Path \$env:ProgramFiles 'Git\\cmd\\git\.exe'/s,
        'install.ps1 -Jenkins only adds the default Git candidate when ProgramFiles is set',
    );
    like(
        $route,
        qr/function Install-JenkinsGit \{.*?\$gitPath = Resolve-JenkinsGitPath.*?if \(-not \[string\]::IsNullOrWhiteSpace\(\$gitPath\)\) \{\s+Write-JenkinsLine -Message "Git \$JenkinsGitVersionFull is already installed"\s+return \$gitPath\s+\}/s,
        'install.ps1 -Jenkins skips the Git install when the pinned Git is already there',
    );
    like(
        $route,
        qr/Invoke-InstallerCommand -Label 'Git for Windows pinned installer' -FilePath \$exePath -Arguments \@\('\/VERYSILENT', '\/NORESTART', '\/SUPPRESSMSGBOXES'\)/,
        'install.ps1 -Jenkins installs Git for Windows silently, with no restart',
    );
    like(
        $route,
        qr/return \(\$versionText -match \('git version ' \+ \[Regex\]::Escape\(\$JenkinsGitVersionFull\) \+ '\(\?:\\s\|\$\)'\)\)/,
        'install.ps1 -Jenkins checks git --version against the pinned version exactly',
    );
    unlike(
        $route,
        qr/return \(\$versionText -match \('git version ' \+ \[Regex\]::Escape\(\$JenkinsGitVersionFull\)\)\)/,
        'install.ps1 -Jenkins no longer matches git --version against the pinned version without an end anchor',
    );
    like(
        $route,
        qr/\$isPinnedGit = Test-JenkinsGitVersion -GitPath \$GitPath\s+if \(-not \$isPinnedGit\) \{\s+throw "\$GitPath is not Git \$JenkinsGitVersionFull"\s+\}/,
        'install.ps1 -Jenkins checks in the final check that git reports the pinned version',
    );

    like( $route, qr/Join-Path \$PSScriptRoot 'share\\jenkins'/, 'install.ps1 -Jenkins reads its lists from share\\jenkins beside the script' );
    like( $route, qr/\$pinnedList = \@\(Get-JenkinsListLines -Path \(Join-Path \$listFolder 'modules-windows\.txt'\)\)/, 'install.ps1 -Jenkins reads the pinned list from modules-windows.txt' );
    like( $route, qr/\$compiledList = \@\(Get-JenkinsListLines -Path \(Join-Path \$listFolder 'modules-compiled-windows\.txt'\)\)/, 'install.ps1 -Jenkins reads the compiled list from modules-compiled-windows.txt' );
    ok( -f File::Spec->catfile( $root, 'share', 'jenkins', 'modules-windows.txt' ), 'the Windows pinned list install.ps1 -Jenkins reads is in the repository' );
    ok( -f File::Spec->catfile( $root, 'share', 'jenkins', 'modules-compiled-windows.txt' ), 'the Windows compiled list install.ps1 -Jenkins reads is in the repository' );
    my ($list_pattern) = $route =~ /^\$JenkinsDistributionPattern = '([^']+)'\r?$/m;
    ok( defined $list_pattern, 'install.ps1 -Jenkins holds the shape every list line must have' );
    $list_pattern = '\A(?!)' if !defined $list_pattern;
    is_deeply(
        [
            grep { $_ !~ /$list_pattern/ } map { _plain_lines( File::Spec->catfile( $root, 'share', 'jenkins', $_ ) ) }
              qw(modules-windows.txt modules-compiled-windows.txt)
        ],
        [],
        'every line of the two Windows lists has the shape install.ps1 -Jenkins accepts',
    );
    like(
        $route,
        qr/Get-Content -LiteralPath \$Path \| ForEach-Object \{ \$_.Trim\(\) \}.*?foreach \(\$line in \$lines\) \{\s+if \(\$line -cnotmatch \$JenkinsDistributionPattern\)/s,
        'install.ps1 -Jenkins trims each list line before checking its shape, so a CRLF list still reads',
    );
    like( $route, qr/foreach \(\$distribution in \$Distributions\) \{.*?-Arguments \@\('--notest', \$distribution\)/s, 'install.ps1 -Jenkins installs the pinned list one line at a time, in list order, with --notest' );
    like(
        $route,
        qr/foreach \(\$distribution in \$Distributions\) \{\s+if \(\$installed\.ContainsKey\(\$distribution\)\) \{\s+continue\s+\}/s,
        'install.ps1 -Jenkins skips a pinned distribution that is already installed',
    );
    like( $route, qr/-Arguments \@\('--test-only', \$distribution\)/, 'install.ps1 -Jenkins runs the own tests of the compiled distributions' );
    like(
        $route,
        qr/if \(Test-Path -LiteralPath \$JenkinsTestedStamp\) \{\s+Write-JenkinsLine -Message 'the compiled distributions already passed their own tests'\s+return\s+\}/s,
        'install.ps1 -Jenkins skips the compiled tests when they already passed',
    );
    like( $route, qr/\$JenkinsCpanmPath = Join-Path \$JenkinsStrawberryRoot 'perl\\bin\\cpanm'/, q{install.ps1 -Jenkins starts with Strawberry's own cpanm} );
    like( $route, qr/\$JenkinsSiteCpanmPath = Join-Path \$JenkinsStrawberryRoot 'perl\\site\\bin\\cpanm'/, 'install.ps1 -Jenkins knows where the pinned cpanm lands in the site bin folder' );
    like(
        $route,
        qr/Install-JenkinsPinnedList.*?if \(Test-Path -LiteralPath \$JenkinsSiteCpanmPath -PathType Leaf\) \{\s+\$script:JenkinsCpanmPath = \$JenkinsSiteCpanmPath\s+\}/s,
        'install.ps1 -Jenkins prefers the pinned cpanm from the start when it is already there',
    );
    like(
        $route,
        qr/Invoke-JenkinsCpanm -Label "cpanm --notest \$distribution".*?if \(Test-Path -LiteralPath \$JenkinsSiteCpanmPath -PathType Leaf\) \{\s+\$script:JenkinsCpanmPath = \$JenkinsSiteCpanmPath\s+\}/s,
        'install.ps1 -Jenkins switches to the pinned cpanm after the first line installs it',
    );
    like( $route, qr/'\{0\} \{1\} \{2\} < NUL' -f \('"' \+ \$JenkinsPerlPath \+ '"'\), \('"' \+ \$script:JenkinsCpanmPath \+ '"'\)/, 'install.ps1 -Jenkins runs cpanm with standard input closed' );
    like(
        $route,
        qr/function Invoke-JenkinsCpanm \{.*?\$quotedArguments = \@\(\$Arguments \| ForEach-Object \{ '"' \+ \(\$_\.Replace\('"', '""'\)\) \+ '"' \}\)/s,
        'install.ps1 -Jenkins quotes each cpanm argument on its own, doubling embedded quotes, so an argument holding a space stays one argument',
    );
    like(
        $route,
        qr/function Invoke-JenkinsCpanm \{.*?\$commandLine = \('\{0\} \{1\} \{2\} < NUL' -f \('"' \+ \$JenkinsPerlPath \+ '"'\), \('"' \+ \$script:JenkinsCpanmPath \+ '"'\), \(\$quotedArguments -join ' '\)\)/s,
        'install.ps1 -Jenkins builds the cpanm command line from the quoted paths and quoted arguments with standard input closed',
    );
    unlike(
        $route,
        qr/function Invoke-JenkinsCpanm \{.*?\$commandLine = \('\{0\} \{1\} \{2\} < NUL' -f \$JenkinsPerlPath, \$script:JenkinsCpanmPath, \(\$quotedArguments -join ' '\)\)/s,
        'install.ps1 -Jenkins no longer builds the cpanm command line from bare perl and cpanm paths',
    );
    like(
        $route,
        qr/function Resolve-JenkinsStrawberryMsiUrl \{.*?catch \{\s+\$url = ''\s+\}/s,
        'install.ps1 -Jenkins leaves the release URL empty when the feed entry has no MSI URL',
    );
    like(
        $route,
        qr/function Resolve-JenkinsStrawberryMsiUrl \{.*?catch \{\s+\$url = ''\s+\}\s+if \(\[string\]::IsNullOrWhiteSpace\(\$url\)\) \{\s+continue\s+\}/s,
        'install.ps1 -Jenkins skips a release with no MSI URL, with the check outside the try/catch',
    );
    unlike(
        $route,
        qr/function Resolve-JenkinsStrawberryMsiUrl \{.*?catch \{\s+continue\s+\}/s,
        'install.ps1 -Jenkins no longer hides a continue inside the catch of the MSI URL lookup',
    );
    like( $route, qr/if \(-not \(Test-Path -LiteralPath \$script:JenkinsCpanmPath -PathType Leaf\)\) \{\s+throw "Strawberry's own cpanm is missing at \$JenkinsCpanmPath"/, 'install.ps1 -Jenkins checks Strawberry cpanm through the script-scoped path' );
    like( $route, qr/^\$JenkinsWork = ''\r?$/m, 'install.ps1 -Jenkins starts with an empty work folder' );
    like(
        $route,
        qr/function Invoke-JenkinsNodeSetup \{.*?\$script:JenkinsWork = Join-Path \(\[IO\.Path\]::GetTempPath\(\)\) \('developer-dashboard-jenkins-' \+ \[Guid\]::NewGuid\(\)\.ToString\('N'\)\)/s,
        'install.ps1 -Jenkins creates a unique work folder for each run',
    );
    unlike( $route, qr/Join-Path \(\[IO\.Path\]::GetTempPath\(\)\) 'developer-dashboard-jenkins'/, 'install.ps1 -Jenkins keeps no fixed work folder path' );
    like(
        $route,
        qr/finally \{\s+if \(-not \[string\]::IsNullOrWhiteSpace\(\$JenkinsWork\) -and \(Test-Path -LiteralPath \$JenkinsWork\)\) \{\s+Remove-Item -LiteralPath \$JenkinsWork -Recurse -Force\s+\}/s,
        'install.ps1 -Jenkins deletes the unique work folder at the end, and only when one was created',
    );
    like(
        $route,
        qr/function Get-JenkinsInstalledDistributions \{.*?foreach \(\$siteKey in \@\('sitearchexp', 'sitelibexp'\)\)/s,
        'install.ps1 -Jenkins asks the pinned Perl for both the arch and the pure-Perl site folders',
    );
    like(
        $route,
        qr/function Get-JenkinsInstalledDistributions \{.*?\$metaFolders = \@\(Join-Path \$siteFolder '\.meta'\).*?foreach \(\$subFolder in \@\(Get-ChildItem -LiteralPath \$siteFolder -Directory.*?\$metaFolders \+= Join-Path \$subFolder\.FullName '\.meta'/s,
        'install.ps1 -Jenkins reads .meta under each site folder and under each of its subdirectories, so the sandbox layout is covered where the site folder is the non-arch path and .meta sits only under the arch subdir',
    );
    like(
        $route,
        qr/function Get-JenkinsInstalledDistributions \{.*?foreach \(\$metaFolder in \$metaFolders\) \{\s+if \(Test-Path -LiteralPath \$metaFolder -PathType Container\) \{\s+foreach \(\$record in \@\(Get-ChildItem -LiteralPath \$metaFolder -Recurse -File -Filter 'install\.json'\)\)/s,
        'install.ps1 -Jenkins searches every collected .meta folder for install.json records',
    );
    like(
        $route,
        qr/function Get-JenkinsInstalledDistributions \{.*?throw "Unable to ask \$JenkinsPerlPath for its site folders"/s,
        'install.ps1 -Jenkins refuses to continue when the pinned Perl cannot name its site folders',
    );
    like(
        $route,
        qr/function Get-JenkinsInstalledDistributions \{.*?foreach \(\$siteKey in \@\('sitearchexp', 'sitelibexp'\)\) \{.*?if \(\$LASTEXITCODE -ne 0\) \{\s+throw "Unable to ask \$JenkinsPerlPath for its site folder/s,
        'install.ps1 -Jenkins reads the exit code inside the site-folder loop, so a failed first call is not missed',
    );
    unlike(
        $route,
        qr/function Get-JenkinsInstalledDistributions \{.*?\$siteFolders\.Count -ne 2/s,
        'install.ps1 -Jenkins no longer checks a site-folder count that can never be wrong',
    );
    like(
        $route,
        qr/function Get-JenkinsInstalledDistributions \{.*?if \(\[string\]::IsNullOrWhiteSpace\(\$siteFolders\[0\]\) -or \[string\]::IsNullOrWhiteSpace\(\$siteFolders\[1\]\)\) \{\s+throw "Unable to ask \$JenkinsPerlPath for its site folders"/s,
        'install.ps1 -Jenkins still refuses to continue when the pinned Perl names no site folder',
    );
    unlike( $route, qr/cpanmin\.us|Download-CpanmScript|local-lib/, 'install.ps1 -Jenkins downloads no other cpanm and uses no private install root' );

    is( scalar( () = $route =~ /-Message \("DONE\. This machine is ready to be a Jenkins test node: /g ), 1, 'install.ps1 -Jenkins has one DONE line' );
    is( scalar( () = $route =~ /"install\.ps1 -Jenkins: FAILED \(\{0\}\)\. This machine is not ready to be a Jenkins test node\."/g ), 1, 'install.ps1 -Jenkins has one FAILED line' );
    like( $route, qr/catch \{\s+Write-Host \("install\.ps1 -Jenkins: FAILED .*?\s+throw\s+\}/s, 'install.ps1 -Jenkins fails the run after its FAILED line' );
    like( $route, qr/Assert-JenkinsNodeReady -JavaPath \$javaPath -GitPath \$gitPath -Distributions \$pinnedList -AgentRoot \$agentRoot\s+\$agentRootText = .*?DONE\./s, 'install.ps1 -Jenkins prints DONE only after the final check' );
    like( $route, qr/These pinned distributions are not recorded as installed/, 'install.ps1 -Jenkins checks the installed distributions against the pinned list at the end' );

    unlike(
        $route,
        qr/Resolve-DefaultDashboardCheckout|DefaultBootstrapRepository|CpanTarget|git\s+clone|d2 init|\bshell\s+ps\b|dashboardCommand|d2\.bat/,
        'install.ps1 -Jenkins does not install or initialise the dashboard',
    );
    unlike(
        $route,
        qr/Ensure-ProfileContains|ProfilePath|\$PROFILE|profileBlock|ExecutionPolicy|Developer Dashboard bootstrap/,
        'install.ps1 -Jenkins edits no PowerShell profile and no execution policy',
    );

    my ( @ps_addresses, @ps_user_paths, @ps_user_names );
    my $number = 0;
    for my $line ( split /\n/, $install_ps_raw ) {
        $number++;
        # The pinned Strawberry Perl build has four numbers; it is a
        # version, not an address, so it is taken out before the check.
        ( my $checked = $line ) =~ s/(?<![\d.])5\.38\.2\.2(?![\d.])//g;
        push @ps_addresses,  "line $number" if $checked =~ /(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])/;
        push @ps_user_paths, "line $number" if $line =~ m{[\\/](?:Users|home)[\\/][A-Za-z0-9_]}i;
        push @ps_user_names, "line $number" if $line =~ /WDAGUtilityAccount|\$env:USERNAME\b|\$env:COMPUTERNAME\b/i;
    }
    is_deeply( \@ps_addresses,  [], 'install.ps1 holds no IP address' );
    is_deeply( \@ps_user_paths, [], 'install.ps1 holds no path into one user profile' );
    is_deeply( \@ps_user_names, [], 'install.ps1 names no user and no machine' );
}

done_testing;

# Purpose: build a PATH string in which `command -v $command` genuinely
# fails, for use as a subprocess's PATH when a fixture needs to simulate a
# tool being absent (not merely shadowed by a fake earlier on PATH).
# Input: a command name (e.g. 'perlbrew'). Output: a ':'-joined PATH string
# derived from $ENV{PATH}, with any directory that would resolve that
# command replaced by a shadow directory lacking it (see
# _shadow_dir_without). DD-851.
sub _path_hiding_command {
    my ($command) = @_;
    # On Windows the scenarios run with Git for Windows' /usr/bin as the
    # only real directory (see _base_path); it holds neither brew nor
    # perlbrew, so there is nothing to hide.
    return _base_path() if $^O eq 'MSWin32';
    my @dirs = grep { length } split /:/, ( $ENV{PATH} || '' );
    return join ':', map {
        my $dir       = $_;
        my $candidate = File::Spec->catfile( $dir, $command );
        ( -f $candidate && -x $candidate )
          ? _shadow_dir_without( $dir, $command )
          : $dir;
    } @dirs;
}

# Purpose: build a throwaway directory that mirrors $dir's contents except
# for $hidden_command, via symlinks. Real directories on PATH (e.g. /bin)
# hold both the real command we need to hide and unrelated coreutils
# (dirname, basename, sh, ...) this test still needs for real; symlinking
# everything else keeps every other tool reachable while genuinely hiding
# just the one command from `command -v`.
# Input: a real directory path and the one entry name to omit. Output: the
# path of the new shadow directory (falls back to returning $dir unchanged
# if it cannot be read). DD-851.
sub _shadow_dir_without {
    my ( $dir, $hidden_command ) = @_;
    my $shadow = tempdir( CLEANUP => 1 );
    opendir( my $dh, $dir ) or return $dir;
    for my $entry ( readdir $dh ) {
        next if $entry eq '.' || $entry eq '..' || $entry eq $hidden_command;
        symlink( File::Spec->catfile( $dir, $entry ), File::Spec->catfile( $shadow, $entry ) );
    }
    closedir $dh;
    return $shadow;
}

sub _expected_apt_bootstrap_steps {
    my (%args) = @_;
    my @packages = @{ $args{packages} || [] };
    my @non_node_packages = grep { $_ ne 'nodejs' && $_ ne 'npm' } @packages;
    my @install_lines;
    push @install_lines, 'apt-get install -y ' . join( ' ', @non_node_packages )
      if @non_node_packages;
    push @install_lines, 'apt-get install -y nodejs'
      if grep { $_ eq 'nodejs' } @packages;
    push @install_lines, 'apt-get install -y npm'
      if ( grep { $_ eq 'npm' } @packages ) && !$args{nodejs_provides_npm};
    return (
        'apt-get update',
        @install_lines,
    ) if _shell_runs_as_root();
    return (
        'sudo apt-get update',
        'apt-get update',
        map( { ( "sudo $_", $_ ) } @install_lines ),
    );
}

sub _expected_apk_bootstrap_steps {
    my (%args) = @_;
    my @packages = @{ $args{packages} || [] };
    my $install_line = 'apk add --no-cache ' . join( ' ', @packages );
    return ($install_line) if _shell_runs_as_root();
    return (
        "sudo $install_line",
        $install_line,
    );
}

sub _expected_dnf_bootstrap_steps {
    my (%args) = @_;
    my @packages = @{ $args{packages} || [] };
    my $install_line = 'dnf install -y ' . join( ' ', @packages );
    return ($install_line) if _shell_runs_as_root();
    return (
        "sudo $install_line",
        $install_line,
    );
}

sub _manifest_lines {
    my ($path) = @_;
    my $text = _slurp($path);
    return grep { defined && $_ ne '' }
      map {
        s/\s+#.*$//r =~ s/^\s+|\s+$//gr
      }
      grep { $_ !~ /^\s*(?:#|$)/ }
      split /\n/, $text;
}

sub _seed_fake_install_commands {
    my (%args) = @_;
    my $fake_bin = $args{fake_bin};
    my $log      = $args{log};
    my $node_marker = File::Spec->catfile( $fake_bin, 'node-toolchain.marker' );
    my $fake_brew_on_path = exists $args{fake_brew_on_path} ? $args{fake_brew_on_path} : 1;
    my $fake_perlbrew_on_path = exists $args{fake_perlbrew_on_path} ? $args{fake_perlbrew_on_path} : 1;
    my $fake_cpanm_installs_local_perlbrew = $args{fake_cpanm_installs_local_perlbrew} ? 1 : 0;
    make_path($fake_bin);

    _write_executable(
        File::Spec->catfile( $fake_bin, 'sudo' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "sudo \$*" >> "$log"
exec "\$@"
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'apt-get' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "apt-get \$*" >> "$log"
append_marker() {
tool=\$1
grep -qx "\$tool" "$node_marker" 2>/dev/null || printf '%s\\n' "\$tool" >> "$node_marker"
}
if [ "\$1" = "install" ]; then
case " \$* " in
  *" nodejs "*)
    append_marker node
    if [ "\${FAKE_NODEJS_PROVIDES_NPM:-0}" = "1" ]; then
      append_marker npm
      append_marker npx
    fi
    ;;
esac
case " \$* " in
  *" npm "*)
    if [ "\${FAKE_NPM_PACKAGE_CONFLICTS:-0}" = "1" ]; then
      printf '%s\\n' 'E: nodejs conflicts with npm' >&2
      exit 1
    fi
    append_marker npm
    append_marker npx
    ;;
esac
fi
exit 0
SH
    );
    my $brew_script = <<"SH";
#!/bin/sh
printf '%s\\n' "brew \$*" >> "$log"
if [ "\$1" = "install" ] && printf '%s ' "\$@" | grep -q ' node '; then
grep -qx 'node' "$node_marker" 2>/dev/null || printf '%s\\n' 'node' >> "$node_marker"
grep -qx 'npm' "$node_marker" 2>/dev/null || printf '%s\\n' 'npm' >> "$node_marker"
grep -qx 'npx' "$node_marker" 2>/dev/null || printf '%s\\n' 'npx' >> "$node_marker"
fi
if [ "\$1" = "--prefix" ] && [ "\$2" = "perl" ]; then
  printf '%s\\n' "\$HOME/.homebrew/opt/perl"
fi
exit 0
SH
    _write_executable(
        File::Spec->catfile( $fake_bin, 'bash' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "/bin/bash \$*" >> "$log"
if [ "\$1" = "-c" ] && printf '%s' "\$2" | grep -q 'developer-dashboard-homebrew-install.sh'; then
mkdir -p "\$HOME/.homebrew/bin" "\$HOME/.homebrew/opt/perl/bin"
cat > "\$HOME/.homebrew/bin/brew" <<'EOS'
$brew_script
EOS
chmod 0755 "\$HOME/.homebrew/bin/brew"
fi
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'apk' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "apk \$*" >> "$log"
append_marker() {
tool=\$1
grep -qx "\$tool" "$node_marker" 2>/dev/null || printf '%s\\n' "\$tool" >> "$node_marker"
}
if [ "\$1" = "add" ]; then
case " \$* " in
  *" nodejs "*)
    append_marker node
    ;;
esac
case " \$* " in
  *" npm "*)
    append_marker npm
    append_marker npx
    ;;
esac
fi
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'dnf' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "dnf \$*" >> "$log"
if [ "\$1" = "install" ] && printf '%s ' "\$@" | grep -q ' nodejs '; then
grep -qx 'node' "$node_marker" 2>/dev/null || printf '%s\\n' 'node' >> "$node_marker"
grep -qx 'npm' "$node_marker" 2>/dev/null || printf '%s\\n' 'npm' >> "$node_marker"
grep -qx 'npx' "$node_marker" 2>/dev/null || printf '%s\\n' 'npx' >> "$node_marker"
fi
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'cpanm' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "cpanm \$*" >> "$log"
if [ "$fake_cpanm_installs_local_perlbrew" = "1" ] && printf '%s ' "\$*" | grep -Eq ' App::perlbrew|App-perlbrew-1\\.02\\.tar\\.gz'; then
mkdir -p "\$HOME/perl5/bin" "\$HOME/perl5/lib/perl5/App"
cat > "\$HOME/perl5/bin/perlbrew" <<'EOS'
#!/bin/sh
printf '%s\\n' "perlbrew \$*" >> "__LOG__"
case ":\${PERL5LIB:-}:" in
  *:"__HOME__/perl5/lib/perl5":* ) ;;
  *)
    printf '%s\\n' "Can't locate App/perlbrew.pm in \@INC" >&2
    exit 2
    ;;
esac
if [ "\$1" = "--notest" ]; then
shift
fi
case "\$1" in
init)
mkdir -p "\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}/perls"
mkdir -p "\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}/etc"
cat > "\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}/etc/bashrc" <<'INNER'
# fake perlbrew shell bootstrap
INNER
exit 0
;;
list)
exit 0
;;
install)
root="\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}"
PERL5LIB='' "\$HOME/perl5/bin/patchperl" apply "\$2" || exit \$?
mkdir -p "\$root/perls/\$2/bin"
cat > "\$root/perls/\$2/bin/perl" <<'INNER'
#!/bin/sh
printf '%s\\n' "perl \$*" >> "__LOG__"
printf 'export PATH="__HOME__/perl5/bin:\$PATH"; export PERL5LIB="__HOME__/perl5/lib/perl5\${PERL5LIB:+:\$PERL5LIB}"\\n'
exit 0
INNER
perl_path="\$root/perls/\$2/bin/perl"
sed "s|__LOG__|$log|g; s|__HOME__|\$HOME|g" "\$perl_path" > "\$perl_path.tmp" && mv "\$perl_path.tmp" "\$perl_path"
chmod 0755 "\$perl_path"
exit 0
;;
install-cpanm)
root="\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}"
mkdir -p "\$root/bin"
cat > "\$root/bin/cpanm" <<'INNER'
#!/bin/sh
printf '%s\\n' "cpanm \$*" >> "__LOG__"
exit 0
INNER
sed "s|__LOG__|$log|g" "\$root/bin/cpanm" > "\$root/bin/cpanm.tmp" && mv "\$root/bin/cpanm.tmp" "\$root/bin/cpanm"
chmod 0755 "\$root/bin/cpanm"
exit 0
;;
esac
exit 0
EOS
sed "s|__LOG__|$log|g; s|__HOME__|\$HOME|g" "\$HOME/perl5/bin/perlbrew" > "\$HOME/perl5/bin/perlbrew.tmp" && mv "\$HOME/perl5/bin/perlbrew.tmp" "\$HOME/perl5/bin/perlbrew"
chmod 0755 "\$HOME/perl5/bin/perlbrew"
cat > "\$HOME/perl5/bin/patchperl" <<'EOS'
#!/bin/sh
printf '%s\\n' "patchperl \$*" >> "__LOG__"
case ":\${PERL5LIB:-}:" in
  *:"__HOME__/perl5/lib/perl5":* ) ;;
  *)
    printf '%s\\n' "Can't locate Devel/PatchPerl.pm in \@INC" >&2
    exit 2
    ;;
esac
exit 0
EOS
sed "s|__LOG__|$log|g; s|__HOME__|\$HOME|g" "\$HOME/perl5/bin/patchperl" > "\$HOME/perl5/bin/patchperl.tmp" && mv "\$HOME/perl5/bin/patchperl.tmp" "\$HOME/perl5/bin/patchperl"
chmod 0755 "\$HOME/perl5/bin/patchperl"
cat > "\$HOME/perl5/lib/perl5/App/perlbrew.pm" <<'EOS'
package App::perlbrew;
1;
EOS
mkdir -p "\$HOME/perl5/lib/perl5/Devel"
cat > "\$HOME/perl5/lib/perl5/Devel/PatchPerl.pm" <<'EOS'
package Devel::PatchPerl;
1;
EOS
fi
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'git' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "git \$*" >> "$log"
if [ "\$1" = "clone" ]; then
target=''
for arg in "\$@"; do
target=\$arg
done
mkdir -p "\$target/lib/Developer"
printf '%s\\n' 'version = 3.44' > "\$target/dist.ini"
printf '%s\\n' 'package Developer::Dashboard; 1;' > "\$target/lib/Developer/Dashboard.pm"
fi
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'curl' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "curl \$*" >> "$log"
output=''
stdout=0
while [ \$# -gt 0 ]; do
case "\$1" in
  -o)
    output=\$2
    shift 2
    ;;
  -fsSL|-f|-s|-S|-L)
    shift
    ;;
  *)
    url=\$1
    shift
    ;;
esac
done
[ -n "\$url" ] || exit 1
if [ -n "\$output" ]; then
mkdir -p "\$(dirname "\$output")"
printf '%s\\n' 'fake perlbrew tarball' > "\$output"
else
printf '%s\\n' '#!/bin/sh'
printf '%s\\n' 'echo fake homebrew install'
fi
exit 0
SH
    );
    if ($fake_brew_on_path) {
        _write_executable(
            File::Spec->catfile( $fake_bin, 'brew' ),
            $brew_script,
        );
    }
    _write_executable(
        File::Spec->catfile( $fake_bin, 'perl' ),
        <<"SH",
#!/bin/sh
if [ "\$1" = "-e" ] && [ "\$2" = "exit((\$] >= 5.038) ? 0 : 1)" ]; then
printf '%s\\n' "perl \$*" >> "$log"
if [ "\${FAKE_PERL_MEETS_MIN:-1}" = "1" ]; then
exit 0
fi
exit 1
fi
printf '%s\\n' "perl \$*" >> "$log"
printf 'export PATH="%s/perl5/bin:\$PATH"; export PERL5LIB="%s/perl5/lib/perl5\${PERL5LIB:+:\$PERL5LIB}"\\n' "\$HOME" "\$HOME"
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'd2' ),
        <<"SH",
#!/bin/sh
printf '%s\\n' "d2 \$*" >> "$log"
exit 0
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'node' ),
        <<"SH",
#!/bin/sh
grep -qx 'node' "$node_marker" 2>/dev/null || exit 1
printf '%s\\n' 'v22.0.0'
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'npm' ),
        <<"SH",
#!/bin/sh
grep -qx 'npm' "$node_marker" 2>/dev/null || exit 1
printf '%s\\n' '10.0.0'
SH
    );
    _write_executable(
        File::Spec->catfile( $fake_bin, 'npx' ),
        <<"SH",
#!/bin/sh
grep -qx 'npx' "$node_marker" 2>/dev/null || exit 1
printf '%s\\n' '10.0.0'
SH
    );
    if ($fake_perlbrew_on_path) {
        _write_executable(
            File::Spec->catfile( $fake_bin, 'perlbrew' ),
            <<"SH",
#!/bin/sh
printf '%s\\n' "perlbrew \$*" >> "$log"
if [ "\$1" = "--notest" ]; then
shift
fi
case "\$1" in
init)
mkdir -p "\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}/perls"
mkdir -p "\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}/etc"
cat > "\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}/etc/bashrc" <<'EOS'
# fake perlbrew shell bootstrap
EOS
cat <<'EOS'
perlbrew root (~/perl5/perlbrew) is initialized.

Append the following piece of code to the end of your ~/.profile and start a
new shell, perlbrew should be up and fully functional from there:

    export PERLBREW_HOME=~/perl5/perlbrew
    source ~/perl5/perlbrew/etc/bashrc
EOS
exit 0
;;
list)
exit 0
;;
install)
root="\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}"
mkdir -p "\$root/perls/\$2/bin"
cat > "\$root/perls/\$2/bin/perl" <<'EOS'
#!/bin/sh
printf '%s\\n' "perl \$*" >> "__LOG__"
printf 'export PATH="__HOME__/perl5/bin:\$PATH"; export PERL5LIB="__HOME__/perl5/lib/perl5\${PERL5LIB:+:\$PERL5LIB}"\\n'
exit 0
EOS
perl_path="\$root/perls/\$2/bin/perl"
sed "s|__LOG__|$log|g; s|__HOME__|\$HOME|g" "\$perl_path" > "\$perl_path.tmp" && mv "\$perl_path.tmp" "\$perl_path"
chmod 0755 "\$perl_path"
exit 0
;;
install-cpanm)
root="\${PERLBREW_ROOT:-\$HOME/perl5/perlbrew}"
mkdir -p "\$root/bin"
cat > "\$root/bin/cpanm" <<'EOS'
#!/bin/sh
printf '%s\\n' "cpanm \$*" >> "__LOG__"
exit 0
EOS
sed "s|__LOG__|$log|g" "\$root/bin/cpanm" > "\$root/bin/cpanm.tmp" && mv "\$root/bin/cpanm.tmp" "\$root/bin/cpanm"
chmod 0755 "\$root/bin/cpanm"
exit 0
;;
esac
exit 0
SH
        );
    }
}

# _plain_lines($path)
# Reads a one-entry-per-line list file.
# Input: file path. Output: the non-empty lines, in file order.
sub _plain_lines {
    my ($path) = @_;
    return grep { $_ ne '' } map { s/\s+\z//r } split /\n/, _raw_text($path);
}

# _raw_text($path)
# Reads a file exactly as it is on disk, with no spelling changes.
# Input: file path. Output: the file text.
sub _raw_text {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    binmode $fh;
    my $text = do { local $/; <$fh> };
    close $fh or die "Unable to close $path: $!";
    return $text;
}

# _jenkins_env_prefix(%env)
# Builds the "KEY='value' ..." prefix for an install.sh --jenkins scenario.
# Input: environment names and values, in order. Output: the prefix text.
sub _jenkins_env_prefix {
    my (@pairs) = @_;
    my @parts;
    while (@pairs) {
        my ( $key, $value ) = splice @pairs, 0, 2;
        push @parts, sprintf q{%s='%s'}, $key, _msys_path($value);
    }
    return join ' ', @parts;
}

# _seed_fake_jenkins_commands(%args)
# Adds the fake tools the install.sh --jenkins route needs on top of
# _seed_fake_install_commands: a sudo that accepts -n, the macOS settings
# tools, java, a brew that knows the openssl@3 and openjdk@21 prefixes, a
# perlbrew that "builds" a fake Perl, and a bash that "runs" the perlbrew
# installer. The fake Perl answers the exact-version question (wrong when
# FAKE_JENKINS_PERL_WRONG is 1) and "installs" a fake cpanm, which records
# each pinned distribution the way the real one does (and fails on the
# distribution named in FAKE_JENKINS_CPANM_FAILS_ON).
# Input: fake_bin, log, perlbrew_on_path.
# Output: none; the stubs are written under fake_bin.
sub _seed_fake_jenkins_commands {
    my (%args) = @_;
    my $fake_bin = $args{fake_bin};
    my $log      = $args{log};
    my $payload  = File::Spec->catdir( $fake_bin, 'jenkins-payload' );
    make_path($payload);

    my $write = sub {
        my ( $path, $body ) = @_;
        $body =~ s/__LOG__/$log/g;
        $body =~ s/__PAYLOAD__/$payload/g;
        return _write_executable( $path, $body );
    };

    $write->( File::Spec->catfile( $fake_bin, 'sudo' ), <<'SH' );
#!/bin/sh
printf '%s\n' "sudo $*" >> "__LOG__"
if [ "$1" = "-n" ]; then
shift
fi
exec "$@"
SH
    for my $tool (qw(systemsetup pmset sntp)) {
        $write->( File::Spec->catfile( $fake_bin, $tool ), <<"SH" );
#!/bin/sh
printf '%s\\n' "$tool \$*" >> "__LOG__"
exit 0
SH
    }
    my $java = <<'SH';
#!/bin/sh
printf '%s\n' "java $*" >> "__LOG__"
printf '%s\n' 'openjdk version "21.0.13" 2026-10-24' >&2
exit 0
SH
    $write->( File::Spec->catfile( $fake_bin, 'java' ), $java );
    $write->( File::Spec->catfile( $payload,  'java' ), $java );
    # The CPU count the --jenkins route reads for the Perl build: a fixed
    # 6, so the test can tell -j from the count apart from a hard-coded 4.
    $write->( File::Spec->catfile( $fake_bin, 'nproc' ), <<'SH' );
#!/bin/sh
printf '%s\n' "nproc $*" >> "__LOG__"
printf '%s\n' '6'
exit 0
SH
    $write->( File::Spec->catfile( $fake_bin, 'sysctl' ), <<'SH' );
#!/bin/sh
printf '%s\n' "sysctl $*" >> "__LOG__"
printf '%s\n' '6'
exit 0
SH
    $write->( File::Spec->catfile( $fake_bin, 'brew' ), <<'SH' );
#!/bin/sh
printf '%s\n' "brew $*" >> "__LOG__"
if [ "$1" = "--prefix" ]; then
case "$2" in
  perl)
    printf '%s\n' "$HOME/.homebrew/opt/perl"
    ;;
  openssl@3)
    mkdir -p "$HOME/.homebrew/opt/openssl@3/bin"
    printf '%s\n' "$HOME/.homebrew/opt/openssl@3"
    ;;
  openjdk@21)
    mkdir -p "$HOME/.homebrew/opt/openjdk@21/bin"
    cp "__PAYLOAD__/java" "$HOME/.homebrew/opt/openjdk@21/bin/java"
    chmod 0755 "$HOME/.homebrew/opt/openjdk@21/bin/java"
    printf '%s\n' "$HOME/.homebrew/opt/openjdk@21"
    ;;
esac
fi
exit 0
SH
    $write->( File::Spec->catfile( $payload, 'cpanm' ), <<'SH' );
#!/bin/sh
printf '%s\n' "cpanm $*" >> "__LOG__"
last=''
for arg in "$@"; do
last=$arg
done
case " $* " in
  *" --version "*)
    printf '%s\n' 'cpanm (App::cpanminus) version 1.7049 (fake)'
    exit 0
    ;;
  *" --test-only "*|*" --uninstall "*)
    exit 0
    ;;
esac
case "$last" in
  */*.tar.gz)
    if [ "${FAKE_JENKINS_CPANM_FAILS_ON:-}" = "$last" ]; then
      printf '%s\n' 'fake build failure' >&2
      exit 1
    fi
    name=$(basename "$last" .tar.gz)
    meta="$(dirname "$0")/../lib/site_perl/5.38.2/fake-arch/.meta/$name"
    mkdir -p "$meta"
    # No trailing newline, exactly as the real cpanm writes install.json
    # (its save_meta prints the JSON with no newline): the final check
    # must read one pathname per file, and a newline here would hide a
    # read-back that merges the files into one line (R84).
    printf '{"dist":"%s","pathname":"%s"}' "$name" "$last" > "$meta/install.json"
    ;;
esac
exit 0
SH
    $write->( File::Spec->catfile( $payload, 'perl' ), <<'SH' );
#!/bin/sh
printf '%s\n' "perl $*" >> "__LOG__"
case "$*" in
  *"5.038002"*)
    if [ "${FAKE_JENKINS_PERL_WRONG:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
  *"App::cpanminus@1.7049"*)
    cp "__PAYLOAD__/cpanm" "$(dirname "$0")/cpanm"
    chmod 0755 "$(dirname "$0")/cpanm"
    exit 0
    ;;
esac
exit 0
SH
    my $perlbrew = <<'SH';
#!/bin/sh
printf '%s\n' "perlbrew $*" >> "__LOG__"
root="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}"
case "$1" in
  init)
    mkdir -p "$root/perls"
    ;;
  install)
    mkdir -p "$root/perls/$2/bin"
    cp "__PAYLOAD__/perl" "$root/perls/$2/bin/perl"
    chmod 0755 "$root/perls/$2/bin/perl"
    ;;
esac
exit 0
SH
    $write->( File::Spec->catfile( $payload, 'perlbrew' ), $perlbrew );
    if ( $args{perlbrew_on_path} ) {
        $write->( File::Spec->catfile( $fake_bin, 'perlbrew' ), $perlbrew );
    }
    $write->( File::Spec->catfile( $fake_bin, 'bash' ), <<'SH' );
#!/bin/sh
printf '%s\n' "/bin/bash $*" >> "__LOG__"
case "$1" in
  *jenkins-perlbrew-install.sh)
    root="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}"
    mkdir -p "$root/bin"
    cp "__PAYLOAD__/perlbrew" "$root/bin/perlbrew"
    chmod 0755 "$root/bin/perlbrew"
    ;;
esac
exit 0
SH
    return 1;
}

# _posix_shell_binary($preferred)
# Resolves the POSIX shell that runs install.sh. Windows has no sh on PATH,
# so the copy shipped with Git for Windows (usr\bin) is located explicitly;
# same helper as t/172.
# Input: shell name such as 'sh'.
# Output: the name unchanged off Windows, else the sh.exe path when found.
sub _posix_shell_binary {
    my ($preferred) = @_;
    return $preferred if $^O ne 'MSWin32';

    my @roots;
    my %seen;

    # git.exe lives in <root>\cmd, <root>\bin or <root>\mingw64\bin: strip
    # those trailing components to recover the Git install root.
    for my $dir ( split /;/, $ENV{PATH} // '' ) {
        my $git = File::Spec->catfile( $dir, 'git.exe' );
        next if !-f $git;
        my ( $volume, $dirs ) = File::Spec->splitpath($git);
        my @parts = grep { $_ ne '' } File::Spec->splitdir($dirs);
        pop @parts while @parts && $parts[-1] =~ /\A(?:cmd|bin|mingw64|mingw32)\z/i;
        my $root = File::Spec->catdir( $volume . File::Spec->rootdir(), @parts );
        push @roots, $root if !$seen{$root}++;
        last;
    }

    for my $program_files ( grep { defined && $_ ne '' } $ENV{ProgramFiles}, $ENV{'ProgramFiles(x86)'} ) {
        my $root = File::Spec->catdir( $program_files, 'Git' );
        push @roots, $root if !$seen{$root}++;
    }

    for my $root (@roots) {
        my $shell = File::Spec->catfile( $root, 'usr', 'bin', "$preferred.exe" );
        return $shell if -f $shell;
    }
    return $preferred;
}

# _msys_path($path)
# Spells a Windows path the way Git for Windows' sh expects it inside a
# ':'-joined PATH (C:\dir becomes /c/dir). Unchanged off Windows.
# Input: native path. Output: path usable inside the POSIX shell.
sub _msys_path {
    my ($path) = @_;
    return $path if $^O ne 'MSWin32';
    $path =~ s{\\}{/}g;
    $path =~ s{\A([A-Za-z]):}{'/' . lc($1)}e;
    return $path;
}

# _base_path()
# The real directories the install.sh scenarios may fall through to after
# the fake command directory. Off Windows that is the caller's PATH. On
# Windows it is only Git for Windows' /usr/bin (coreutils, sed, awk, grep):
# it holds no curl, git, cpanm, winget or make, so a scenario can never
# reach a real downloader or installer there.
# Input: none. Output: ':'-joined PATH tail.
sub _base_path {
    return '/usr/bin' if $^O eq 'MSWin32';
    return $ENV{PATH} || '';
}

# _sh_script($command)
# Writes a shell command line to a script file. A command holding quotes
# does not survive the Windows command line as a -c argument.
# Input: shell command text. Output: path of the script file.
sub _sh_script {
    my ($command) = @_;
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'run.sh' );
    open my $fh, '>', $path or die "Unable to write $path: $!";
    binmode $fh;
    print {$fh} $command, "\n";
    close $fh or die "Unable to close $path: $!";
    return $path;
}

# _sh_c($command)
# Runs a shell command line through the POSIX shell, as "sh -c" does.
# Input: shell command text. Output: the system() status.
sub _sh_c {
    my ($command) = @_;
    return system( 'sh', '-c', $command ) if $^O ne 'MSWin32';
    return system( _posix_shell_binary('sh'), _sh_script($command) );
}

# _native_spelling($text)
# Turns the shell's spelling of the temp directory back into the native one
# on Windows (see the note at the top of the file). Unchanged elsewhere.
# Input: text produced by the shell. Output: the text in native spelling.
sub _native_spelling {
    my ($text) = @_;
    return $text if $^O ne 'MSWin32' || !defined $text;
    $text =~ s{\Q$TEMP_MSYS\E/}{$TEMP_NATIVE/}g;
    $text =~ s{(?<![\w.\}])/tmp/(?=\w{10}(?:\W|\z))}{$TEMP_NATIVE/}g;
    return $text;
}

# _shell_runs_as_root()
# Says whether install.sh will see itself as root, which decides whether it
# goes through sudo. Perl's effective uid is always 0 on Windows, so there
# the shell is asked the same question install.sh asks.
# Input: none. Output: true when "id -u" is 0 for the installer.
sub _shell_runs_as_root {
    return ( ( $> || 0 ) == 0 ) if $^O ne 'MSWin32';
    my ( $uid, undef, $status ) = capture {
        _sh_c( q{PATH='/usr/bin' id -u} );
    };
    $uid =~ s/\s+//g;
    return $status == 0 && $uid eq '0';
}

sub _log_lines {
    my ($path) = @_;
    return () if !-f $path;
    my $text = _slurp($path);
    return grep { defined && $_ ne '' } split /\n/, $text;
}

# _perl_source_file($source)
# Writes Perl source to a script file so it can run as "perl FILE". A -e
# argument holding double quotes does not survive the Windows command line.
# Input: Perl source text.
# Output: absolute path of the script file (removed at exit).
sub _perl_source_file {
    my ($source) = @_;
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = File::Spec->catfile( $dir, 'one-liner.pl' );
    open my $fh, '>', $path or die "Unable to write $path: $!";
    print {$fh} $source;
    close $fh or die "Unable to close $path: $!";
    return $path;
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "Unable to read $path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return _native_spelling($text);
}

sub _write_executable {
    my ( $path, $body ) = @_;
    open my $fh, '>', $path or die "Unable to write $path: $!";
    # Raw: a carriage return after "#!/bin/sh" would break the stub.
    binmode $fh;
    print {$fh} $body;
    close $fh;
    chmod 0755, $path or die "Unable to chmod $path: $!";
    return 1;
}

__END__

=head1 NAME

t/40-install-bootstrap.t - regression coverage for the repo bootstrap installer

=head1 PURPOSE

This test locks the repo-root bootstrap installer contract so the plain
F<install.sh> entrypoint, F<aptfile>, F<apkfile>, and F<brewfile> stay aligned
while the project evolves.

=head1 WHAT IT CHECKS

It verifies that the installer remains valid POSIX shell, that Debian-family
and macOS package installation flows use the repo manifests in order, that the
user-space Perl bootstrap goes through C<local::lib>, and that the correct
shell rc file receives exactly one bootstrap line.
It also checks the installer's arguments: an unknown argument is refused
with a usage line before any tool is called or any shell rc file is written.
C<--jenkins> takes its own route, the Jenkins test-node setup: with fake tools
it checks that Perl 5.38.2 is always built, that the pinned list is installed
in list order, that the compiled distributions run their own tests, that the
macOS-only settings step runs only on macOS, that a wrong Perl, a failed
build or an unsupported platform stops with one FAILED line, that a second
run changes nothing, and that neither the dashboard nor a shell rc file is
touched.
For F<install.ps1> it reads the script text: the C<-Jenkins> switch and the
C<DD_INSTALL_JENKINS> variable exist, the Perl is pinned to exactly 5.38.2 at
the Strawberry root, the Windows lists under F<share/jenkins> are the ones
read, the dashboard install and the profile edits are not on that route, and
the script holds no address and no path into one user profile. No PowerShell
is started by this file on any platform.

=head1 WHY IT EXISTS

The installation path now has to work from a blank machine, so this file
protects the most important bootstrap assumptions before the heavier Docker
acceptance gates run.

=head1 WHEN TO USE

Use this test when changing the checkout bootstrap flow, the repo-root package
manifests, the user-space Perl bootstrap contract, or the shell rc file update
policy.

=head1 HOW TO USE

Run it directly through the Perl test harness during focused bootstrap work or
let it run as part of the full suite.

=head1 WHAT USES IT

It is used by the local regression suite and the release metadata gate so the
shipped bootstrap installer cannot drift away from the documented install path.

=head1 HOW TO RUN

Run it through the normal suite:

  prove -lv t/40-install-bootstrap.t

=head1 EXAMPLES

Example:

  prove -lv t/40-install-bootstrap.t

=cut
