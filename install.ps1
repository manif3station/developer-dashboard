& {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CpanTarget = if ([string]::IsNullOrWhiteSpace($env:DD_INSTALL_CPAN_TARGET)) { 'Developer::Dashboard' } else { $env:DD_INSTALL_CPAN_TARGET }
$InstallRoot = if ([string]::IsNullOrWhiteSpace($env:DD_INSTALL_ROOT)) { '' } else { $env:DD_INSTALL_ROOT }
$ProfilePath = if ([string]::IsNullOrWhiteSpace($env:DD_INSTALL_PROFILE_PATH)) { '' } else { $env:DD_INSTALL_PROFILE_PATH }
$PreferredShell = if ([string]::IsNullOrWhiteSpace($env:DD_INSTALL_PREFERRED_SHELL)) { 'powershell' } else { $env:DD_INSTALL_PREFERRED_SHELL }
$ShellCommands = if ([string]::IsNullOrWhiteSpace($env:DD_INSTALL_SHELL_COMMANDS)) { '' } else { $env:DD_INSTALL_SHELL_COMMANDS }

function Resolve-HomeDirectory {
    # Purpose: determine the current user's home directory for the Windows bootstrap.
    # Input: the current PowerShell environment and .NET user-profile APIs.
    # Output: returns a non-empty absolute home-directory path string.
    if (-not [string]::IsNullOrWhiteSpace($HOME)) {
        return $HOME
    }

    $resolvedHome = [Environment]::GetFolderPath('UserProfile')
    if (-not [string]::IsNullOrWhiteSpace($resolvedHome)) {
        return $resolvedHome
    }

    throw 'Unable to resolve the current user home directory for install.ps1'
}

function Resolve-CommandPath {
    # Purpose: resolve a runnable command path for the requested executable names.
    # Input: one or more command names to search through Get-Command.
    # Output: returns the first filesystem-backed command path or an empty string.
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {
            continue
        }

        foreach ($propertyName in @('Source', 'Path', 'Definition')) {
            $candidate = $command.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
                return $candidate
            }
        }
    }

    return ''
}

function Refresh-ProcessPathFromEnvironment {
    # Purpose: refresh the current PowerShell PATH from machine, user, and process scopes after winget installs.
    # Input: the current Windows environment plus machine and user PATH values from .NET.
    # Output: updates $env:PATH in-process and returns nothing.
    $pathSegments = [System.Collections.Generic.List[string]]::new()
    foreach ($scope in @('Machine', 'User', 'Process')) {
        $scopePath = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ([string]::IsNullOrWhiteSpace($scopePath)) {
            continue
        }

        foreach ($segment in ($scopePath -split ';')) {
            if ([string]::IsNullOrWhiteSpace($segment)) {
                continue
            }
            if (-not $pathSegments.Contains($segment)) {
                $null = $pathSegments.Add($segment)
            }
        }
    }

    if ($pathSegments.Count -gt 0) {
        $env:PATH = ($pathSegments -join ';')
    }
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path (Resolve-HomeDirectory) 'perl5'
}

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = $PROFILE.CurrentUserCurrentHost
}

$script:ProgressSteps = [System.Collections.Generic.List[object]]::new()
$null = $script:ProgressSteps.Add([pscustomobject]@{ Id = 'detect_profile'; Label = 'Detect PowerShell profile'; Status = 'pending'; Detail = '' })
$null = $script:ProgressSteps.Add([pscustomobject]@{ Id = 'install_bootstrap'; Label = 'Install Windows bootstrap packages'; Status = 'pending'; Detail = '' })
$null = $script:ProgressSteps.Add([pscustomobject]@{ Id = 'verify_node'; Label = 'Verify Node toolchain'; Status = 'pending'; Detail = '' })
$null = $script:ProgressSteps.Add([pscustomobject]@{ Id = 'bootstrap_perl'; Label = 'Bootstrap Perl user-space runtime'; Status = 'pending'; Detail = '' })
$null = $script:ProgressSteps.Add([pscustomobject]@{ Id = 'install_dashboard'; Label = 'Install Developer Dashboard'; Status = 'pending'; Detail = '' })
$null = $script:ProgressSteps.Add([pscustomobject]@{ Id = 'initialize_dashboard'; Label = 'Initialize dashboard runtime'; Status = 'pending'; Detail = '' })

