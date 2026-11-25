& {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DefaultBootstrapRepository = 'https://github.com/manif3station/developer-dashboard.git'
$CpanTarget = if ([string]::IsNullOrWhiteSpace($env:DD_INSTALL_CPAN_TARGET)) { '' } else { $env:DD_INSTALL_CPAN_TARGET }
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

function Resolve-DashboardRuntimeHome {
    # Purpose: resolve the home directory the Perl runtime anchors ~/.developer-dashboard under, which is HOME-first and can differ from PowerShell's own $HOME on hosts that export HOME.
    # Input: the HOME, USERPROFILE, HOMEDRIVE, and HOMEPATH environment variables plus the PowerShell home fallback.
    # Output: returns a non-empty absolute home-directory path string matching the Perl-side resolution order.
    if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
        return $env:HOME
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        return $env:USERPROFILE
    }

    if ((-not [string]::IsNullOrWhiteSpace($env:HOMEDRIVE)) -and (-not [string]::IsNullOrWhiteSpace($env:HOMEPATH))) {
        return (Join-Path $env:HOMEDRIVE $env:HOMEPATH)
    }

    return (Resolve-HomeDirectory)
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

function Join-ScriptText {
    # Purpose: normalize command output that may arrive as one string or multiple lines into one PowerShell script string.
    # Input: any scalar or array output captured from a command invocation.
    # Output: returns one newline-joined string with empty values removed.
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [System.Array]) {
        return (($Value | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }

    return [string]$Value
}

# Pin env:HOME for this installer session so the Perl runtime, the cache
# validation below, and the generated profile block all resolve the same
# ~/.developer-dashboard root. The generated profile performs the same seeding
# for future sessions.
$env:HOME = Resolve-DashboardRuntimeHome

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
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Invoke-InstallerCommand {
    # Purpose: run a Windows GUI or MSI installer and wait for its real process exit without piping through a console stream.
    # Input: a label plus an installer executable path and its argument array.
    # Output: writes the command, waits for completion, and throws on non-zero exit status.
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

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw "$Label failed with exit code $($process.ExitCode)"
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

    $unsigned = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes($ExitCode), 0)
    return ('{0} (0x{1:X8})' -f $ExitCode, $unsigned)
}

function Set-TlsSecurityProtocol {
    # Purpose: enable modern TLS protocols before any Windows bootstrap HTTP request runs.
    # Input: the current .NET ServicePointManager state.
    # Output: updates the process security protocol flags to include TLS 1.2 and TLS 1.3 when available.
    $protocol = [Net.SecurityProtocolType]::Tls12
    if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $protocol = $protocol -bor [Net.SecurityProtocolType]::Tls13
    }

    [Net.ServicePointManager]::SecurityProtocol = $protocol
}

function Get-RemoteText {
    # Purpose: fetch UTF-8 text over HTTPS for Windows bootstrap metadata without depending on one fragile transport.
    # Input: a URL string plus an optional label for diagnostics.
    # Output: returns the fetched response body text or throws after all supported transports fail.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Label = 'remote text request'
    )

    Set-TlsSecurityProtocol

    try {
        return (Invoke-WebRequest -UseBasicParsing -Uri $Uri).Content
    }
    catch {
        Write-Host ("Invoke-WebRequest failed for {0}: {1}" -f $Label, $_.Exception.Message) -ForegroundColor Yellow
    }

    $webClient = New-Object System.Net.WebClient
    try {
        return $webClient.DownloadString($Uri)
    }
    catch {
        throw ("{0} failed for {1}: {2}" -f $Label, $Uri, $_.Exception.Message)
    }
    finally {
        $webClient.Dispose()
    }
}

function Download-RemoteFile {
    # Purpose: download a Windows bootstrap installer or helper script robustly even when one HTTP client path is unreliable.
    # Input: a URL string, a destination file path, and an optional diagnostic label.
    # Output: writes the file to disk or throws after Invoke-WebRequest, curl, and WebClient all fail.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [string]$Label = 'remote file download'
    )

    Ensure-ParentDirectory -Path $DestinationPath
    Set-TlsSecurityProtocol

    $curlPath = Resolve-CommandPath -Names @('curl.exe', 'curl')
    if (-not [string]::IsNullOrWhiteSpace($curlPath)) {
        try {
            Invoke-NativeCommand -Label "$Label via curl" -FilePath $curlPath -Arguments @(
                '--fail',
                '--location',
                '--silent',
                '--show-error',
                '--output', $DestinationPath,
                $Uri
            )
            if ((Test-Path $DestinationPath) -and ((Get-Item $DestinationPath).Length -gt 0)) {
                return
            }
            throw "curl created an empty file for $Uri"
        }
        catch {
            if ((Test-Path $DestinationPath) -and ((Get-Item $DestinationPath).Length -eq 0)) {
                Remove-Item -Force $DestinationPath
            }
            Write-Host ("curl failed for {0}: {1}" -f $Label, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $DestinationPath
        if ((Test-Path $DestinationPath) -and ((Get-Item $DestinationPath).Length -gt 0)) {
            return
        }
        throw "Invoke-WebRequest created an empty file for $Uri"
    }
    catch {
        if ((Test-Path $DestinationPath) -and ((Get-Item $DestinationPath).Length -eq 0)) {
            Remove-Item -Force $DestinationPath
        }
        Write-Host ("Invoke-WebRequest failed for {0}: {1}" -f $Label, $_.Exception.Message) -ForegroundColor Yellow
    }

    $webClient = New-Object System.Net.WebClient
    try {
        $webClient.DownloadFile($Uri, $DestinationPath)
        if ((Test-Path $DestinationPath) -and ((Get-Item $DestinationPath).Length -gt 0)) {
            return
        }
        throw "WebClient created an empty file for $Uri"
    }
    catch {
        if ((Test-Path $DestinationPath) -and ((Get-Item $DestinationPath).Length -eq 0)) {
            Remove-Item -Force $DestinationPath
        }
        throw ("{0} failed for {1}: {2}" -f $Label, $Uri, $_.Exception.Message)
    }
    finally {
        $webClient.Dispose()
    }
}

function Get-RemoteJson {
    # Purpose: fetch JSON metadata for Windows bootstrap decisions through the shared resilient downloader.
    # Input: a URL string plus an optional label for diagnostics.
    # Output: returns the decoded PowerShell object graph from the remote JSON payload.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Label = 'remote JSON request'
    )

    $jsonText = Get-RemoteText -Uri $Uri -Label $Label
    return ($jsonText | ConvertFrom-Json)
}

function Get-WindowsBootstrapArchitecture {
    # Purpose: resolve the effective Windows CPU architecture for bootstrap package selection.
    # Input: the current process and WOW64 environment variables exposed by Windows.
    # Output: returns one of arm64, x64, or x86.
    $rawArchitecture = @(
        $env:PROCESSOR_ARCHITEW6432,
        $env:PROCESSOR_ARCHITECTURE
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($rawArchitecture)) {
        $rawArchitecture = ''
    }

    switch ($rawArchitecture.ToUpperInvariant()) {
        'ARM64' { return 'arm64' }
        'AMD64' { return 'x64' }
        'X86'   { return 'x86' }
        default {
            if ([Environment]::Is64BitOperatingSystem) {
                return 'x64'
            }
            return 'x86'
        }
    }
}

