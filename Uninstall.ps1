$ErrorActionPreference = 'Stop'
$target = Join-Path $env:LOCALAPPDATA 'CodexUsageTray'
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Usage Tray.lnk'
Remove-Item -LiteralPath $startup -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*$target*CodexUsageTray.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Codex Usage Tray was removed.'

