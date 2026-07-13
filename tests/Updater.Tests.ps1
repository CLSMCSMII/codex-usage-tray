$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-usage-updater-test-' + [guid]::NewGuid())
$installRoot = Join-Path $tempRoot 'install'
$archivePath = Join-Path $tempRoot 'source.zip'
New-Item -ItemType Directory -Path $tempRoot, $installRoot -Force | Out-Null
try {
    Compress-Archive -Path (Join-Path $projectRoot '*') -DestinationPath $archivePath -CompressionLevel Fastest
    & (Join-Path $projectRoot 'src\Updater.ps1') -InstallRoot $installRoot -SourceArchive $archivePath -NoRestart
    $result = Get-Content -Raw -LiteralPath (Join-Path $installRoot 'update-result.json') | ConvertFrom-Json
    if (-not $result.success) { throw $result.message }
    foreach ($relative in @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'Install.ps1', 'Uninstall.ps1', 'README.md', 'LICENSE')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot $relative))) { throw "Missing installed file: $relative" }
    }
    Write-Host 'PASS: updater validates and replaces a test installation.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