function Add-ProcessPathSegment {
    # Purpose: prepend one directory to the current process PATH once without duplication.
    # Input: one directory path string.
    # Output: returns nothing after PATH is updated in-process when needed.
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathSegment
    )

    if ([string]::IsNullOrWhiteSpace($PathSegment) -or -not (Test-Path $PathSegment)) {
        return
    }

    $currentSegments = @()
    if (-not [string]::IsNullOrWhiteSpace($env:PATH)) {
        $currentSegments = $env:PATH -split ';'
    }
    if ($currentSegments -contains $PathSegment) {
        return
    }

    $env:PATH = if ($currentSegments.Count -gt 0) {
        "$PathSegment;$env:PATH"
    }
    else {
        $PathSegment
    }
}

function Resolve-StrawberryPerlMsiUrl {
    # Purpose: resolve the latest supported Strawberry Perl MSI URL from the official release feed.
    # Input: none.
    # Output: returns an https MSI URL string or throws when no supported release is available for the active Windows architecture.
    $bootstrapArchitecture = Get-WindowsBootstrapArchitecture
    $wantedArchname = switch ($bootstrapArchitecture) {
        'arm64' { 'MSWin32-x64-multi-thread' }
        'x64'   { 'MSWin32-x64-multi-thread' }
        default { 'MSWin32-x86-multi-thread-64int' }
    }
    $releases = Get-RemoteJson -Uri 'https://strawberryperl.com/releases.json' -Label 'Strawberry Perl releases feed'
    foreach ($release in $releases) {
        if ($release.archname -ne $wantedArchname) {
            continue
        }

        $url = $release.edition.msi.url
        if (-not [string]::IsNullOrWhiteSpace($url)) {
            return $url
        }
    }

    throw "Unable to resolve a Strawberry Perl MSI URL for Windows architecture $bootstrapArchitecture from the official release feed."
}

function Resolve-GitForWindowsInstallerUrl {
    # Purpose: resolve the current Git for Windows installer URL for the active Windows architecture from the latest release page.
    # Input: none.
    # Output: returns an https EXE URL string or throws when the latest release page no longer exposes the expected asset.
    Set-TlsSecurityProtocol

    $bootstrapArchitecture = Get-WindowsBootstrapArchitecture
    $releaseUrl = 'https://github.com/git-for-windows/git/releases/latest'
    $releasePage = ''
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $releaseUrl
        $releasePage = $response.Content
        if ($response.BaseResponse -and $response.BaseResponse.ResponseUri) {
            $releaseUrl = $response.BaseResponse.ResponseUri.AbsoluteUri
        }
    }
    catch {
        $releasePage = Get-RemoteText -Uri $releaseUrl -Label 'Git for Windows latest release page'
    }

    $assetPattern = if ($bootstrapArchitecture -eq 'arm64') {
        'Git-[0-9][^"''<]*-arm64\.exe'
    }
    else {
        'Git-[0-9][^"''<]*-64-bit\.exe'
    }

    if ($releasePage -match $assetPattern) {
        $assetName = $matches[0]
        if ($releaseUrl -match '/tag/([^/?#]+)') {
            return ('https://github.com/git-for-windows/git/releases/download/{0}/{1}' -f $matches[1], $assetName)
        }
    }

    throw "Unable to resolve the latest Git for Windows installer URL for Windows architecture $bootstrapArchitecture from the release page."
}

function Resolve-NodeLtsPackage {
    # Purpose: resolve the latest supported Node.js LTS package for the active Windows architecture.
    # Input: none.
    # Output: returns a hash table describing the official package kind, url, version, and architecture.
    $bootstrapArchitecture = Get-WindowsBootstrapArchitecture
    $releases = Get-RemoteJson -Uri 'https://nodejs.org/dist/index.json' -Label 'Node.js release index'
    foreach ($release in $releases) {
        if (-not $release.lts) {
            continue
        }

        if ($bootstrapArchitecture -eq 'arm64') {
            if ($release.files -contains 'win-arm64-zip') {
                return @{
                    kind         = 'zip'
                    architecture = 'arm64'
                    version      = $release.version
                    url          = ('https://nodejs.org/dist/{0}/node-{1}-win-arm64.zip' -f $release.version, $release.version)
                }
            }
        }
        else {
            if ($release.files -contains 'win-x64-msi') {
                return @{
                    kind         = 'msi'
                    architecture = 'x64'
                    version      = $release.version
                    url          = ('https://nodejs.org/dist/{0}/node-{1}-x64.msi' -f $release.version, $release.version)
                }
            }
        }
    }

    throw "Unable to resolve a supported Node.js LTS package for Windows architecture $bootstrapArchitecture from the official release index."
}

function Install-PortableNodeZip {
    # Purpose: install the official Node.js Windows ZIP fallback into the user-space dashboard runtime root.
    # Input: the downloaded Node.js ZIP path plus the dashboard install root.
    # Output: returns the stable node bin directory path after extraction and PATH activation.
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstallRoot
    )

    $extractRoot = Join-Path $TargetInstallRoot 'nodejs'
    if (Test-Path $extractRoot) {
        Remove-Item -Recurse -Force $extractRoot
    }
    $null = New-Item -ItemType Directory -Path $extractRoot -Force

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force
    $nodeRoot = Get-ChildItem -Path $extractRoot -Directory | Select-Object -First 1
    if (-not $nodeRoot) {
        throw "Node.js ZIP fallback at $ZipPath did not extract a runtime directory"
    }

    $nodeBin = $nodeRoot.FullName
    Add-ProcessPathSegment -PathSegment $nodeBin
    return $nodeBin
}