$script:ProgressPrinted = $false

function Get-StepPrefix {
    # Purpose: choose the visible progress prefix for a step status.
    # Input: a status token such as pending, running, ok, or error.
    # Output: returns the human-readable status prefix string for terminal output.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    switch ($Status) {
        'ok' { return '[OK]' }
        'error' { return '[X]' }
        'running' { return '->' }
        default { return '[ ]' }
    }
}

function Get-StepColor {
    # Purpose: choose the terminal color for a step status.
    # Input: a status token such as pending, running, ok, or error.
    # Output: returns a PowerShell ConsoleColor name for Write-Host.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    switch ($Status) {
        'ok' { return 'Green' }
        'error' { return 'Red' }
        'running' { return 'Yellow' }
        default { return 'Gray' }
    }
}

function Show-ProgressBoard {
    # Purpose: print the initial progress board once before any work starts.
    # Input: the in-memory progress-step list.
    # Output: writes the progress title plus the full pending checklist to the terminal.
    if ($script:ProgressPrinted) {
        return
    }

    Write-Host 'Developer Dashboard install progress'
    foreach ($step in $script:ProgressSteps) {
        Write-Host ("{0} {1}" -f (Get-StepPrefix -Status $step.Status), $step.Label) -ForegroundColor (Get-StepColor -Status $step.Status)
    }
    $script:ProgressPrinted = $true
}

function Set-StepStatus {
    # Purpose: update one progress step and emit a visible transition line.
    # Input: the step id, a new status token, and an optional detail string.
    # Output: mutates the in-memory progress step and writes the new state to the terminal.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [string]$Detail = ''
    )

    $step = $script:ProgressSteps | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $step) {
        throw "Unknown install.ps1 progress step id: $Id"
    }

    $step.Status = $Status
    $step.Detail = $Detail

    Show-ProgressBoard

    $line = "{0} {1}" -f (Get-StepPrefix -Status $Status), $step.Label
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $line = "$line ($Detail)"
    }
    Write-Host $line -ForegroundColor (Get-StepColor -Status $Status)
}

function Ensure-ParentDirectory {
    # Purpose: create the parent directory for a path when it does not exist yet.
    # Input: a filesystem path whose parent directory should be ensured.
    # Output: creates the parent directory tree and returns nothing.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
}

function Invoke-NativeCommand {
    # Purpose: run a native command verbosely and fail on non-zero exit status.
    # Input: a label plus an executable path/name and its argument array.
    # Output: writes the command, streams native output, and throws on failure.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $display = if ($Arguments.Count -gt 0) { "$FilePath $($Arguments -join ' ')" } else { $FilePath }
    Write-Host $display -ForegroundColor DarkGray
    & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Format-ExitCode {
    # Purpose: render a native Windows exit code in both decimal and unsigned hexadecimal forms.
    # Input: a signed integer exit code captured from $LASTEXITCODE.
    # Output: returns a string like "-1978335138 (0x8A15005E)" for clearer diagnostics.
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $unsigned = [uint32]$ExitCode
    return ('{0} (0x{1:X8})' -f $ExitCode, $unsigned)
}

function Repair-WingetSources {
    # Purpose: repair the default winget sources after a bootstrap install fails because source metadata or certificates are broken.
    # Input: a resolved winget executable path.
    # Output: resets and refreshes the winget source catalog or throws if repair fails.
    param(
        [Parameter(Mandatory = $true)]
        [string]$WingetPath
    )

    Write-Host 'Repairing winget sources before retrying the Windows bootstrap install.' -ForegroundColor Yellow
    Invoke-NativeCommand -Label 'winget source reset' -FilePath $WingetPath -Arguments @(
        'source',
        'reset',
        '--force'
    )
    Invoke-NativeCommand -Label 'winget source update winget' -FilePath $WingetPath -Arguments @(
        'source',
        'update',
        'winget'
    )
}

function Ensure-WingetPackage {
    # Purpose: install a missing Windows package through winget without user prompts.
    # Input: the winget package id, a human label, and the command names that prove it is already present.
    # Output: installs the package when needed and returns the resolved command path when one exists.
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string[]]$CommandNames
    )

    $resolved = Resolve-CommandPath -Names $CommandNames
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        return $resolved
    }

    $winget = Resolve-CommandPath -Names @('winget.exe', 'winget')
    if ([string]::IsNullOrWhiteSpace($winget)) {
        throw "winget is required to install missing Windows package: $Label ($PackageId)"
    }

    Write-Host "Installing missing Windows package via winget: $Label ($PackageId)"
    $installArguments = @(
        'install',
        '--id', $PackageId,
        '--exact',
        '--source', 'winget',
        '--silent',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    $installLabel = "winget install $PackageId"
    $installFailed = $false
    try {
        Invoke-NativeCommand -Label $installLabel -FilePath $winget -Arguments $installArguments
    }
    catch {
        $installFailed = $true
        $firstExitCode = $LASTEXITCODE
        Write-Host ("winget install failed for {0}: {1}" -f $PackageId, (Format-ExitCode -ExitCode $firstExitCode)) -ForegroundColor Yellow
        Write-Host 'A broken msstore source or stale source metadata can block winget even for community packages. Resetting sources and retrying once.' -ForegroundColor Yellow
        Repair-WingetSources -WingetPath $winget
    }

    if ($installFailed) {
        try {
            Invoke-NativeCommand -Label "$installLabel retry" -FilePath $winget -Arguments $installArguments
        }
        catch {
            $retryExitCode = $LASTEXITCODE
            throw "winget install $PackageId failed after a source reset retry with exit code $(Format-ExitCode -ExitCode $retryExitCode)"
        }
    }

    Refresh-ProcessPathFromEnvironment
    $resolved = Resolve-CommandPath -Names $CommandNames
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "Installed Windows package did not expose command on PATH: $Label ($PackageId)"
    }

    return $resolved
}

