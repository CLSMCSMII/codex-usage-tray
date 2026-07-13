$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$target = Join-Path $env:LOCALAPPDATA 'CodexUsageTray'
New-Item -ItemType Directory -Path (Join-Path $target 'src') -Force | Out-Null
foreach ($relative in @('src\CodexUsageTray.ps1', 'src\Updater.ps1', 'README.md', 'LICENSE', 'Install.ps1', 'Uninstall.ps1')) {
    $destination = Join-Path $target $relative
    New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination -Force
}

$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Usage Tray.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($startup)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $target 'src\CodexUsageTray.ps1') + '"'
$shortcut.WorkingDirectory = $target
$shortcut.Description = 'Codex usage indicator'
$shortcut.Save()
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $target 'src\CodexUsageTray.ps1'))
Write-Host "Installed Codex Usage Tray to $target"