function Install-WindowsPackageFallback {
    # Purpose: install a required Windows bootstrap package directly from the official vendor download when winget source metadata is broken.
    # Input: package id and user-facing label.
    # Output: downloads and installs the package or throws if no fallback is available.
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) 'developer-dashboard-bootstrap'
    Ensure-ParentDirectory -Path (Join-Path $tempRoot 'bootstrap.marker')
    $installerPath = ''
    $arguments = @()
    $installLabel = ''

    switch ($PackageId) {
        'Git.Git' {
            $uri = Resolve-GitForWindowsInstallerUrl
            $installerPath = Join-Path $tempRoot 'Git-64-bit.exe'
            Write-Host "Downloading official Git for Windows installer to $installerPath"
            Download-RemoteFile -Uri $uri -DestinationPath $installerPath -Label 'Git for Windows fallback installer download'
            $arguments = @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-')
            $installLabel = 'Git for Windows fallback installer'
        }
        'StrawberryPerl.StrawberryPerl' {
            $uri = Resolve-StrawberryPerlMsiUrl
            $installerPath = Join-Path $tempRoot ([IO.Path]::GetFileName($uri))
            Write-Host "Downloading official Strawberry Perl MSI to $installerPath"
            Download-RemoteFile -Uri $uri -DestinationPath $installerPath -Label 'Strawberry Perl fallback installer download'
            $arguments = @('/i', $installerPath, '/qn', '/norestart')
            $installLabel = 'Strawberry Perl fallback installer'
            Invoke-InstallerCommand -Label $installLabel -FilePath 'msiexec.exe' -Arguments $arguments
            return
        }
        'OpenJS.NodeJS.LTS' {
            $nodePackage = Resolve-NodeLtsPackage
            $uri = $nodePackage.url
            $installerPath = Join-Path $tempRoot ([IO.Path]::GetFileName($uri))
            Write-Host "Downloading official Node.js LTS MSI to $installerPath"
            Download-RemoteFile -Uri $uri -DestinationPath $installerPath -Label 'Node.js LTS fallback installer download'
            if ($nodePackage.kind -eq 'zip') {
                Install-PortableNodeZip -ZipPath $installerPath -TargetInstallRoot $InstallRoot | Out-Null
                return
            }
            $arguments = @('/i', $installerPath, '/qn', '/norestart')
            $installLabel = 'Node.js LTS fallback installer'
            Invoke-InstallerCommand -Label $installLabel -FilePath 'msiexec.exe' -Arguments $arguments
            return
        }
        default {
            throw "No official fallback installer is defined for $Label ($PackageId)"
        }
    }

    Invoke-InstallerCommand -Label $installLabel -FilePath $installerPath -Arguments $arguments
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
            Write-Host ("winget install failed again for {0}: {1}" -f $PackageId, (Format-ExitCode -ExitCode $retryExitCode)) -ForegroundColor Yellow
            Write-Host "Falling back to the official $Label installer because winget source metadata is still broken." -ForegroundColor Yellow
            Install-WindowsPackageFallback -PackageId $PackageId -Label $Label
        }
    }

    Refresh-ProcessPathFromEnvironment
    $resolved = Resolve-CommandPath -Names $CommandNames
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "Installed Windows package did not expose command on PATH: $Label ($PackageId)"
    }

    return $resolved
}

function Resolve-DefaultDashboardCheckout {
    # Purpose: materialize the current GitHub master source into a local checkout for streamed Windows installs.
    # Input: a writable temp directory plus the canonical Developer Dashboard Git repository URL.
    # Output: returns the local checkout path that cpanm should install when no explicit target override is set.
    $gitPath = Resolve-CommandPath -Names @('git.exe', 'git')
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        throw 'git is required before resolving the default Windows checkout bootstrap target'
    }

    $checkoutRoot = Join-Path ([IO.Path]::GetTempPath()) 'developer-dashboard-install'
    if (Test-Path $checkoutRoot) {
        Remove-Item -Recurse -Force $checkoutRoot
    }

    Invoke-NativeCommand -Label 'git clone Developer Dashboard checkout' -FilePath $gitPath -Arguments @(
        'clone',
        '--depth', '1',
        '--branch', 'master',
        $DefaultBootstrapRepository,
        $checkoutRoot
    )
    return $checkoutRoot
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

function Ensure-GnuMakeCommand {
    # Purpose: expose a stable GNU make command for Windows skills that ship Makefiles.
    # Input: the user-space install root where stable helper shims should live.
    # Output: creates or refreshes a make.cmd shim that delegates to the Strawberry GNU make provider.
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetInstallRoot
    )

    $makeProvider = Resolve-CommandPath -Names @(
        'gmake.exe',
        'gmake',
        'mingw32-make.exe',
        'mingw32-make',
        'make.exe',
        'make'
    )
    if ([string]::IsNullOrWhiteSpace($makeProvider)) {
        throw 'Unable to resolve a GNU make provider after Strawberry Perl bootstrap'
    }

    $shimDir = Join-Path $TargetInstallRoot 'bin'
    if (-not (Test-Path $shimDir)) {
        $null = New-Item -ItemType Directory -Path $shimDir -Force
    }

    $shimPath = Join-Path $shimDir 'make.cmd'
    $shimContent = @(
        '@echo off',
        ('"{0}" %*' -f $makeProvider)
    ) -join [Environment]::NewLine
    Set-Content -Path $shimPath -Value ($shimContent + [Environment]::NewLine) -Encoding ASCII
}

function Ensure-NodeToolchain {
    # Purpose: make sure node, npm, and npx all exist before d2 skills need package.json support.
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
    # Purpose: keep exactly one managed Developer Dashboard bootstrap block in the PowerShell profile.
    # Input: the profile path, the literal block text, and a stable marker label that brackets the managed block.
    # Output: creates the profile file when needed, replaces any older managed block, and appends the current block once.
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetProfile,
        [Parameter(Mandatory = $true)]
        [string]$Block,
        [Parameter(Mandatory = $true)]
        [string]$Marker
    )

    Ensure-ParentDirectory -Path $TargetProfile
    if (-not (Test-Path $TargetProfile)) {
        Set-Content -Path $TargetProfile -Value '' -Encoding UTF8
    }

    $existing = Get-Content -Path $TargetProfile -Raw
    $beginMarker = "# >>> $Marker >>>"
    $endMarker = "# <<< $Marker <<<"
    $beginMarkerPattern = [Regex]::Escape($beginMarker)
    $endMarkerPattern = [Regex]::Escape($endMarker)
    $managedPattern = "(?ms)$beginMarkerPattern.*?$endMarkerPattern\s*"
    $legacyManagedPattern = '(?ms)^# Developer Dashboard bootstrap\r?\n.*?(?=^\s*$|\z)'
    $sanitized = [Regex]::Replace($existing, $managedPattern, '')
    $sanitized = [Regex]::Replace($sanitized, $legacyManagedPattern, '')
    $sanitized = $sanitized.TrimEnd()

    if ($sanitized -eq $Block) {
        return
    }

    $combined = if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $Block
    }
    else {
        $sanitized + [Environment]::NewLine + [Environment]::NewLine + $Block
    }

    Set-Content -Path $TargetProfile -Value ($combined + [Environment]::NewLine) -Encoding UTF8
}

function Assert-ValidPowerShellCache {
    # Purpose: reject a missing, empty, or syntactically invalid generated PowerShell startup cache.
    # Input: cache file path and a human-readable cache label.
    # Output: returns nothing when valid and throws with a refresh instruction otherwise.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -le 0) {
        throw "PowerShell startup cache generation failed: $Label is missing or empty at $Path. Run 'd2 shell ps' to refresh the cache files."
    }

    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell startup cache generation failed: $Label is invalid at $Path ($messages). Run 'd2 shell ps' to refresh the cache files."
    }
}

