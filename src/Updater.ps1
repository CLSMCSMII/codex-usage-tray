param(
    [int]$ParentProcessId,
    [Parameter(Mandatory)][string]$InstallRoot,
    [string]$Repository = 'CLSMCSMII/codex-usage-tray',
    [string]$SourceArchive,
    [switch]$CheckOnly,
    [string]$CurrentVersion,
    [switch]$ValidateOnly,
    [switch]$NoRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-usage-update-' + [guid]::NewGuid())
$archivePath = Join-Path $tempRoot 'source.zip'
$extractPath = Join-Path $tempRoot 'extract'
$resultPath = Join-Path $InstallRoot 'update-result.json'
$appPath = Join-Path $InstallRoot 'src\CodexUsageTray.ps1'
$backupPath = Join-Path $tempRoot 'CodexUsageTray.backup.ps1'

function Write-UpdateResult {
    param([bool]$Success, [string]$Message)
    [pscustomobject]@{ success = $Success; message = $Message; timestamp = [DateTime]::Now.ToString('o') } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $resultPath -Encoding UTF8
}

function Start-TrayApp {
    if ($NoRestart) { return }
    if (Test-Path -LiteralPath $appPath) {
        $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $appPath
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments
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

New-Item -ItemType Directory -Path $tempRoot, $extractPath -Force | Out-Null
try {
    if ($SourceArchive) { Copy-Item -LiteralPath $SourceArchive -Destination $archivePath -Force }
    else {
        $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repository/archive/refs/heads/main.zip?cacheBust=$cacheBust" -OutFile $archivePath
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
    $firstDirectory = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
    $sourceRoot = if ($firstDirectory -and (Test-Path -LiteralPath (Join-Path $firstDirectory.FullName 'src\CodexUsageTray.ps1'))) { $firstDirectory.FullName }
        elseif (Test-Path -LiteralPath (Join-Path $extractPath 'src\CodexUsageTray.ps1')) { $extractPath }
        else { throw 'The downloaded archive has no Codex Usage Tray project.' }
    $required = @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'Install.ps1', 'Uninstall.ps1', 'README.md', 'LICENSE')
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relative))) { throw "The downloaded update is missing $relative." }
    }
    $latestVersion = Get-SourceVersion -SourceRoot $sourceRoot
    if ($CheckOnly) {
        if (-not $CurrentVersion) { throw 'CurrentVersion is required when CheckOnly is used.' }
        try { $installedVersion = [version]$CurrentVersion }
        catch { throw "The installed app version '$CurrentVersion' is invalid." }
        [pscustomobject]@{
            currentVersion = $installedVersion.ToString()
            latestVersion = $latestVersion.ToString()
            updateAvailable = ($latestVersion -gt $installedVersion)
        } | ConvertTo-Json -Compress
        return
    }
    if ($ValidateOnly) { Write-Host 'PASS: update archive contains every required file.'; return }

    if (Test-Path -LiteralPath $appPath) { Copy-Item -LiteralPath $appPath -Destination $backupPath -Force }
    if ($ParentProcessId -gt 0) {
        $parent = Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
        if ($parent) {
            [void]$parent.WaitForExit(10000)
            if (-not $parent.HasExited) { Stop-Process -Id $ParentProcessId -Force }
        }
    }

    New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'src') -Force | Out-Null
    foreach ($relative in $required) {
        $destination = Join-Path $InstallRoot $relative
        $destinationParent = Split-Path $destination
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $destination -Force
    }
    Write-UpdateResult -Success $true -Message 'Codex Usage Tray was updated from GitHub.'
    Start-TrayApp
} catch {
    try {
        if (Test-Path -LiteralPath $backupPath) { Copy-Item -LiteralPath $backupPath -Destination $appPath -Force }
        Write-UpdateResult -Success $false -Message ('Update failed: ' + $_.Exception.Message)
        Start-TrayApp
    } catch {}
    throw
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
