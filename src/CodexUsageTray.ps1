param([switch]$NoUi, [switch]$Json, [string]$SessionsPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CodexSessionsPath {
    param([string]$Override)
    if ($Override) { return $Override }
    if ($env:CODEX_HOME) { return (Join-Path $env:CODEX_HOME 'sessions') }
    return (Join-Path $HOME '.codex\sessions')
}

function ConvertTo-UsageSnapshot {
    param([Parameter(Mandatory)]$Event, [string]$SourceFile)
    if (-not $Event.payload -or $Event.payload.type -ne 'token_count' -or -not $Event.payload.rate_limits) { return $null }
    $r = $Event.payload.rate_limits
    $windows = @()
    foreach ($name in @('primary', 'secondary')) {
        $w = $r.$name
        if ($null -ne $w -and $null -ne $w.used_percent) {
            $reset = if ($w.resets_at) { [DateTimeOffset]::FromUnixTimeSeconds([long]$w.resets_at).LocalDateTime } else { $null }
            $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, [double]$w.used_percent))
            $windows += [pscustomobject]@{
                Name = $name
                UsedPercent = $usedPercent
                RemainingPercent = 100.0 - $usedPercent
                WindowMinutes = if ($w.window_minutes) { [int]$w.window_minutes } else { 0 }
                ResetsAt = $reset
            }
        }
    }
    if ($windows.Count -eq 0) { return $null }
    [pscustomobject]@{
        Timestamp = if ($Event.timestamp) { [DateTimeOffset]::Parse([string]$Event.timestamp).LocalDateTime } else { [DateTime]::Now }
        LimitId = [string]$r.limit_id
        PlanType = [string]$r.plan_type
        Windows = $windows
        SourceFile = $SourceFile
    }
}

function Get-LatestCodexUsage {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $files = Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 12
    foreach ($file in $files) {
        $lines = @(Get-Content -LiteralPath $file.FullName -Tail 500 -ErrorAction SilentlyContinue)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -notmatch '"rate_limits"') { continue }
            try {
                $snapshot = ConvertTo-UsageSnapshot -Event ($lines[$i] | ConvertFrom-Json) -SourceFile $file.FullName
                if ($snapshot) { return $snapshot }
            } catch { continue }
        }
    }
    return $null
}

if ($NoUi) {
    $snapshot = Get-LatestCodexUsage -Path (Get-CodexSessionsPath $SessionsPath)
    if ($Json -and $snapshot) { $snapshot | ConvertTo-Json -Compress -Depth 6 }
    elseif (-not $Json) { $snapshot }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeIconMethods {
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@

function New-UsageIcon {
    param([Nullable[double]]$RemainingPercent)
    $bmp = [System.Drawing.Bitmap]::new(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $value = if ($null -eq $RemainingPercent) { 0.0 } else { [Math]::Max(0.0, [Math]::Min(100.0, [double]$RemainingPercent)) }
        $levelColor = if ($null -eq $RemainingPercent) { [System.Drawing.Color]::SlateGray } elseif ($value -le 10) { [System.Drawing.Color]::Crimson } elseif ($value -le 30) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::SeaGreen }

        $terminalBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
        $insideBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(210, 35, 35, 35))
        $levelBrush = [System.Drawing.SolidBrush]::new($levelColor)
        $outerPen = [System.Drawing.Pen]::new([System.Drawing.Color]::Black, 3)
        $innerPen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 1)
        try {
            $g.FillRectangle($terminalBrush, 11, 1, 10, 5)
            $g.DrawRectangle($outerPen, 11, 1, 10, 5)
            $g.FillRectangle($insideBrush, 6, 7, 20, 21)
            $fillHeight = [int][Math]::Round(20.0 * $value / 100.0)
            if ($fillHeight -gt 0) { $g.FillRectangle($levelBrush, 7, 28 - $fillHeight, 18, $fillHeight) }
            $g.DrawRectangle($outerPen, 4, 5, 24, 24)
            $g.DrawRectangle($innerPen, 4, 5, 24, 24)
        } finally {
            $terminalBrush.Dispose(); $insideBrush.Dispose(); $levelBrush.Dispose(); $outerPen.Dispose(); $innerPen.Dispose()
        }

        $label = if ($null -eq $RemainingPercent) { '?' } else { [Math]::Round($value).ToString('0') }
        $fontSize = if ($label.Length -gt 2) { 9 } elseif ($label.Length -gt 1) { 12 } else { 15 }
        $font = [System.Drawing.Font]::new('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $format = [System.Drawing.StringFormat]::new(); $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
        $textRect = [System.Drawing.RectangleF]::new(4, 5, 24, 25)
        $g.DrawString($label, $font, [System.Drawing.Brushes]::Black, [System.Drawing.RectangleF]::new(5, 6, 24, 25), $format)
        $g.DrawString($label, $font, [System.Drawing.Brushes]::White, $textRect, $format)
        $font.Dispose(); $format.Dispose()
        $handle = $bmp.GetHicon()
        try { return [System.Drawing.Icon]::FromHandle($handle).Clone() }
        finally { [void][NativeIconMethods]::DestroyIcon($handle) }
    } finally { $g.Dispose(); $bmp.Dispose() }
}

