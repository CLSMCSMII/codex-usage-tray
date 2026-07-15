$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$target = Join-Path $env:LOCALAPPDATA 'CodexUsageTray'
New-Item -ItemType Directory -Path (Join-Path $target 'src') -Force | Out-Null
foreach ($relative in @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'Launcher.vbs', 'README.md', 'LICENSE', 'Install.ps1', 'Uninstall.ps1')) {
    $destination = Join-Path $target $relative
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination -Force
}

$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Usage Tray.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($startup)
$launcher = Join-Path $target 'Launcher.vbs'
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shortcut.Arguments = '//B //NoLogo "' + $launcher + '"'
$shortcut.WorkingDirectory = $target
$shortcut.Description = 'Codex usage indicator'
$shortcut.Save()
$launcherArgument = '"' + $launcher + '"'
Start-Process (Join-Path $env:SystemRoot 'System32\wscript.exe') -WindowStyle Hidden -ArgumentList @('//B', '//NoLogo', $launcherArgument)
Write-Host "Installed Codex Usage Tray to $target"
