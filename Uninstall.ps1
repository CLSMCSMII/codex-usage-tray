Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$target = Join-Path $env:LOCALAPPDATA 'CodexUsageTray'
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Usage Tray.lnk'
$updateMutex = $null
$updateMutexHeld = $false

function Get-ExactScriptProcesses {
    param([string[]]$ScriptPaths)
    $patterns = @($ScriptPaths | ForEach-Object {
        $escaped = [regex]::Escape([IO.Path]::GetFullPath($_))
        '(?i)(?:^|\s)-File\s+(?:"' + $escaped + '"|''' + $escaped + '''|' + $escaped + ')(?:\s|$)'
    })
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop | Where-Object {
        $commandLine = [string]$_.CommandLine
        $matched = $false
        foreach ($pattern in $patterns) { if ($commandLine -match $pattern) { $matched = $true; break } }
        $matched
    })
}

function Stop-InstalledProcesses {
    $paths = @(
        (Join-Path $target 'src\CodexUsageTray.ps1'),
        (Join-Path $target 'src\Updater.ps1')
    )
    $processes = @(Get-ExactScriptProcesses -ScriptPaths $paths)
    foreach ($process in $processes) { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $remaining = @(Get-ExactScriptProcesses -ScriptPaths $paths)
        if ($remaining.Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'One or more Codex Usage Tray processes could not be stopped.'
}

try {
    $updateMutex = [System.Threading.Mutex]::new($false, 'CLSMCSMII.CodexUsageTray.Update')
    try { $updateMutexHeld = $updateMutex.WaitOne([TimeSpan]::FromMinutes(3)) }
    catch [System.Threading.AbandonedMutexException] { $updateMutexHeld = $true }
    if (-not $updateMutexHeld) { throw 'An install or update operation is still running. Try uninstalling again after it finishes.' }

    Stop-InstalledProcesses
    if (Test-Path -LiteralPath $startup) { Remove-Item -LiteralPath $startup -Force -ErrorAction Stop }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop }

    if (Test-Path -LiteralPath $startup) { throw 'The Startup shortcut still exists after removal.' }
    if (Test-Path -LiteralPath $target) { throw 'The installation directory still exists after removal.' }
    Write-Host 'Codex Usage Tray was removed.'
} finally {
    if ($updateMutexHeld -and $updateMutex) { try { $updateMutex.ReleaseMutex() } catch {} }
    if ($updateMutex) { $updateMutex.Dispose() }
}