function Add-StrawberryPaths {
    # Purpose: add the Strawberry Perl toolchain directories to the current PATH.
    # Input: a resolved Strawberry perl.exe path.
    # Output: prepends perl/bin, perl/site/bin, and c/bin to PATH when they exist.
    param(
        [Parameter(Mandatory = $true)]
        [string]$PerlPath
    )

    $perlBin = Split-Path -Parent $PerlPath
    $perlRoot = Split-Path -Parent $perlBin
    $strawberryRoot = Split-Path -Parent $perlRoot
    $candidateDirs = @(
        $perlBin,
        (Join-Path $perlRoot 'site\bin'),
        (Join-Path $strawberryRoot 'c\bin')
    ) | Select-Object -Unique

    foreach ($dir in $candidateDirs) {
        if (-not (Test-Path $dir)) {
            continue
        }
        $escaped = [Regex]::Escape($dir)
        if ($env:PATH -notmatch "(?i)(^|;)$escaped(;|$)") {
            $env:PATH = "$dir;$env:PATH"
        }
    }
}

function Ensure-NodeToolchain {
    # Purpose: make sure node, npm, and npx all exist before dashboard skills need package.json support.
    # Input: the current PATH and optional winget package manager.
    # Output: returns nothing after the Node toolchain is available or throws on failure.
    $nodePath = Resolve-CommandPath -Names @('node.exe', 'node')
    $npmPath = Resolve-CommandPath -Names @('npm.cmd', 'npm.exe', 'npm')
    $npxPath = Resolve-CommandPath -Names @('npx.cmd', 'npx.exe', 'npx')

    if (-not [string]::IsNullOrWhiteSpace($nodePath) -and -not [string]::IsNullOrWhiteSpace($npmPath) -and -not [string]::IsNullOrWhiteSpace($npxPath)) {
        return
    }

    $null = Ensure-WingetPackage -PackageId 'OpenJS.NodeJS.LTS' -Label 'Node.js LTS' -CommandNames @('node.exe', 'node')
    $npmPath = Resolve-CommandPath -Names @('npm.cmd', 'npm.exe', 'npm')
    $npxPath = Resolve-CommandPath -Names @('npx.cmd', 'npx.exe', 'npx')
    if ([string]::IsNullOrWhiteSpace($npmPath) -or [string]::IsNullOrWhiteSpace($npxPath)) {
        throw 'Node.js was installed but npm and npx are still unavailable on PATH'
    }
}