function Ensure-CurrentUserPowerShellExecutionPolicy {
    # Purpose: make sure the current user can load the generated PowerShell profile script in future sessions.
    # Input: the current-user PowerShell execution policy state.
    # Output: sets the CurrentUser execution policy to RemoteSigned when it is undefined or restricted.
    $currentUserPolicy = Get-ExecutionPolicy -Scope CurrentUser
    if ($currentUserPolicy -in @('RemoteSigned', 'Unrestricted', 'Bypass')) {
        return $currentUserPolicy
    }

    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'ExecutionPolicyOverride*') {
            throw
        }
        Write-Host 'Current PowerShell session already overrides execution policy; kept the saved CurrentUser policy and continued.'
    }
    return (Get-ExecutionPolicy -Scope CurrentUser)
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
    Download-RemoteFile -Uri 'https://cpanmin.us/' -DestinationPath $cpanmScript -Label 'cpanm bootstrap script download'
    return $cpanmScript
}

function Set-EnvironmentValue {
    # Purpose: update a process environment variable in one place.
    # Input: an environment variable name and the value it should carry for this PowerShell process.
    # Output: writes the process-scoped environment value and returns nothing.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    Set-Item -Path ("Env:{0}" -f $Name) -Value $Value
}

function Sync-LocalLibEnvironmentFromPerl {
    # Purpose: ask perl local::lib for the canonical Windows environment block instead of hand-assembling INSTALL_BASE values.
    # Input: a resolved perl executable path plus the install root where local::lib should live.
    # Output: refreshes PATH, PERL5LIB, PERL_LOCAL_LIB_ROOT, PERL_MB_OPT, and PERL_MM_OPT for the current PowerShell process.
    param(
        [Parameter(Mandatory = $true)]
        [string]$PerlPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetInstallRoot
    )

    $libDir = Join-Path $TargetInstallRoot 'lib\perl5'
    $normalizedInstallRoot = $TargetInstallRoot -replace '\\', '/'
$dumpCode = @'
for my $key (qw(PATH PERL5LIB PERL_LOCAL_LIB_ROOT PERL_MB_OPT PERL_MM_OPT)) {
    next unless exists $ENV{$key};
    print $key, q(=), $ENV{$key}, chr(10);
}
'@
    $lines = & $PerlPath "-I$libDir" "-Mlocal::lib=$normalizedInstallRoot" '-e' $dumpCode
    if ($LASTEXITCODE -ne 0) {
        throw "perl local::lib environment sync failed with exit code $LASTEXITCODE"
    }

    foreach ($line in $lines) {
        if ($line -match '^([^=]+)=(.*)$') {
            Set-EnvironmentValue -Name $matches[1] -Value $matches[2]
        }
    }
}

# >>> Jenkins test-node route >>>
# Jenkins test-node setup (install.ps1 -Jenkins, or DD_INSTALL_JENKINS=1
# for the piped form, which cannot take a switch).
#
# Takes a Windows machine to a working test node: Strawberry Perl
# 5.38.2.2 at C:\Strawberry, Java 21, the pinned distributions from
# share\jenkins installed in list order with Strawberry's own cpanm, the
# own tests of the compiled ones, the agent root, and a final check. It
# does not install the dashboard and does not edit any PowerShell
# profile. Nothing on this route runs unless it is asked for: without
# the switch and without the variable the installer goes on exactly as
# it did before this route existed.
$JenkinsStrawberryRoot = 'C:\Strawberry'
$JenkinsPerlNumber = '5.038002'
$JenkinsPerlShort = '5.38.2'
$JenkinsStrawberryBuild = '5.38.2.2'
$JenkinsStrawberryMsiName = 'strawberry-perl-5.38.2.2-64bit.msi'
$JenkinsCpanmVersion = '1.7049'
$JenkinsGitVersionFull = '2.56.1.windows.1'
$JenkinsGitInstallerName = 'Git-2.56.1-64-bit.exe'
# Pinned directly, never resolved from the releases page: the bootstrap
# resolver that follows 'latest' must not be used for the Jenkins node.
$JenkinsGitInstallerUrl = 'https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1/Git-2.56.1-64-bit.exe'
$JenkinsJavaMajor = '21'
$JenkinsKeyModules = @('Net::SSLeay', 'JSON::XS', 'Test::Pod')
$JenkinsTestOnlyHelpers = @('B::COW')
$JenkinsDistributionPattern = '^[A-Z]/[A-Z]{2}/[A-Z0-9-]+/[A-Za-z0-9._-]+\.tar\.gz$'
$JenkinsPerlPath = Join-Path $JenkinsStrawberryRoot 'perl\bin\perl.exe'
$JenkinsCpanmPath = Join-Path $JenkinsStrawberryRoot 'perl\bin\cpanm'
$JenkinsSiteCpanmPath = Join-Path $JenkinsStrawberryRoot 'perl\site\bin\cpanm'
$JenkinsTestedStamp = Join-Path $JenkinsStrawberryRoot 'perl\.jenkins-compiled-tests-passed'
$JenkinsWork = ''

function Test-JenkinsRequested {
    # Purpose: decide whether this run is the Jenkins test-node route.
    # Input: the arguments given to install.ps1 and the DD_INSTALL_JENKINS environment variable.
    # Output: returns $true for -Jenkins or DD_INSTALL_JENKINS=1, $false when neither is given, and throws for any other value of the variable.
    param(
        [AllowNull()]
        [object[]]$Arguments
    )

    foreach ($argument in @($Arguments)) {
        if ([string]$argument -ieq '-Jenkins') {
            return $true
        }
    }

    $flag = $env:DD_INSTALL_JENKINS
    if ([string]::IsNullOrWhiteSpace($flag)) {
        return $false
    }
    if ($flag.Trim() -eq '1') {
        return $true
    }

    throw "install.ps1: DD_INSTALL_JENKINS must be 1 or unset, not '$flag'. Nothing was installed or changed."
}

function Write-JenkinsLine {
    # Purpose: print one progress line for the Jenkins test-node route.
    # Input: the message text.
    # Output: writes the prefixed line to the terminal and returns nothing.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "install.ps1 -Jenkins: $Message"
}

