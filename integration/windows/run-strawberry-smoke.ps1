param(
    [Parameter(Mandatory = $true)]
    [string]$Tarball,

    [string]$Port = "7890",

    [string]$PerlBin = "",

    [string]$DashboardBin = "",

    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Purpose: run a command with logging and fail on non-zero exit.
# Input: Command array and an optional label string.
# Output: writes the command to stdout and throws on a non-zero exit code.
function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Command,

        [string]$Label = "command"
    )

    Write-Host "==> $Label"
    Write-Host ($Command -join ' ')
    & $Command[0] @Command[1..($Command.Length - 1)]
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

# Purpose: resolve the Strawberry Perl interpreter path for the Windows smoke.
# Input: optional explicit Perl interpreter path.
# Output: returns the absolute Perl interpreter path or throws if none is found.
function Get-PerlBin {
    param([string]$Requested)
    if ($Requested -ne "") {
        return $Requested
    }

    $candidates = @(
        "perl",
        "C:\Strawberry\perl\bin\perl.exe",
        "C:\Strawberry\c\bin\perl.exe"
    )

    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    throw "Unable to find a Strawberry Perl interpreter"
}

# Purpose: resolve the installed dashboard command path.
# Input: optional explicit dashboard executable path.
# Output: returns the dashboard executable path or throws if it is missing from PATH.
function Get-DashboardBin {
    param([string]$Requested)
    if ($Requested -ne "") {
        return $Requested
    }

    $cmd = Get-Command dashboard -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw "Unable to find installed dashboard command in PATH"
}

# Purpose: assert that a text blob contains a required fragment.
# Input: text to inspect, the required fragment, and a label for error reporting.
# Output: returns nothing and throws if the fragment is absent.
function Invoke-AssertContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Fragment,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not $Text.Contains($Fragment)) {
        throw "$Label missing fragment [$Fragment]"
    }
}

# Purpose: assert that a text blob omits a forbidden fragment.
# Input: text to inspect, the forbidden fragment, and a label for error reporting.
# Output: returns nothing and throws if the fragment is present.
function Invoke-AssertNotContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Fragment,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Text.Contains($Fragment)) {
        throw "$Label unexpectedly contained [$Fragment]"
    }
}

# Purpose: locate an Edge or Chrome browser binary for DOM smoke checks.
# Input: none.
# Output: returns a browser path or $null when no supported browser exists.
function Get-BrowserBinary {
    $candidates = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

# Purpose: wait until the dashboard HTTP endpoint responds.
# Input: target URL string.
# Output: returns when the URL responds with a non-5xx code or throws on timeout.
function Wait-HttpOk {
    param([Parameter(Mandatory = $true)][string]$Url)

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return
            }
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }

    throw "Timed out waiting for HTTP response from $Url"
}

# Purpose: dump the rendered DOM of a page through a real Windows browser.
# Input: browser path, target URL, and browser user-data directory path.
# Output: returns the dumped DOM as text or throws on browser failure.
function Get-DumpDom {
    param(
        [Parameter(Mandatory = $true)][string]$Browser,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserDataDir
    )

    $dump = & $Browser --headless --disable-gpu --allow-insecure-localhost --user-data-dir=$UserDataDir --dump-dom $Url
    if ($LASTEXITCODE -ne 0) {
        throw "Browser dump-dom failed with exit code $LASTEXITCODE"
    }
    return ($dump | Out-String)
}

$Perl = Get-PerlBin -Requested $PerlBin

if (-not (Test-Path $Tarball)) {
    throw "Tarball does not exist: $Tarball"
}

Invoke-LoggedCommand -Label "install Developer Dashboard tarball with cpanm" -Command @("cpanm", $Tarball)

$Dashboard = Get-DashboardBin -Requested $DashboardBin

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dd-win-smoke-" + [guid]::NewGuid().ToString("N"))
$homeRoot = Join-Path $tempRoot "home"
$projectRoot = Join-Path $tempRoot "project"
$profileRoot = Join-Path $tempRoot "browser"
$runtimeRoot = Join-Path $projectRoot ".developer-dashboard"
$bookmarkRoot = Join-Path $runtimeRoot "dashboards"
$ajaxRoot = Join-Path $bookmarkRoot "ajax"
$navRoot = Join-Path $bookmarkRoot "nav"
$configRoot = Join-Path $runtimeRoot "config"

New-Item -ItemType Directory -Force -Path $homeRoot, $projectRoot, $bookmarkRoot, $ajaxRoot, $navRoot, $configRoot, $profileRoot | Out-Null
Set-Content -Path (Join-Path $projectRoot ".git") -Value "" -NoNewline

