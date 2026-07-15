$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$updater = Join-Path $projectRoot 'src\Updater.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-usage-updater-test-' + [guid]::NewGuid())
$installRoot = Join-Path $testRoot 'install'
$archivePath = Join-Path $testRoot 'source.zip'
$required = @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'Launcher.vbs', 'Install.ps1', 'Uninstall.ps1', 'README.md', 'LICENSE')
New-Item -ItemType Directory -Path $testRoot, $installRoot -Force | Out-Null

try {
    Compress-Archive -Path (Join-Path $projectRoot '*') -DestinationPath $archivePath -CompressionLevel Fastest

    $available = & $updater -InstallRoot $installRoot -SourceArchive $archivePath -CheckOnly -PersistArchive -CurrentVersion '1.2.3' | ConvertFrom-Json
    if (-not $available.updateAvailable -or $available.currentVersion -ne '1.2.3' -or $available.latestVersion -ne '1.3.0') {
        throw 'Update check did not identify version 1.3.0 as newer than 1.2.3.'
    }
    if ([string]$available.archiveSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Update check returned no valid archive SHA-256.' }
    if (-not (Test-Path -LiteralPath ([string]$available.archivePath) -PathType Leaf)) { throw 'Update check did not persist the exact approved archive.' }
    Write-Host 'PASS: update check returns and preserves an exact archive identity.' -ForegroundColor Green

    $current = & $updater -InstallRoot $installRoot -SourceArchive $archivePath -CheckOnly -CurrentVersion '1.3.0' | ConvertFrom-Json
    if ($current.updateAvailable) { throw 'Update check incorrectly reported an update for the current version.' }

    [IO.File]::WriteAllText((Join-Path $installRoot 'existing-marker.txt'), 'old-installation')
    $badHashFailed = $false
    try {
        & $updater -InstallRoot $installRoot -SourceArchive $archivePath -ExpectedArchiveSha256 ('0' * 64) -ExpectedVersion '1.3.0' -NoRestart
    } catch { $badHashFailed = $true }
    if (-not $badHashFailed) { throw 'Updater accepted an archive whose SHA-256 differed from the approved hash.' }
    if ((Get-Content -Raw -LiteralPath (Join-Path $installRoot 'existing-marker.txt')) -ne 'old-installation') {
        throw 'Updater modified the old installation after archive identity validation failed.'
    }
    Write-Host 'PASS: updater rejects an archive that was not approved by the update check.' -ForegroundColor Green

    $approvedArchive = [string]$available.archivePath
    & $updater -InstallRoot $installRoot -SourceArchive $approvedArchive -ExpectedArchiveSha256 ([string]$available.archiveSha256) -ExpectedVersion ([string]$available.latestVersion) -DeleteSourceArchive -NoRestart
    if (Test-Path -LiteralPath $approvedArchive) { throw 'Updater did not remove the consumed pending archive.' }
    $result = Get-Content -Raw -LiteralPath (Join-Path $installRoot 'update-result.json') | ConvertFrom-Json
    if (-not $result.success) { throw $result.message }
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot $relative) -PathType Leaf)) { throw "Missing installed file: $relative" }
    }
    if (Test-Path -LiteralPath (Join-Path $installRoot 'existing-marker.txt')) { throw 'Atomic replacement retained an obsolete file from the old installation.' }
    Write-Host 'PASS: updater atomically replaces a test installation from the approved archive.' -ForegroundColor Green

    # Force the second deployment move to fail. The first move backs up the old installation;
    # the third move in the rollback path must restore that complete backup.
    $before = @{}
    foreach ($relative in $required) { $before[$relative] = (Get-FileHash -LiteralPath (Join-Path $installRoot $relative) -Algorithm SHA256).Hash }
    $script:moveCallCount = 0
    function Move-Item {
        [CmdletBinding()]
        param(
            [Parameter(ParameterSetName='Path', Position=0)][string[]]$Path,
            [Parameter(ParameterSetName='LiteralPath')][Alias('PSPath')][string[]]$LiteralPath,
            [Parameter(Position=1)][string]$Destination,
            [switch]$Force
        )
        $script:moveCallCount++
        if ($script:moveCallCount -eq 2) { throw 'Injected staged-install move failure.' }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    $rollbackFailedAsExpected = $false
    try {
        . $updater -InstallRoot $installRoot -SourceArchive $archivePath -ExpectedArchiveSha256 ([string]$available.archiveSha256) -ExpectedVersion '1.3.0' -NoRestart
    } catch {
        if ($_.Exception.Message -match 'Injected staged-install move failure') { $rollbackFailedAsExpected = $true }
    } finally {
        Remove-Item Function:\Move-Item -ErrorAction SilentlyContinue
    }
    if (-not $rollbackFailedAsExpected) { throw 'The rollback test did not reach the injected deployment failure.' }
    foreach ($relative in $required) {
        $afterHash = (Get-FileHash -LiteralPath (Join-Path $installRoot $relative) -Algorithm SHA256).Hash
        if ($afterHash -ne $before[$relative]) { throw "Rollback did not restore $relative." }
    }
    $rollbackResult = Get-Content -Raw -LiteralPath (Join-Path $installRoot 'update-result.json') | ConvertFrom-Json
    if ($rollbackResult.success) { throw 'A rolled-back update was incorrectly reported as successful.' }
    Write-Host 'PASS: a failed deployment restores the complete previous installation.' -ForegroundColor Green

    $invalidArchive = Join-Path $testRoot 'invalid.zip'
    [IO.File]::WriteAllText($invalidArchive, 'not a zip archive')
    $checkFailure = $false
    try { & $updater -InstallRoot $installRoot -SourceArchive $invalidArchive -CheckOnly -CurrentVersion '1.3.0' }
    catch { $checkFailure = $true }
    if (-not $checkFailure) { throw 'Invalid check-only archive unexpectedly succeeded.' }
    $postFailureResult = Get-Content -Raw -LiteralPath (Join-Path $installRoot 'update-result.json') | ConvertFrom-Json
    if ($postFailureResult.success) { throw 'Check-only failure changed the existing update result or entered the restart path.' }
    Write-Host 'PASS: failed check-only validation does not enter the restart path.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