function Test-JenkinsCommandSucceeds {
    # Purpose: run a short native check quietly and report whether it exited with zero.
    # Input: an executable path and its argument array.
    # Output: returns $true when the command exits with zero, otherwise $false.
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-JenkinsCpanm {
    # Purpose: run the pinned cpanm with standard input closed so no build can stop to ask a question.
    # Input: a label for diagnostics and the cpanm argument array.
    # Output: streams the cpanm output and throws on a non-zero exit status.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $commandLine = ('{0} {1} {2} < NUL' -f $JenkinsPerlPath, $script:JenkinsCpanmPath, ($Arguments -join ' '))
    Invoke-NativeCommand -Label $Label -FilePath 'cmd.exe' -Arguments @('/d', '/c', $commandLine)
}

function Resolve-JenkinsStrawberryMsiUrl {
    # Purpose: find the download address of the one pinned Strawberry Perl installer in the official release feed.
    # Input: none.
    # Output: returns the https MSI URL whose file name is the pinned installer, or throws when the feed does not list it.
    $releases = Get-RemoteJson -Uri 'https://strawberryperl.com/releases.json' -Label 'Strawberry Perl releases feed'
    foreach ($release in $releases) {
        $url = ''
        try {
            $url = [string]$release.edition.msi.url
        }
        catch {
            continue
        }
        if ($url.EndsWith('/' + $JenkinsStrawberryMsiName)) {
            return $url
        }
    }

    throw "The official Strawberry Perl release feed does not list $JenkinsStrawberryMsiName."
}

function Assert-JenkinsPerlVersion {
    # Purpose: refuse to go on unless the Perl at the pinned path is exactly the pinned Strawberry Perl.
    # Input: none; reads the pinned perl.exe path.
    # Output: returns nothing when the Perl is right and throws otherwise.
    if (-not (Test-Path -LiteralPath $JenkinsPerlPath -PathType Leaf)) {
        throw "Missing $JenkinsPerlPath"
    }

    $versionCode = 'exit($] == ' + $JenkinsPerlNumber + ' ? 0 : 1)'
    if (-not (Test-JenkinsCommandSucceeds -FilePath $JenkinsPerlPath -Arguments @('-e', $versionCode))) {
        throw "$JenkinsPerlPath is not Perl $JenkinsPerlShort; refusing to go on"
    }

    $buildCode = 'exit(index($Config{myuname}, q(strawberry-perl ' + $JenkinsStrawberryBuild + ')) >= 0 ? 0 : 1)'
    if (-not (Test-JenkinsCommandSucceeds -FilePath $JenkinsPerlPath -Arguments @('-MConfig', '-e', $buildCode))) {
        throw "$JenkinsPerlPath is not Strawberry Perl $JenkinsStrawberryBuild; refusing to go on"
    }
}

function Install-JenkinsStrawberryPerl {
    # Purpose: make sure the pinned Strawberry Perl is at the pinned root, installing it only when nothing is there.
    # Input: none; reads the pinned root, installer name and work folder.
    # Output: returns nothing after the pinned Perl is present, checked and on PATH; throws otherwise.
    if (Test-Path -LiteralPath $JenkinsPerlPath -PathType Leaf) {
        Write-JenkinsLine -Message "a Perl is already at $JenkinsStrawberryRoot"
    }
    else {
        if (Test-Path -LiteralPath $JenkinsStrawberryRoot) {
            throw "$JenkinsStrawberryRoot exists but holds no perl\bin\perl.exe; refusing to install over it"
        }
        Write-JenkinsLine -Message "installing Strawberry Perl $JenkinsStrawberryBuild to $JenkinsStrawberryRoot"
        $msiUrl = Resolve-JenkinsStrawberryMsiUrl
        $msiPath = Join-Path $JenkinsWork $JenkinsStrawberryMsiName
        Download-RemoteFile -Uri $msiUrl -DestinationPath $msiPath -Label 'Strawberry Perl pinned installer download'
        Invoke-InstallerCommand -Label 'Strawberry Perl pinned installer' -FilePath 'msiexec.exe' -Arguments @('/i', $msiPath, '/qn', '/norestart')
    }

    Assert-JenkinsPerlVersion
    Add-StrawberryPaths -PerlPath $JenkinsPerlPath
    if (-not (Test-Path -LiteralPath $script:JenkinsCpanmPath -PathType Leaf)) {
        throw "Strawberry's own cpanm is missing at $JenkinsCpanmPath"
    }
}

function Test-JenkinsGitVersion {
    # Purpose: say whether one git.exe reports the pinned Git for Windows version.
    # Input: a git.exe path.
    # Output: returns $true when it runs and reports 2.56.1.windows.1, otherwise $false.
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitPath
    )

    $versionText = ''
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $versionText = (& $GitPath '--version' 2>&1 | ForEach-Object { [string]$_ }) -join ' '
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return ($versionText -match ('git version ' + [Regex]::Escape($JenkinsGitVersionFull)))
}

function Resolve-JenkinsGitPath {
    # Purpose: find a git.exe that reports the pinned Git for Windows version.
    # Input: none; looks on PATH and at the default Git for Windows install path.
    # Output: returns the git.exe path, or an empty string when there is none.
    $candidates = [System.Collections.Generic.List[string]]::new()
    $gitOnPath = Resolve-CommandPath -Names @('git.exe')
    if (-not [string]::IsNullOrWhiteSpace($gitOnPath)) {
        $null = $candidates.Add($gitOnPath)
    }
    $defaultGitPath = ''
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $defaultGitPath = Join-Path $env:ProgramFiles 'Git\cmd\git.exe'
        $null = $candidates.Add($defaultGitPath)
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        if (Test-JenkinsGitVersion -GitPath $candidate) {
            return $candidate
        }
    }
    return ''
}

function Install-JenkinsGit {
    # Purpose: make sure the pinned Git for Windows is installed, installing it only when no git.exe reports the pinned version.
    # Input: none; reads the pinned installer URL and the work folder.
    # Output: returns the git.exe path that reports the pinned version; throws otherwise.
    $gitPath = Resolve-JenkinsGitPath
    if (-not [string]::IsNullOrWhiteSpace($gitPath)) {
        Write-JenkinsLine -Message "Git $JenkinsGitVersionFull is already installed"
        return $gitPath
    }

    Write-JenkinsLine -Message "installing Git for Windows $JenkinsGitVersionFull"
    $exePath = Join-Path $JenkinsWork $JenkinsGitInstallerName
    Download-RemoteFile -Uri $JenkinsGitInstallerUrl -DestinationPath $exePath -Label 'Git for Windows pinned installer download'
    Invoke-InstallerCommand -Label 'Git for Windows pinned installer' -FilePath $exePath -Arguments @('/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES')

    $gitPath = Resolve-JenkinsGitPath
    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        throw "Git $JenkinsGitVersionFull was not found after its installer ran"
    }
    return $gitPath
}

function Test-JenkinsJavaVersion {
    # Purpose: say whether one java.exe is the pinned major version.
    # Input: a java.exe path.
    # Output: returns $true when it runs and reports the pinned major version, otherwise $false.
    param(
        [Parameter(Mandatory = $true)]
        [string]$JavaPath
    )

    $versionText = ''
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $versionText = (& $JavaPath '-version' 2>&1 | ForEach-Object { [string]$_ }) -join ' '
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return ($versionText -match ('version "' + $JenkinsJavaMajor + '\.'))
}