function Ensure-ProfileContains {
    # Purpose: append one bootstrap block to the PowerShell profile only when it is missing.
    # Input: the profile path plus the literal block text that should exist in that profile.
    # Output: creates the profile file when needed and appends the block once.
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetProfile,
        [Parameter(Mandatory = $true)]
        [string]$Block
    )

    Ensure-ParentDirectory -Path $TargetProfile
    if (-not (Test-Path $TargetProfile)) {
        Set-Content -Path $TargetProfile -Value '' -Encoding UTF8
    }

    $existing = Get-Content -Path $TargetProfile -Raw
    if ($existing -notlike "*$Block*") {
        $prefix = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { [Environment]::NewLine + [Environment]::NewLine }
        Add-Content -Path $TargetProfile -Value ($prefix + $Block) -Encoding UTF8
    }
}

function Download-CpanmScript {
    # Purpose: fetch the cpanminus bootstrap script into the user-space install root.
    # Input: the install root where the cpanm script should be written.
    # Output: returns the downloaded cpanm script path.
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetInstallRoot
    )

    $binDir = Join-Path $TargetInstallRoot 'bin'
    if (-not (Test-Path $binDir)) {
        $null = New-Item -ItemType Directory -Path $binDir -Force
    }

    $cpanmScript = Join-Path $binDir 'cpanm'
    Write-Host "Downloading cpanminus bootstrap script to $cpanmScript"
    Invoke-WebRequest -Uri 'https://cpanmin.us/' -OutFile $cpanmScript
    return $cpanmScript
}

