Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$source = $PSScriptRoot
$target = Join-Path $env:LOCALAPPDATA 'CodexUsageTray'
$required = @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'Launcher.vbs', 'README.md', 'LICENSE', 'Install.ps1', 'Uninstall.ps1')
$staging = Join-Path $env:LOCALAPPDATA ('CodexUsageTray.install-staging-' + [guid]::NewGuid())
$previousInstall = Join-Path $env:LOCALAPPDATA ('CodexUsageTray.previous-install-' + [guid]::NewGuid())
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Usage Tray.lnk'
$shortcutBackup = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageTray-startup-' + [guid]::NewGuid() + '.lnk')
$updateMutex = $null
$updateMutexHeld = $false
$oldInstallMoved = $false
$newInstallMoved = $false
$installationSucceeded = $false
$oldInstallWasRunning = $false
$shortcutExisted = Test-Path -LiteralPath $startup -PathType Leaf

function Assert-SourcePackage {
    foreach ($relative in $required) {
        $path = Join-Path $source $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Installation package is missing $relative." }
    }
    foreach ($relative in @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'Install.ps1', 'Uninstall.ps1')) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $source $relative), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw "Installation package contains invalid PowerShell syntax in $relative." }
    }
}

function Copy-PackageToStaging {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($relative in $required) {
        $destination = Join-Path $staging $relative
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination -Force
    }
}

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
    $appScriptPath = Join-Path $target 'src\CodexUsageTray.ps1'
    $updaterScriptPath = Join-Path $target 'src\Updater.ps1'
    $trayProcesses = @(Get-ExactScriptProcesses -ScriptPaths @($appScriptPath))
    $updaterProcesses = @(Get-ExactScriptProcesses -ScriptPaths @($updaterScriptPath))
    $processes = @($trayProcesses + $updaterProcesses | Sort-Object ProcessId -Unique)
    $hadRunningTray = $trayProcesses.Count -gt 0
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }
    $paths = @($appScriptPath, $updaterScriptPath)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $remaining = @(Get-ExactScriptProcesses -ScriptPaths $paths)
        if ($remaining.Count -eq 0) { return $hadRunningTray }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'One or more existing Codex Usage Tray processes could not be stopped.'
}

function Start-InstalledTray {
    $launcher = Join-Path $target 'Launcher.vbs'
    $launcherArgument = '"' + $launcher + '"'
    Start-Process (Join-Path $env:SystemRoot 'System32\wscript.exe') -WindowStyle Hidden -ArgumentList @('//B', '//NoLogo', $launcherArgument)
}

function Set-StartupShortcut {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startup)
    $launcher = Join-Path $target 'Launcher.vbs'
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = '//B //NoLogo "' + $launcher + '"'
    $shortcut.WorkingDirectory = $target
    $shortcut.Description = 'Codex usage indicator'
    $shortcut.Save()
}

Assert-SourcePackage
Copy-PackageToStaging
if ($shortcutExisted) { Copy-Item -LiteralPath $startup -Destination $shortcutBackup -Force }

try {
    $updateMutex = [System.Threading.Mutex]::new($false, 'CLSMCSMII.CodexUsageTray.Update')
    try { $updateMutexHeld = $updateMutex.WaitOne([TimeSpan]::FromMinutes(3)) }
    catch [System.Threading.AbandonedMutexException] { $updateMutexHeld = $true }
    if (-not $updateMutexHeld) { throw 'Another install, update, or uninstall operation is still running.' }

    $oldInstallWasRunning = [bool](Stop-InstalledProcesses)
    if (Test-Path -LiteralPath $target) {
        Move-Item -LiteralPath $target -Destination $previousInstall
        $oldInstallMoved = $true
    }
    Move-Item -LiteralPath $staging -Destination $target
    $newInstallMoved = $true
    Set-StartupShortcut

    Start-InstalledTray
    $installationSucceeded = $true
    Write-Host "Installed Codex Usage Tray to $target"
} catch {
    $failure = $_.Exception.Message
    try {
        if ($newInstallMoved -and (Test-Path -LiteralPath $target)) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            $newInstallMoved = $false
        }
        if ($oldInstallMoved -and (Test-Path -LiteralPath $previousInstall)) {
            Move-Item -LiteralPath $previousInstall -Destination $target
            $oldInstallMoved = $false
        }
        if ($shortcutExisted -and (Test-Path -LiteralPath $shortcutBackup -PathType Leaf)) {
            Copy-Item -LiteralPath $shortcutBackup -Destination $startup -Force
        } elseif (-not $shortcutExisted -and (Test-Path -LiteralPath $startup)) {
            Remove-Item -LiteralPath $startup -Force -ErrorAction Stop
        }
        if ($oldInstallWasRunning) { Start-InstalledTray }
    } catch {
        throw "Installation failed: $failure Rollback also failed: $($_.Exception.Message)"
    }
    throw "Installation failed: $failure"
} finally {
    if ($updateMutexHeld -and $updateMutex) { try { $updateMutex.ReleaseMutex() } catch {} }
    if ($updateMutex) { $updateMutex.Dispose() }
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    if ($installationSucceeded) { Remove-Item -LiteralPath $previousInstall -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $shortcutBackup -Force -ErrorAction SilentlyContinue
}