$env:HOME = $homeRoot
$env:USERPROFILE = $homeRoot

$bookmark = @"
BOOKMARK: sample
:--------------------------------------------------------------------------------:
TITLE: Windows Smoke
:--------------------------------------------------------------------------------:
HTML:
<div id="windows-smoke-page">hello from windows smoke</div>
CODE1:
Ajax file => 'hello.ps1', jvar => 'ajax.url', code => q{
Write-Output 'ajax-ok'
};
"@
Set-Content -Path (Join-Path $bookmarkRoot "sample") -Value $bookmark
Set-Content -Path (Join-Path $navRoot "home.tt") -Value '<a href="/app/sample">Home</a>'

$configJson = @"
{
  "collectors": [
    {
      "name": "windows.collector",
      "command": "Write-Output 'collector-ok'",
      "cwd": "home"
    }
  ]
}
"@
Set-Content -Path (Join-Path $configRoot "config.json") -Value $configJson

$psBootstrap = & $Dashboard shell ps | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "dashboard shell ps failed with exit code $LASTEXITCODE"
}
Invoke-AssertContains -Text $psBootstrap -Fragment "function prompt {" -Label "PowerShell bootstrap"
Invoke-AssertContains -Text $psBootstrap -Fragment "dashboard ps1 --mode compact" -Label "PowerShell bootstrap"
Invoke-AssertNotContains -Text $psBootstrap -Fragment "PS1=" -Label "PowerShell bootstrap"

$promptText = & $Dashboard ps1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "dashboard ps1 failed with exit code $LASTEXITCODE"
}
if ([string]::IsNullOrWhiteSpace($promptText)) {
    throw "dashboard ps1 returned empty prompt text"
}

Push-Location $projectRoot
try {
    Invoke-LoggedCommand -Label "dashboard page list" -Command @($Dashboard, "page", "list")
    Invoke-LoggedCommand -Label "dashboard collector run windows.collector" -Command @($Dashboard, "collector", "run", "windows.collector")

    $collectorOutput = & $Dashboard collector output windows.collector | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "dashboard collector output windows.collector failed with exit code $LASTEXITCODE"
    }
    Invoke-AssertContains -Text $collectorOutput -Fragment "collector-ok" -Label "collector output"

    Invoke-LoggedCommand -Label "dashboard auth add-user helper smoke-pass-123" -Command @($Dashboard, "auth", "add-user", "helper", "smoke-pass-123")

    $serve = Start-Process -FilePath $Dashboard -ArgumentList @("serve", "--host", "127.0.0.1", "--port", $Port) -PassThru -NoNewWindow
    try {
        Wait-HttpOk -Url "http://127.0.0.1:$Port/"

        $root = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/"
        Invoke-AssertContains -Text $root.Content -Fragment "textarea" -Label "root editor"

        $page = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/app/sample"
        Invoke-AssertContains -Text $page.Content -Fragment "windows-smoke-page" -Label "saved page"

        $ajax = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/ajax/hello.ps1?type=text"
        Invoke-AssertContains -Text $ajax.Content -Fragment "ajax-ok" -Label "saved Ajax"

        $browser = Get-BrowserBinary
        if ($browser) {
            $dom = Get-DumpDom -Browser $browser -Url "http://127.0.0.1:$Port/app/sample" -UserDataDir $profileRoot
            Invoke-AssertContains -Text $dom -Fragment "hello from windows smoke" -Label "browser DOM"
        }
        else {
            Write-Warning "No Edge or Chrome browser found; skipping Windows browser DOM smoke"
        }
    }
    finally {
        if ($serve -and -not $serve.HasExited) {
            Stop-Process -Id $serve.Id -Force
            $serve.WaitForExit()
        }
    }
}
finally {
    Pop-Location
    if (-not $KeepTemp) {
        Remove-Item -Recurse -Force $tempRoot
    }
}

Write-Host "Windows Strawberry Perl smoke passed"

<#
__END__

=head1 NAME

run-strawberry-smoke.ps1 - verify the built tarball under Strawberry Perl and PowerShell

=head1 SYNOPSIS

  powershell -ExecutionPolicy Bypass -File integration/windows/run-strawberry-smoke.ps1 -Tarball C:\path\Developer-Dashboard-*.tar.gz

=head1 DESCRIPTION

This script installs the built C<Developer::Dashboard> tarball with C<cpanm>
under Strawberry Perl, verifies C<dashboard shell ps> and C<dashboard ps1>,
checks one PowerShell-backed collector command, starts the dashboard web
service, exercises one saved Ajax PowerShell handler through
C<Invoke-WebRequest>, and optionally dumps DOM through Edge or Chrome when a
browser binary is present on the Windows host.

=cut
#>
