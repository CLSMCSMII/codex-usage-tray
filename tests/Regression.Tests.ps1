$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$app = Join-Path $projectRoot 'src\CodexUsageTray.ps1'
$updater = Join-Path $projectRoot 'src\Updater.ps1'
$installer = Join-Path $projectRoot 'Install.ps1'
$uninstaller = Join-Path $projectRoot 'Uninstall.ps1'
$readme = Join-Path $projectRoot 'README.md'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-usage-regression-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-RateLimitLine {
    param([string]$Timestamp, [double]$UsedPercent, [long]$ResetsAt = 4102444800)
    [pscustomobject]@{
        timestamp = $Timestamp
        payload = [pscustomobject]@{
            type = 'token_count'
            rate_limits = [pscustomobject]@{
                limit_id = 'codex'
                plan_type = 'test'
                primary = [pscustomobject]@{
                    used_percent = $UsedPercent
                    window_minutes = 300
                    resets_at = $ResetsAt
                }
                secondary = $null
            }
        }
    } | ConvertTo-Json -Compress -Depth 8
}

function Assert-Matches {
    param([string]$Content, [string]$Pattern, [string]$Message)
    if ($Content -notmatch $Pattern) { throw $Message }
}

try {
    # The embedded event timestamp, not filesystem mtime, must determine the latest snapshot.
    $ordering = Join-Path $tempRoot 'ordering'
    New-Item -ItemType Directory -Path $ordering | Out-Null
    $chronologicallyNew = Join-Path $ordering 'new-event-old-mtime.jsonl'
    $chronologicallyOld = Join-Path $ordering 'old-event-new-mtime.jsonl'
    $now = [DateTime]::UtcNow
    [IO.File]::WriteAllText($chronologicallyNew, (New-RateLimitLine $now.ToString('o') 10))
    [IO.File]::WriteAllText($chronologicallyOld, (New-RateLimitLine $now.AddHours(-1).ToString('o') 90))
    (Get-Item -LiteralPath $chronologicallyNew).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
    (Get-Item -LiteralPath $chronologicallyOld).LastWriteTimeUtc = [DateTime]::UtcNow
    $ordered = & $app -NoUi -LocalOnly -SessionsPath $ordering
    if (-not $ordered -or [Math]::Abs($ordered.Windows[0].UsedPercent - 10) -gt 0.001) {
        throw 'Local usage selection followed file mtime instead of the newest embedded event timestamp.'
    }
    Write-Host 'PASS: local usage is selected by embedded event timestamp.' -ForegroundColor Green

    # Physical line order inside one JSONL file must not override embedded timestamps.
    $singleFile = Join-Path $tempRoot 'single-file-ordering'
    New-Item -ItemType Directory -Path $singleFile | Out-Null
    $singleFilePath = Join-Path $singleFile 'events.jsonl'
    $newerLine = New-RateLimitLine $now.ToString('o') 10
    $olderLine = New-RateLimitLine $now.AddHours(-1).ToString('o') 90
    [IO.File]::WriteAllText($singleFilePath, $newerLine + [Environment]::NewLine + $olderLine)
    $singleFileResult = & $app -NoUi -LocalOnly -SessionsPath $singleFile
    if (-not $singleFileResult -or [Math]::Abs($singleFileResult.Windows[0].UsedPercent - 10) -gt 0.001) {
        throw 'Local usage selection followed physical line order instead of embedded timestamps within one JSONL file.'
    }
    Write-Host 'PASS: local usage ordering is correct within one JSONL file.' -ForegroundColor Green

    # A snapshot whose displayed window has already reset must not be shown as current usage.
    $stale = Join-Path $tempRoot 'stale'
    New-Item -ItemType Directory -Path $stale | Out-Null
    [IO.File]::WriteAllText((Join-Path $stale 'stale.jsonl'), (New-RateLimitLine $now.ToString('o') 75 1))
    $staleResult = & $app -NoUi -LocalOnly -SessionsPath $stale
    if ($staleResult) { throw 'An expired local usage snapshot was returned as current usage.' }
    Write-Host 'PASS: expired local usage is rejected.' -ForegroundColor Green

    $tooOld = Join-Path $tempRoot 'too-old'
    New-Item -ItemType Directory -Path $tooOld | Out-Null
    [IO.File]::WriteAllText((Join-Path $tooOld 'too-old.jsonl'), (New-RateLimitLine $now.AddHours(-48).ToString('o') 60))
    if (& $app -NoUi -LocalOnly -SessionsPath $tooOld) { throw 'An arbitrarily old local snapshot with a future reset was returned as current usage.' }
    Write-Host 'PASS: arbitrarily old local usage is rejected.' -ForegroundColor Green

    # Valid usage must not disappear merely because twelve newer files contain no rate-limit event.
    $manyFiles = Join-Path $tempRoot 'many-files'
    New-Item -ItemType Directory -Path $manyFiles | Out-Null
    $validPath = Join-Path $manyFiles 'valid.jsonl'
    [IO.File]::WriteAllText($validPath, (New-RateLimitLine $now.ToString('o') 25))
    (Get-Item -LiteralPath $validPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-1)
    1..12 | ForEach-Object {
        $noisePath = Join-Path $manyFiles ("noise-$_.jsonl")
        [IO.File]::WriteAllText($noisePath, '{"timestamp":"2026-07-15T13:00:00Z","payload":{"type":"message"}}')
        (Get-Item -LiteralPath $noisePath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes($_)
    }
    $manyResult = & $app -NoUi -LocalOnly -SessionsPath $manyFiles
    if (-not $manyResult -or [Math]::Abs($manyResult.Windows[0].UsedPercent - 25) -gt 0.001) {
        throw 'Valid usage was hidden by the twelve-file search limit.'
    }
    Write-Host 'PASS: local usage search is not truncated to twelve files.' -ForegroundColor Green

    $appText = Get-Content -Raw -LiteralPath $app
    $updaterText = Get-Content -Raw -LiteralPath $updater
    $installerText = Get-Content -Raw -LiteralPath $installer
    $uninstallerText = Get-Content -Raw -LiteralPath $uninstaller
    $readmeText = Get-Content -Raw -LiteralPath $readme

    Assert-Matches $appText 'Local\\CLSMCSMII\.CodexUsageTray' 'The tray application has no per-session single-instance mutex.'
    Assert-Matches $appText 'TimeoutSec' 'Live usage requests have no explicit timeout.'
    Assert-Matches $appText 'refreshProcessStartedAt' 'Background refreshes have no overall watchdog.'
    Assert-Matches $updaterText 'ExpectedArchiveSha256' 'The updater does not bind installation to the archive approved during the check.'
    Assert-Matches $updaterText 'ParentProcessStartTimeUtcTicks' 'The updater identifies its parent only by a reusable numeric PID.'
    Assert-Matches $updaterText 'transactionStarted' 'The updater has no guard preventing rollback actions before it owns the update mutex.'
    Assert-Matches $updaterText '\$latestVersion\s+-lt\s+\$installedVersion' 'Apply mode does not reject a stale approved archive when a newer version is already installed.'
    Assert-Matches $updaterText 'pending-update-' 'The update check does not preserve the exact approved archive.'
    Assert-Matches $updaterText 'previous-install' 'The updater does not retain a full-installation rollback copy.'
    Assert-Matches $updaterText 'if \(\$CheckOnly -or \$ValidateOnly' 'Check-only failures can still execute the tray restart path.'
    Assert-Matches $installerText 'install-staging-' 'The installer does not stage a complete installation before replacement.'
    Assert-Matches $installerText 'previous-install' 'The installer does not retain a full rollback copy.'
    Assert-Matches $installerText 'oldInstallWasRunning' 'Installer rollback does not track whether the previous tray process was running.'
    Assert-Matches $installerText 'Start-InstalledTray' 'Installer rollback cannot restart a restored previous installation.'
    Assert-Matches $uninstallerText '(?i)-File' 'The uninstaller does not require an exact -File script invocation before stopping a process.'
    if ($uninstallerText -match '-like\s+"\*\$target\*CodexUsageTray\.ps1\*"') { throw 'The uninstaller still uses a broad command-line wildcard that can kill unrelated processes.' }
    Assert-Matches $uninstallerText 'CodexUsageTray\.Update' 'The uninstaller does not coordinate with an in-progress updater.'
    Assert-Matches $uninstallerText 'Test-Path -LiteralPath \$target' 'The uninstaller does not verify that the installation was removed.'

    $readmeVersion = [regex]::Match($readmeText, 'Current version:\s*\*\*([^*]+)\*\*').Groups[1].Value
    $appVersion = [regex]::Match($appText, "(?m)^.*AppVersion\s*=\s*'([^']+)'").Groups[1].Value
    if (-not $readmeVersion -or $readmeVersion -ne $appVersion) { throw "README version '$readmeVersion' does not match app version '$appVersion'." }
    if ($readmeText -match 'Does not send data outside the computer') { throw 'README still incorrectly claims the application sends no data outside the computer.' }
    Write-Host 'PASS: safety invariants and documentation are consistent.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