function Resolve-JenkinsJavaPath {
    # Purpose: find the Java the agent will run on.
    # Input: the DD_INSTALL_JENKINS_JAVA environment variable, the java21 folder under the user's home directory, and PATH.
    # Output: returns the first java.exe that reports the pinned major version, or throws when there is none.
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:DD_INSTALL_JENKINS_JAVA)) {
        $null = $candidates.Add($env:DD_INSTALL_JENKINS_JAVA)
    }

    $javaFolder = Join-Path (Resolve-HomeDirectory) 'java21'
    if (Test-Path -LiteralPath $javaFolder -PathType Container) {
        foreach ($runtime in @(Get-ChildItem -LiteralPath $javaFolder -Directory)) {
            $null = $candidates.Add((Join-Path $runtime.FullName 'bin\java.exe'))
        }
    }

    $javaOnPath = Resolve-CommandPath -Names @('java.exe')
    if (-not [string]::IsNullOrWhiteSpace($javaOnPath)) {
        $null = $candidates.Add($javaOnPath)
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $isPinnedJava = Test-JenkinsJavaVersion -JavaPath $candidate
        if ($isPinnedJava) {
            return $candidate
        }
    }

    throw "Java $JenkinsJavaMajor was not found. Unpack a Java $JenkinsJavaMajor runtime into the java21 folder under the home directory, or name its java.exe in DD_INSTALL_JENKINS_JAVA."
}

function Resolve-JenkinsListFolder {
    # Purpose: find the folder that holds the pinned lists.
    # Input: the DD_INSTALL_JENKINS_LIST_DIR environment variable and the folder install.ps1 was run from.
    # Output: returns the folder path, or throws when the script was piped and no folder was named.
    if (-not [string]::IsNullOrWhiteSpace($env:DD_INSTALL_JENKINS_LIST_DIR)) {
        return $env:DD_INSTALL_JENKINS_LIST_DIR
    }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return (Join-Path $PSScriptRoot 'share\jenkins')
    }

    throw 'The pinned lists were not found. Run install.ps1 from a checkout, or name the folder that holds them in DD_INSTALL_JENKINS_LIST_DIR.'
}

function Get-JenkinsListLines {
    # Purpose: read one pinned list and refuse any line that is not a plain CPAN distribution file path.
    # Input: the list file path.
    # Output: returns the non-empty lines in file order, or throws when the file is missing or a line is malformed.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing pinned list: $Path"
    }

    $lines = @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    foreach ($line in $lines) {
        if ($line -cnotmatch $JenkinsDistributionPattern) {
            throw "Malformed line in ${Path}: $line"
        }
    }
    return $lines
}

function Get-JenkinsInstalledDistributions {
    # Purpose: read which distribution files cpanm has recorded as installed in the pinned Perl.
    # Input: none; asks the pinned Perl where its site folder is.
    # Output: returns a hash table keyed by distribution file path.
    $siteFolder = ''
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $siteFolder = [string](& $JenkinsPerlPath '-MConfig' '-e' 'print $Config{sitearchexp}')
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($siteFolder)) {
        throw "Unable to ask $JenkinsPerlPath for its site folder"
    }

    $installed = @{}
    $metaFolder = Join-Path $siteFolder '.meta'
    if (Test-Path -LiteralPath $metaFolder -PathType Container) {
        foreach ($record in @(Get-ChildItem -LiteralPath $metaFolder -Recurse -File -Filter 'install.json')) {
            $recordText = [string](Get-Content -LiteralPath $record.FullName -Raw)
            if ($recordText -match '"pathname"\s*:\s*"([^"]+)"') {
                $installed[$matches[1]] = $true
            }
        }
    }
    return $installed
}

function Install-JenkinsPinnedList {
    # Purpose: install the pinned list in list order, one distribution at a time, without running their tests.
    # Input: the list lines in install order.
    # Output: returns nothing; stops at the first distribution that fails to install.
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Distributions
    )

    Write-JenkinsLine -Message ("the {0} pinned distributions, in list order" -f $Distributions.Count)
    $installed = Get-JenkinsInstalledDistributions
    $installedNow = 0
    # Prefer the pinned cpanm from the start when it is already there, as
    # on a second run.
    if (Test-Path -LiteralPath $JenkinsSiteCpanmPath -PathType Leaf) {
        $script:JenkinsCpanmPath = $JenkinsSiteCpanmPath
    }
    foreach ($distribution in $Distributions) {
        if ($installed.ContainsKey($distribution)) {
            continue
        }
        if (Test-Path -LiteralPath $JenkinsTestedStamp) {
            Remove-Item -LiteralPath $JenkinsTestedStamp -Force
        }
        Invoke-JenkinsCpanm -Label "cpanm --notest $distribution" -Arguments @('--notest', $distribution)
        $installedNow++
        Write-Host "OK $distribution"
        # The first line installs the pinned cpanm itself; use it for
        # every line after that.
        if (Test-Path -LiteralPath $JenkinsSiteCpanmPath -PathType Leaf) {
            $script:JenkinsCpanmPath = $JenkinsSiteCpanmPath
        }
    }
    Write-JenkinsLine -Message ("{0} of {1} installed now, the rest were already there" -f $installedNow, $Distributions.Count)
}

function Test-JenkinsCompiledList {
    # Purpose: run the own tests of the distributions that hold compiled code, then remove the test-only helper those tests pull in.
    # Input: the compiled list lines.
    # Output: returns nothing; stops at the first distribution whose own tests fail.
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Distributions
    )

    if (Test-Path -LiteralPath $JenkinsTestedStamp) {
        Write-JenkinsLine -Message 'the compiled distributions already passed their own tests'
        return
    }

    Write-JenkinsLine -Message 'the own tests of the compiled distributions'
    foreach ($distribution in $Distributions) {
        Invoke-JenkinsCpanm -Label "cpanm --test-only $distribution" -Arguments @('--test-only', $distribution)
        Write-Host "TESTED OK $distribution"
    }
    foreach ($helper in $JenkinsTestOnlyHelpers) {
        $helperLoads = Test-JenkinsCommandSucceeds -FilePath $JenkinsPerlPath -Arguments @("-M$helper", '-e', '1')
        if ($helperLoads) {
            Invoke-JenkinsCpanm -Label "cpanm --uninstall $helper" -Arguments @('--uninstall', '-f', $helper)
        }
    }
    Set-Content -LiteralPath $JenkinsTestedStamp -Value 'passed' -Encoding ASCII
}

