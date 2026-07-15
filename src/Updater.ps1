param(
    [int]$ParentProcessId,
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$Repository = 'CLSMCSMII/codex-usage-tray',
    [string]$SourceArchive,
    [string]$SourceCommit,
    [string]$ExpectedArchiveSha256,
    [string]$ExpectedVersion,
    [switch]$CheckOnly,
    [string]$CurrentVersion,
    [switch]$PersistArchive,
    [switch]$DeleteSourceArchive,
    [switch]$ValidateOnly,
    [switch]$NoRestart,
    [ValidateRange(10, 600)][int]$HttpTimeoutSec = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid GitHub repository '$Repository'." }
if ($SourceCommit -and $SourceCommit -notmatch '^[0-9a-fA-F]{40}$') { throw "Invalid source commit '$SourceCommit'." }
if ($ExpectedArchiveSha256 -and $ExpectedArchiveSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'ExpectedArchiveSha256 must be a 64-character SHA-256 value.' }

$required = @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'Launcher.vbs', 'Install.ps1', 'Uninstall.ps1', 'README.md', 'LICENSE')
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-usage-update-' + [guid]::NewGuid())
$archivePath = Join-Path $tempRoot 'source.zip'
$extractPath = Join-Path $tempRoot 'extract'
$installParent = Split-Path ([IO.Path]::GetFullPath($InstallRoot)) -Parent
$deploymentId = [guid]::NewGuid().ToString('N')
$stagePath = Join-Path $installParent ("CodexUsageTray.update-staging-$deploymentId")
$previousInstallPath = Join-Path $installParent ("CodexUsageTray.previous-install-$deploymentId")
$resultPath = Join-Path $InstallRoot 'update-result.json'
$appPath = Join-Path $InstallRoot 'src\CodexUsageTray.ps1'
$updateMutex = $null
$updateMutexHeld = $false
$previousInstallMoved = $false
$newInstallMoved = $false
$updateSucceeded = $false
$parentProcess = $null

# Capture a handle while the parent is still expected to exist. Reusing the numeric PID later could target an unrelated process.
if ($ParentProcessId -gt 0) {
    try {
        $parentProcess = [System.Diagnostics.Process]::GetProcessById($ParentProcessId)
        [void]$parentProcess.Handle
    } catch {
        $parentProcess = $null
    }
}

function Write-UpdateResult {
    param([bool]$Success, [string]$Message)
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    [pscustomobject]@{ success = $Success; message = $Message; timestamp = [DateTime]::Now.ToString('o') } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $resultPath -Encoding UTF8
}

function Start-TrayApp {
    if ($NoRestart) { return }
    $launcherPath = Join-Path $InstallRoot 'Launcher.vbs'
    if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
        $launcherArgument = '"' + $launcherPath + '"'
        Start-Process (Join-Path $env:SystemRoot 'System32\wscript.exe') -WindowStyle Hidden -ArgumentList @('//B', '//NoLogo', $launcherArgument)
    } elseif (Test-Path -LiteralPath $appPath -PathType Leaf) {
        $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $appPath
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments
    } else {
        throw 'The installed tray launcher and application are both missing.'
    }
}

function Get-SourceVersion {
    param([Parameter(Mandatory)][string]$SourceRoot)
    $sourceAppPath = Join-Path $SourceRoot 'src\CodexUsageTray.ps1'
    $content = Get-Content -Raw -LiteralPath $sourceAppPath
    $match = [regex]::Match($content, '(?m)^\s*\$script:AppVersion\s*=\s*''([^'']+)''\s*$')
    if (-not $match.Success) { throw 'The downloaded update has no valid app version.' }
    try { return [version]$match.Groups[1].Value }
    catch { throw "The downloaded app version '$($match.Groups[1].Value)' is invalid." }
}

function Get-GitHubHeadCommit {
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'CodexUsageTray' }
    $ref = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/git/ref/heads/main" -Headers $headers -TimeoutSec $HttpTimeoutSec
    $sha = [string]$ref.object.sha
    if ($sha -notmatch '^[0-9a-fA-F]{40}$') { throw 'GitHub returned an invalid main-branch commit.' }
    return $sha.ToLowerInvariant()
}

function Get-ArchiveSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SourceRoot {
    param([Parameter(Mandatory)][string]$Root)
    if (Test-Path -LiteralPath (Join-Path $Root 'src\CodexUsageTray.ps1') -PathType Leaf) { return $Root }
    $candidates = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'src\CodexUsageTray.ps1') -PathType Leaf
    })
    if ($candidates.Count -ne 1) { throw 'The downloaded archive does not contain exactly one Codex Usage Tray project.' }
    return $candidates[0].FullName
}

function Assert-ProjectFiles {
    param([Parameter(Mandatory)][string]$SourceRoot)
    foreach ($relative in $required) {
        $path = Join-Path $SourceRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "The downloaded update is missing $relative." }
    }
    foreach ($relative in @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'Install.ps1', 'Uninstall.ps1')) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $relative), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "The downloaded update contains invalid PowerShell syntax in $relative." }
    }
}

function Copy-ProjectToStage {
    param([Parameter(Mandatory)][string]$SourceRoot)
    New-Item -ItemType Directory -Path $stagePath -Force | Out-Null
    foreach ($relative in $required) {
        $destination = Join-Path $stagePath $relative
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $SourceRoot $relative) -Destination $destination -Force
    }
}