function Set-LocalPerlEnvironment {
    # Purpose: set the current PowerShell process environment for the user-space Perl install root.
    # Input: the install root path where local::lib-style modules and scripts live.
    # Output: updates PATH, PERL5LIB, PERL_LOCAL_LIB_ROOT, PERL_MB_OPT, and PERL_MM_OPT in-process.
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetInstallRoot
    )

    $binDir = Join-Path $TargetInstallRoot 'bin'
    $libDir = Join-Path $TargetInstallRoot 'lib\perl5'
    $escapedBin = [Regex]::Escape($binDir)
    $escapedLib = [Regex]::Escape($libDir)

    if ($env:PATH -notmatch "(?i)(^|;)$escapedBin(;|$)") {
        $env:PATH = "$binDir;$env:PATH"
    }

    if ([string]::IsNullOrWhiteSpace($env:PERL5LIB)) {
        $env:PERL5LIB = $libDir
    }
    elseif ($env:PERL5LIB -notmatch "(?i)(^|;)$escapedLib(;|$)") {
        $env:PERL5LIB = "$libDir;$env:PERL5LIB"
    }

    $env:PERL_LOCAL_LIB_ROOT = $TargetInstallRoot
    $env:PERL_MB_OPT = "--install_base `"$TargetInstallRoot`""
    $env:PERL_MM_OPT = "INSTALL_BASE=$TargetInstallRoot"
}

Show-ProgressBoard

Set-StepStatus -Id 'detect_profile' -Status 'running'
Ensure-ParentDirectory -Path $ProfilePath
Set-StepStatus -Id 'detect_profile' -Status 'ok' -Detail ("profile: {0}" -f $ProfilePath)

Set-StepStatus -Id 'install_bootstrap' -Status 'running'
$null = Ensure-WingetPackage -PackageId 'Git.Git' -Label 'Git' -CommandNames @('git.exe', 'git')
$perlPath = Ensure-WingetPackage -PackageId 'StrawberryPerl.StrawberryPerl' -Label 'Strawberry Perl' -CommandNames @('perl.exe', 'perl')
Add-StrawberryPaths -PerlPath $perlPath
Set-StepStatus -Id 'install_bootstrap' -Status 'ok' -Detail 'Git and Strawberry Perl ready'

Set-StepStatus -Id 'verify_node' -Status 'running'
Ensure-NodeToolchain
Set-StepStatus -Id 'verify_node' -Status 'ok' -Detail 'node, npm, and npx ready'

Set-StepStatus -Id 'bootstrap_perl' -Status 'running'
if (-not (Test-Path $InstallRoot)) {
    $null = New-Item -ItemType Directory -Path $InstallRoot -Force
}
$cpanmScript = Download-CpanmScript -TargetInstallRoot $InstallRoot
Set-LocalPerlEnvironment -TargetInstallRoot $InstallRoot
Invoke-NativeCommand -Label 'cpanm local::lib App::cpanminus bootstrap' -FilePath $perlPath -Arguments @(
    $cpanmScript,
    '--notest',
    '--local-lib-contained', $InstallRoot,
    'local::lib',
    'App::cpanminus'
)
Set-LocalPerlEnvironment -TargetInstallRoot $InstallRoot

$profileBlock = @"
# Developer Dashboard bootstrap
`$ddInstallRoot = '$InstallRoot'
`$ddPerlBin = Join-Path `$ddInstallRoot 'bin'
`$ddPerlLib = Join-Path `$ddInstallRoot 'lib\perl5'
if (Test-Path `$ddPerlBin) {
    if (`$env:PATH -notlike "*`$ddPerlBin*") {
        `$env:PATH = "`$ddPerlBin;`$env:PATH"
    }
}
if (Test-Path `$ddPerlLib) {
    if ([string]::IsNullOrWhiteSpace(`$env:PERL5LIB)) {
        `$env:PERL5LIB = `$ddPerlLib
    }
    elseif (`$env:PERL5LIB -notlike "*`$ddPerlLib*") {
        `$env:PERL5LIB = "`$ddPerlLib;`$env:PERL5LIB"
    }
}
`$env:PERL_LOCAL_LIB_ROOT = `$ddInstallRoot
`$env:PERL_MB_OPT = "--install_base `"`$ddInstallRoot`""
`$env:PERL_MM_OPT = "INSTALL_BASE=`$ddInstallRoot"
if (Get-Command dashboard -ErrorAction SilentlyContinue) {
    Invoke-Expression (& dashboard shell ps)
}
"@
Ensure-ProfileContains -TargetProfile $ProfilePath -Block $profileBlock
Set-StepStatus -Id 'bootstrap_perl' -Status 'ok' -Detail 'cpanm and PowerShell profile updated'

$dashboardCommand = Resolve-CommandPath -Names @('dashboard.bat', 'dashboard', 'dashboard.cmd')
if ([string]::IsNullOrWhiteSpace($dashboardCommand)) {
    $candidate = Join-Path $InstallRoot 'bin\dashboard.bat'
    if (Test-Path $candidate) {
        $dashboardCommand = $candidate
    }
}

Set-StepStatus -Id 'install_dashboard' -Status 'running'
Invoke-NativeCommand -Label 'cpanm Developer Dashboard install' -FilePath $perlPath -Arguments @(
    $cpanmScript,
    '--notest',
    $CpanTarget
)
$dashboardCommand = Resolve-CommandPath -Names @('dashboard.bat', 'dashboard', 'dashboard.cmd')
if ([string]::IsNullOrWhiteSpace($dashboardCommand)) {
    $candidate = Join-Path $InstallRoot 'bin\dashboard.bat'
    if (-not (Test-Path $candidate)) {
        throw 'Developer Dashboard installed but dashboard command is still unavailable on PATH'
    }
    $dashboardCommand = $candidate
}
Set-StepStatus -Id 'install_dashboard' -Status 'ok' -Detail ("target: {0}" -f $CpanTarget)

Set-StepStatus -Id 'initialize_dashboard' -Status 'running'
Invoke-Expression (& $dashboardCommand shell ps)
Invoke-NativeCommand -Label 'dashboard init' -FilePath $dashboardCommand -Arguments @('init')
if (-not [string]::IsNullOrWhiteSpace($ShellCommands)) {
    Write-Host 'Running post-install activation commands through PowerShell.'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ". '$ProfilePath'; $ShellCommands"
    if ($LASTEXITCODE -ne 0) {
        throw "Post-install activation commands failed with exit code $LASTEXITCODE"
    }
}
Set-StepStatus -Id 'initialize_dashboard' -Status 'ok' -Detail 'dashboard init completed'

Write-Host ("Shell setup was written to: {0}" -f $ProfilePath)
Write-Host 'Developer Dashboard is installed and initialized.'
Write-Host 'Open a new PowerShell window or run this in the current shell:'
Write-Host (". '{0}'" -f $ProfilePath)
Write-Host 'Then verify with:'
Write-Host 'dashboard version'
} @args