function New-JenkinsAgentRoot {
    # Purpose: create the folder the Jenkins agent works in, when one was named.
    # Input: the DD_INSTALL_JENKINS_AGENT_ROOT environment variable.
    # Output: returns the folder path, or an empty string when none was named.
    if ([string]::IsNullOrWhiteSpace($env:DD_INSTALL_JENKINS_AGENT_ROOT)) {
        Write-JenkinsLine -Message 'no agent root was named in DD_INSTALL_JENKINS_AGENT_ROOT, so none is created'
        return ''
    }

    $agentRoot = $env:DD_INSTALL_JENKINS_AGENT_ROOT
    if (-not (Test-Path -LiteralPath $agentRoot -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $agentRoot -Force
    }
    return $agentRoot
}

function Assert-JenkinsNodeReady {
    # Purpose: the final check of the Jenkins test-node route.
    # Input: the java.exe path, the git.exe path, the pinned list lines and the agent root (may be empty).
    # Output: returns nothing when Java, Git, the Perl, cpanm, the pinned list, the key modules and the agent root are all right; throws otherwise.
    param(
        [Parameter(Mandatory = $true)]
        [string]$JavaPath,
        [Parameter(Mandatory = $true)]
        [string]$GitPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Distributions,
        [AllowEmptyString()]
        [string]$AgentRoot = ''
    )

    Write-JenkinsLine -Message 'final check'
    $isPinnedJava = Test-JenkinsJavaVersion -JavaPath $JavaPath
    if (-not $isPinnedJava) {
        throw "$JavaPath is not Java $JenkinsJavaMajor"
    }

    $isPinnedGit = Test-JenkinsGitVersion -GitPath $GitPath
    if (-not $isPinnedGit) {
        throw "$GitPath is not Git $JenkinsGitVersionFull"
    }

    Assert-JenkinsPerlVersion

    $cpanmCode = 'exit($App::cpanminus::VERSION == ' + $JenkinsCpanmVersion + ' ? 0 : 1)'
    if (-not (Test-JenkinsCommandSucceeds -FilePath $JenkinsPerlPath -Arguments @('-MApp::cpanminus', '-e', $cpanmCode))) {
        throw "App::cpanminus $JenkinsCpanmVersion does not load in $JenkinsPerlPath"
    }

    $installed = Get-JenkinsInstalledDistributions
    $missing = @($Distributions | Where-Object { -not $installed.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw ("These pinned distributions are not recorded as installed: {0}" -f ($missing -join ', '))
    }

    foreach ($module in $JenkinsKeyModules) {
        if (-not (Test-JenkinsCommandSucceeds -FilePath $JenkinsPerlPath -Arguments @("-M$module", '-e', '1'))) {
            throw "$module does not load in $JenkinsPerlPath"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($AgentRoot) -and -not (Test-Path -LiteralPath $AgentRoot -PathType Container)) {
        throw "Missing agent root $AgentRoot"
    }
}

function Invoke-JenkinsNodeSetup {
    # Purpose: run the whole Jenkins test-node route and end with one DONE or FAILED line.
    # Input: none; reads the pinned settings above and the DD_INSTALL_JENKINS_* environment variables.
    # Output: returns nothing after the DONE line; prints the FAILED line and rethrows on any failure.
    try {
        # A unique work folder per run, mirroring the POSIX side
        # (install.sh creates JENKINS_WORK with mktemp -d): a fixed
        # folder would collide with a stale one from an earlier run.
        # $script: is required here: a bare assignment inside this
        # function would stay local to it and the install steps that
        # read $JenkinsWork would still see the empty string.
        $script:JenkinsWork = Join-Path ([IO.Path]::GetTempPath()) ('developer-dashboard-jenkins-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $JenkinsWork -Force
        $listFolder = Resolve-JenkinsListFolder
        $pinnedList = @(Get-JenkinsListLines -Path (Join-Path $listFolder 'modules-windows.txt'))
        $compiledList = @(Get-JenkinsListLines -Path (Join-Path $listFolder 'modules-compiled-windows.txt'))

        Install-JenkinsStrawberryPerl
        $gitPath = Install-JenkinsGit
        $javaPath = Resolve-JenkinsJavaPath
        Write-JenkinsLine -Message "Java $JenkinsJavaMajor found"
        Install-JenkinsPinnedList -Distributions $pinnedList
        Test-JenkinsCompiledList -Distributions $compiledList
        $agentRoot = New-JenkinsAgentRoot
        Assert-JenkinsNodeReady -JavaPath $javaPath -GitPath $gitPath -Distributions $pinnedList -AgentRoot $agentRoot

        $agentRootText = if ([string]::IsNullOrWhiteSpace($agentRoot)) { 'no agent root named' } else { 'agent root created' }
        Write-JenkinsLine -Message ("DONE. This machine is ready to be a Jenkins test node: Strawberry Perl {0} at {1}, Java {2}, {3} pinned distributions, {4}." -f $JenkinsStrawberryBuild, $JenkinsStrawberryRoot, $JenkinsJavaMajor, $pinnedList.Count, $agentRootText)
    }
    catch {
        Write-Host ("install.ps1 -Jenkins: FAILED ({0}). This machine is not ready to be a Jenkins test node." -f $_.Exception.Message) -ForegroundColor Red
        throw
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($JenkinsWork) -and (Test-Path -LiteralPath $JenkinsWork)) {
            Remove-Item -LiteralPath $JenkinsWork -Recurse -Force
        }
    }
}

if (Test-JenkinsRequested -Arguments $args) {
    Invoke-JenkinsNodeSetup
    return
}
# <<< Jenkins test-node route <<<

Show-ProgressBoard

Set-StepStatus -Id 'detect_profile' -Status 'running'
Ensure-ParentDirectory -Path $ProfilePath
$currentUserExecutionPolicy = Ensure-CurrentUserPowerShellExecutionPolicy
Set-StepStatus -Id 'detect_profile' -Status 'ok' -Detail ("profile: {0}; policy: {1}" -f $ProfilePath, $currentUserExecutionPolicy)

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
Invoke-NativeCommand -Label 'cpanm local::lib bootstrap' -FilePath $perlPath -Arguments @(
    $cpanmScript,
    '--notest',
    '--local-lib-contained', $InstallRoot,
    'local::lib',
    'File::ShareDir::Install'
)
Sync-LocalLibEnvironmentFromPerl -PerlPath $perlPath -TargetInstallRoot $InstallRoot
Ensure-GnuMakeCommand -TargetInstallRoot $InstallRoot

$profilePerlBin = Split-Path -Parent $perlPath
$profilePerlRoot = Split-Path -Parent $profilePerlBin
$profileStrawberryRoot = Split-Path -Parent $profilePerlRoot
$profilePerlRuntimePaths = @(
    $profilePerlBin,
    (Join-Path $profilePerlRoot 'site\bin'),
    (Join-Path $profileStrawberryRoot 'c\bin')
) | Select-Object -Unique
$profileExtraRuntimePaths = @()
if (Test-Path (Join-Path $InstallRoot 'nodejs')) {
    $profileExtraRuntimePaths += Get-ChildItem -Path (Join-Path $InstallRoot 'nodejs') -Directory | ForEach-Object { $_.FullName }
}
$profileExtraRuntimePaths = $profileExtraRuntimePaths | Select-Object -Unique
$profilePerlRuntimePathLines = ($profilePerlRuntimePaths | ForEach-Object { "    '{0}'" -f $_ }) -join [Environment]::NewLine
$profileExtraRuntimePathLines = ($profileExtraRuntimePaths | ForEach-Object { "    '{0}'" -f $_ }) -join [Environment]::NewLine
$profileRuntimeHome = $env:HOME

$profileBlock = @"
# >>> Developer Dashboard bootstrap >>>
`$ddInstallRoot = '$InstallRoot'
`$ddPerlBin = Join-Path `$ddInstallRoot 'bin'
if ([string]::IsNullOrWhiteSpace(`$env:HOME) -and -not [string]::IsNullOrWhiteSpace(`$HOME)) {
    `$env:HOME = `$HOME
}
if ([string]::IsNullOrWhiteSpace(`$env:HOME)) {
    `$env:HOME = '$profileRuntimeHome'
}
`$ddPerlRuntimePaths = @(
$profilePerlRuntimePathLines
)
`$ddExtraRuntimePaths = @(
$profileExtraRuntimePathLines
)
`$ddCacheRoot = Join-Path `$env:HOME '.developer-dashboard\cache'
`$ddEnvironmentCache = Join-Path `$ddCacheRoot 'powershell-env.ps1'
`$ddBootstrapCache = Join-Path `$ddCacheRoot 'powershell-bootstrap.ps1'
if (Test-Path `$ddPerlBin) {
    if (`$env:PATH -notlike "*`$ddPerlBin*") {
        `$env:PATH = "`$ddPerlBin;`$env:PATH"
    }
}
foreach (`$ddPerlRuntimePath in `$ddPerlRuntimePaths) {
    if (-not [string]::IsNullOrWhiteSpace(`$ddPerlRuntimePath) -and (Test-Path `$ddPerlRuntimePath) -and `$env:PATH -notlike "*`$ddPerlRuntimePath*") {
        `$env:PATH = "`$ddPerlRuntimePath;`$env:PATH"
    }
}
foreach (`$ddExtraRuntimePath in `$ddExtraRuntimePaths) {
    if (-not [string]::IsNullOrWhiteSpace(`$ddExtraRuntimePath) -and (Test-Path `$ddExtraRuntimePath) -and `$env:PATH -notlike "*`$ddExtraRuntimePath*") {
        `$env:PATH = "`$ddExtraRuntimePath;`$env:PATH"
    }
}
if ((Test-Path -LiteralPath `$ddEnvironmentCache -PathType Leaf) -and
    (Test-Path -LiteralPath `$ddBootstrapCache -PathType Leaf) -and
    ((Get-Item -LiteralPath `$ddEnvironmentCache).Length -gt 0) -and
    ((Get-Item -LiteralPath `$ddBootstrapCache).Length -gt 0)) {
    try {
        . `$ddEnvironmentCache
        . `$ddBootstrapCache
    }
    catch {
        Write-Warning "Developer Dashboard PowerShell startup cache files could not be loaded. Run 'd2 shell ps' to refresh them. `$(`$_.Exception.Message)"
    }
}
else {
    Write-Warning "Developer Dashboard PowerShell startup cache files are missing or empty. Run 'd2 shell ps' to refresh them."
}
# <<< Developer Dashboard bootstrap <<<
"@
Set-StepStatus -Id 'bootstrap_perl' -Status 'ok' -Detail 'cpanm, local::lib, GNU make, and configure prereqs ready'

$dashboardCommand = Resolve-CommandPath -Names @('d2.bat', 'd2', 'd2.cmd')
if ([string]::IsNullOrWhiteSpace($dashboardCommand)) {
    $candidate = Join-Path $InstallRoot 'bin\d2.bat'
    if (Test-Path $candidate) {
        $dashboardCommand = $candidate
    }
}

Set-StepStatus -Id 'install_dashboard' -Status 'running'
$effectiveCpanTarget = $CpanTarget
if ([string]::IsNullOrWhiteSpace($effectiveCpanTarget)) {
    $effectiveCpanTarget = Resolve-DefaultDashboardCheckout
    Push-Location $effectiveCpanTarget
    try {
        Invoke-NativeCommand -Label 'cpanm Developer Dashboard install' -FilePath $perlPath -Arguments @(
            $cpanmScript,
            '--notest',
            '--local-lib-contained', $InstallRoot,
            '.'
        )
    }
    finally {
        Pop-Location
    }
}
else {
    Invoke-NativeCommand -Label 'cpanm Developer Dashboard install' -FilePath $perlPath -Arguments @(
        $cpanmScript,
        '--notest',
        '--local-lib-contained', $InstallRoot,
        $effectiveCpanTarget
    )
}
$dashboardCommand = Resolve-CommandPath -Names @('d2.bat', 'd2', 'd2.cmd')
if ([string]::IsNullOrWhiteSpace($dashboardCommand)) {
    $candidate = Join-Path $InstallRoot 'bin\d2.bat'
    if (-not (Test-Path $candidate)) {
        throw 'Developer Dashboard installed but d2 command is still unavailable on PATH'
    }
    $dashboardCommand = $candidate
}
Set-StepStatus -Id 'install_dashboard' -Status 'ok' -Detail ("target: {0}" -f $effectiveCpanTarget)

Set-StepStatus -Id 'initialize_dashboard' -Status 'running'
Invoke-NativeCommand -Label 'd2 init' -FilePath $dashboardCommand -Arguments @('init')
$dashboardShellBootstrap = & $perlPath $dashboardCommand shell ps
$dashboardShellBootstrapText = Join-ScriptText -Value $dashboardShellBootstrap
$powershellCacheRoot = Join-Path $env:HOME '.developer-dashboard\cache'
$powershellEnvironmentCache = Join-Path $powershellCacheRoot 'powershell-env.ps1'
$powershellBootstrapCache = Join-Path $powershellCacheRoot 'powershell-bootstrap.ps1'
if (-not (Test-Path -LiteralPath $powershellEnvironmentCache -PathType Leaf) -or
    -not (Test-Path -LiteralPath $powershellBootstrapCache -PathType Leaf)) {
    throw "PowerShell startup cache generation failed. Run 'd2 shell ps' to refresh the cache files."
}
Assert-ValidPowerShellCache -Path $powershellEnvironmentCache -Label 'environment cache'
Assert-ValidPowerShellCache -Path $powershellBootstrapCache -Label 'shell bootstrap cache'
Ensure-ProfileContains -TargetProfile $ProfilePath -Block $profileBlock -Marker 'Developer Dashboard bootstrap'
if (-not [string]::IsNullOrWhiteSpace($dashboardShellBootstrapText)) {
    Invoke-Expression $dashboardShellBootstrapText
}
if (-not [string]::IsNullOrWhiteSpace($ShellCommands)) {
    Write-Host 'Running post-install activation commands through PowerShell.'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ". '$ProfilePath'; $ShellCommands"
    if ($LASTEXITCODE -ne 0) {
        throw "Post-install activation commands failed with exit code $LASTEXITCODE"
    }
}
Set-StepStatus -Id 'initialize_dashboard' -Status 'ok' -Detail 'd2 init completed'

Write-Host ("Shell setup was written to: {0}" -f $ProfilePath)
Write-Host 'Developer Dashboard is installed and initialized.'
Write-Host 'Open a new PowerShell window or run this in the current shell:'
Write-Host (". '{0}'" -f $ProfilePath)
Write-Host 'Then verify with:'
Write-Host 'd2 version'
} @args