function Wait-ForCapturedParent {
    if (-not $parentProcess) { return }
    try {
        if (-not $parentProcess.HasExited) {
            [void]$parentProcess.WaitForExit(10000)
            if (-not $parentProcess.HasExited) {
                $parentProcess.Kill()
                [void]$parentProcess.WaitForExit(5000)
            }
        }
    } finally {
        $parentProcess.Dispose()
        $script:parentProcess = $null
    }
}

New-Item -ItemType Directory -Path $tempRoot, $extractPath -Force | Out-Null
try {
    $updateMutex = [System.Threading.Mutex]::new($false, 'CLSMCSMII.CodexUsageTray.Update')
    try { $updateMutexHeld = $updateMutex.WaitOne([TimeSpan]::FromMinutes(3)) }
    catch [System.Threading.AbandonedMutexException] { $updateMutexHeld = $true }
    if (-not $updateMutexHeld) { throw 'Another install, update, or uninstall operation is still running.' }

    if ($SourceArchive) {
        Copy-Item -LiteralPath $SourceArchive -Destination $archivePath -Force
    } else {
        if (-not $SourceCommit) {
            if (-not $CheckOnly) { throw 'Apply mode requires the exact source commit returned by the update check.' }
            $SourceCommit = Get-GitHubHeadCommit
        }
        $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repository/archive/$SourceCommit.zip?cacheBust=$cacheBust" -OutFile $archivePath -TimeoutSec $HttpTimeoutSec
    }

    $archiveSha256 = Get-ArchiveSha256 -Path $archivePath
    if ($ExpectedArchiveSha256 -and $archiveSha256 -ne $ExpectedArchiveSha256.ToLowerInvariant()) {
        throw 'The update archive SHA-256 does not match the archive approved during the update check.'
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
    $sourceRoot = Get-SourceRoot -Root $extractPath
    Assert-ProjectFiles -SourceRoot $sourceRoot
    $latestVersion = Get-SourceVersion -SourceRoot $sourceRoot

    if ($ExpectedVersion) {
        try { $approvedVersion = [version]$ExpectedVersion }
        catch { throw "The approved app version '$ExpectedVersion' is invalid." }
        if ($latestVersion -ne $approvedVersion) {
            throw "The update archive version '$latestVersion' does not match approved version '$approvedVersion'."
        }
    }

    if ($CheckOnly) {
        if (-not $CurrentVersion) { throw 'CurrentVersion is required when CheckOnly is used.' }
        try { $installedVersion = [version]$CurrentVersion }
        catch { throw "The installed app version '$CurrentVersion' is invalid." }
        $updateAvailable = $latestVersion -gt $installedVersion
        $pendingArchivePath = $null
        if ($PersistArchive -and $updateAvailable) {
            New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
            Get-ChildItem -LiteralPath $InstallRoot -Filter 'pending-update-*.zip' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            $identity = if ($SourceCommit) { $SourceCommit.ToLowerInvariant() } else { $archiveSha256 }
            $pendingArchivePath = Join-Path $InstallRoot ("pending-update-$identity.zip")
            Copy-Item -LiteralPath $archivePath -Destination $pendingArchivePath -Force
        }
        [pscustomobject]@{
            currentVersion = $installedVersion.ToString()
            latestVersion = $latestVersion.ToString()
            updateAvailable = $updateAvailable
            sourceCommit = if ($SourceCommit) { $SourceCommit.ToLowerInvariant() } else { $null }
            archiveSha256 = $archiveSha256
            archivePath = $pendingArchivePath
        } | ConvertTo-Json -Compress
        return
    }

    if ($ValidateOnly) { Write-Host 'PASS: update archive contains every required file and valid PowerShell syntax.'; return }
    if (-not $ExpectedArchiveSha256) { throw 'Apply mode requires ExpectedArchiveSha256 from the update check.' }
    if (-not $ExpectedVersion) { throw 'Apply mode requires ExpectedVersion from the update check.' }

    Copy-ProjectToStage -SourceRoot $sourceRoot
    Wait-ForCapturedParent

    if (Test-Path -LiteralPath $InstallRoot) {
        Move-Item -LiteralPath $InstallRoot -Destination $previousInstallPath
        $previousInstallMoved = $true
    }
    Move-Item -LiteralPath $stagePath -Destination $InstallRoot
    $newInstallMoved = $true

    Write-UpdateResult -Success $true -Message "Codex Usage Tray was updated to version $latestVersion from the approved archive."
    Start-TrayApp
    $updateSucceeded = $true
} catch {
    if ($CheckOnly -or $ValidateOnly) { throw }
    $failureMessage = 'Update failed: ' + $_.Exception.Message
    try {
        if ($newInstallMoved -and (Test-Path -LiteralPath $InstallRoot)) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction Stop
            $newInstallMoved = $false
        }
        if ($previousInstallMoved -and (Test-Path -LiteralPath $previousInstallPath)) {
            Move-Item -LiteralPath $previousInstallPath -Destination $InstallRoot
            $previousInstallMoved = $false
        }
        Write-UpdateResult -Success $false -Message $failureMessage
        Start-TrayApp
    } catch {
        throw "$failureMessage Rollback also failed: $($_.Exception.Message)"
    }
    throw $failureMessage
} finally {
    if ($parentProcess) { $parentProcess.Dispose() }
    if ($updateMutexHeld -and $updateMutex) { try { $updateMutex.ReleaseMutex() } catch {} }
    if ($updateMutex) { $updateMutex.Dispose() }
    if ($DeleteSourceArchive -and $SourceArchive) { Remove-Item -LiteralPath $SourceArchive -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
    if ($updateSucceeded) { Remove-Item -LiteralPath $previousInstallPath -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