$script:notify = [System.Windows.Forms.NotifyIcon]::new()
$script:notify.Visible = $true
$script:lastIcon = $null
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$statusItem = $menu.Items.Add('Loading Codex usage...'); $statusItem.Enabled = $false
$windowItem = $menu.Items.Add(''); $windowItem.Enabled = $false
$resetItem = $menu.Items.Add(''); $resetItem.Enabled = $false
[void]$menu.Items.Add('-')
$refreshItem = $menu.Items.Add('Refresh now')
$startupItem = $menu.Items.Add('Open at sign-in')
$startupItem.CheckOnClick = $true
$exitItem = $menu.Items.Add('Exit')
$script:notify.ContextMenuStrip = $menu

$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Usage Tray.lnk'
$startupItem.Checked = [bool](Test-Path -LiteralPath $startupShortcut)
$startupItem.add_Click({
    if ($startupItem.Checked) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($startupShortcut)
        $shortcut.TargetPath = 'powershell.exe'
        $shortcut.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        $shortcut.WorkingDirectory = Split-Path $PSCommandPath
        $shortcut.Save()
    } else { Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue }
})

function Set-TrayUsage {
    param($Snapshot, [string]$ErrorMessage)
    try {
        if ($ErrorMessage) { throw $ErrorMessage }
        if (-not $Snapshot) {
            $percent = $null; $tip = 'Codex: no usage data'; $statusItem.Text = 'No Codex usage data'
            $windowItem.Text = 'Open Codex and run a task'; $resetItem.Text = ''
        } else {
            $w = $Snapshot.Windows[0]; $percent = [double]$w.RemainingPercent
            $tip = 'Codex remaining {0:N0}% ({1})' -f $percent, $Snapshot.LimitId
            $statusItem.Text = 'Remaining: {0:N1}%' -f $percent
            $windowItem.Text = if ($w.WindowMinutes) { 'Window: {0}' -f ([TimeSpan]::FromMinutes($w.WindowMinutes).ToString()) } else { 'Window: unknown' }
            $resetItem.Text = if ($w.ResetsAt) { 'Resets: {0:g}' -f $w.ResetsAt } else { 'Reset: unknown' }
        }
        $newIcon = New-UsageIcon $percent
        $script:notify.Icon = $newIcon
        if ($script:lastIcon) { $script:lastIcon.Dispose() }
        $script:lastIcon = $newIcon
        $script:notify.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
    } catch {
        $statusItem.Text = 'Could not read Codex usage'; $windowItem.Text = $_.Exception.Message; $resetItem.Text = ''
    }
}

function Start-UsageRefresh {
    if ($script:refreshProcess -and -not $script:refreshProcess.HasExited) { return }
    $statusItem.Text = 'Refreshing...'
    $refreshItem.Enabled = $false
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -NoUi -Json' -f $PSCommandPath
    if ($SessionsPath) { $arguments += ' -SessionsPath "{0}"' -f $SessionsPath }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $script:refreshProcess = [System.Diagnostics.Process]::new()
    $script:refreshProcess.StartInfo = $startInfo
    if (-not $script:refreshProcess.Start()) { throw 'Could not start the usage reader.' }
}

function Complete-UsageRefresh {
    if (-not $script:refreshProcess -or -not $script:refreshProcess.HasExited) { return }
    $output = $script:refreshProcess.StandardOutput.ReadToEnd()
    $errorOutput = $script:refreshProcess.StandardError.ReadToEnd()
    $exitCode = $script:refreshProcess.ExitCode
    $script:refreshProcess.Dispose()
    $script:refreshProcess = $null
    $refreshItem.Enabled = $true
    $script:nextRefresh = [DateTime]::Now.AddSeconds(60)
    if ($exitCode -ne 0) {
        Set-TrayUsage -Snapshot $null -ErrorMessage $(if ($errorOutput) { $errorOutput.Trim() } else { "Usage reader exited with code $exitCode." })
        return
    }
    $snapshot = if ($output.Trim()) { $output | ConvertFrom-Json } else { $null }
    Set-TrayUsage -Snapshot $snapshot
}

$script:refreshProcess = $null
$script:nextRefresh = [DateTime]::MinValue
$refreshItem.add_Click({ Start-UsageRefresh })
$script:notify.add_DoubleClick({ Start-UsageRefresh; $script:notify.ShowBalloonTip(2500, 'Codex usage', $script:notify.Text, 'Info') })
$timer = [System.Windows.Forms.Timer]::new(); $timer.Interval = 250; $timer.add_Tick({
    Complete-UsageRefresh
    if (-not $script:refreshProcess -and [DateTime]::Now -ge $script:nextRefresh) { Start-UsageRefresh }
}); $timer.Start()
$exitItem.add_Click({
    $timer.Stop()
    if ($script:refreshProcess -and -not $script:refreshProcess.HasExited) { $script:refreshProcess.Kill() }
    $script:notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

Start-UsageRefresh
[System.Windows.Forms.Application]::Run()
$timer.Dispose(); $menu.Dispose(); $script:notify.Dispose(); if ($script:lastIcon) { $script:lastIcon.Dispose() }
