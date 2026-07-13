param([switch]$NoUi, [switch]$Json, [switch]$Details, [switch]$LocalOnly, [string]$SessionsPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.2.1'

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
        DataSource = 'local'
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

function Get-CodexAccessToken {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $authPath = Join-Path $codexHome 'auth.json'
    if (-not (Test-Path -LiteralPath $authPath)) { throw 'Codex auth.json was not found. Sign in to ChatGPT/Codex and try again.' }
    $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
    $accessToken = $auth.tokens.access_token
    if (-not $accessToken) { throw 'No Codex access token was found. Sign in to ChatGPT/Codex and try again.' }
    return $accessToken
}

function Get-LiveCodexUsage {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $accessToken = Get-CodexAccessToken
    $response = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage?supports_rewardless_invites=true' -Headers @{
        Authorization = "Bearer $accessToken"
        originator = 'Codex Desktop'
        'OAI-Product-Sku' = 'CODEX'
        Accept = 'application/json'
    }
    if (-not $response.rate_limit) { throw 'The live usage response did not contain rate_limit data.' }
    $windows = @()
    foreach ($name in @('primary', 'secondary')) {
        $propertyName = $name + '_window'; $window = $response.rate_limit.$propertyName
        if ($null -eq $window -or $null -eq $window.used_percent) { continue }
        $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, [double]$window.used_percent))
        $windows += [pscustomobject]@{
            Name = $name
            UsedPercent = $usedPercent
            RemainingPercent = 100.0 - $usedPercent
            WindowMinutes = if ($window.limit_window_seconds) { [int][Math]::Round([double]$window.limit_window_seconds / 60.0) } else { 0 }
            ResetsAt = if ($window.reset_at) { [DateTimeOffset]::FromUnixTimeSeconds([long]$window.reset_at).LocalDateTime } else { $null }
        }
    }
    if ($windows.Count -eq 0) { throw 'The live usage response did not contain a usage window.' }
    [pscustomobject]@{
        Timestamp = [DateTime]::Now
        LimitId = 'codex'
        PlanType = [string]$response.plan_type
        Windows = $windows
        SourceFile = $null
        DataSource = 'live'
    }
}

function Get-AvailableResetCredits {
    $accessToken = Get-CodexAccessToken
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $response = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits' -Headers @{
        Authorization = "Bearer $accessToken"
        originator = 'Codex Desktop'
        'OAI-Product-Sku' = 'CODEX'
        Accept = 'application/json'
    }
    @($response.credits | Where-Object { $_.status -eq 'available' } | ForEach-Object {
        $expiry = [DateTimeOffset]::Parse([string]$_.expires_at)
        [pscustomobject]@{
            Status = [string]$_.status
            ExpiresAtUtc = $expiry.UtcDateTime.ToString('o')
            ExpiresAtLocal = $expiry.LocalDateTime.ToString('o')
        }
    })
}

if ($NoUi) {
    $usageError = $null
    if ($LocalOnly) { $snapshot = Get-LatestCodexUsage -Path (Get-CodexSessionsPath $SessionsPath) }
    else {
        try { $snapshot = Get-LiveCodexUsage }
        catch { $usageError = $_.Exception.Message; $snapshot = Get-LatestCodexUsage -Path (Get-CodexSessionsPath $SessionsPath) }
    }
    if ($Details) {
        try {
            $result = [pscustomobject]@{ Snapshot = $snapshot; Credits = @(Get-AvailableResetCredits); Error = $null; UsageError = $usageError; FetchedAt = [DateTime]::Now.ToString('o') }
        } catch {
            $result = [pscustomobject]@{ Snapshot = $snapshot; Credits = @(); Error = $_.Exception.Message; UsageError = $usageError; FetchedAt = [DateTime]::Now.ToString('o') }
        }
        if ($Json) { $result | ConvertTo-Json -Compress -Depth 8 } else { $result }
    }
    elseif ($Json -and $snapshot) { $snapshot | ConvertTo-Json -Compress -Depth 6 }
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

        $insideBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(210, 35, 35, 35))
        $levelBrush = [System.Drawing.SolidBrush]::new($levelColor)
        $outerPen = [System.Drawing.Pen]::new([System.Drawing.Color]::Black, 2)
        $innerPen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 1)
        try {
            $g.FillRectangle($insideBrush, 2, 1, 28, 30)
            $fillHeight = [int][Math]::Round(29.0 * $value / 100.0)
            if ($fillHeight -gt 0) { $g.FillRectangle($levelBrush, 2, 30 - $fillHeight, 28, $fillHeight) }
            $g.DrawRectangle($outerPen, 1, 0, 30, 31)
            $g.DrawRectangle($innerPen, 1, 0, 30, 31)
        } finally {
            $insideBrush.Dispose(); $levelBrush.Dispose(); $outerPen.Dispose(); $innerPen.Dispose()
        }

        $label = if ($null -eq $RemainingPercent) { '?' } else { [Math]::Round($value).ToString('0') }
        $fontSize = if ($label.Length -gt 2) { 14 } elseif ($label.Length -gt 1) { 20 } else { 23 }
        $font = [System.Drawing.Font]::new('Segoe UI', $fontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $format = [System.Drawing.StringFormat]::new(); $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
        $textRect = [System.Drawing.RectangleF]::new(0, 1, 32, 30)
        $g.DrawString($label, $font, [System.Drawing.Brushes]::Black, [System.Drawing.RectangleF]::new(1, 2, 32, 30), $format)
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
$updateItem = $menu.Items.Add('Check for update')
$startupItem = $menu.Items.Add('Open at sign-in')
$startupItem.CheckOnClick = $true
$versionItem = $menu.Items.Add("Version $script:AppVersion")
$versionItem.Enabled = $false
$exitItem = $menu.Items.Add('Exit')
$script:notify.ContextMenuStrip = $menu
$script:updateResultPath = Join-Path (Split-Path (Split-Path $PSCommandPath)) 'update-result.json'
$script:updateResultShown = $false

function Show-PendingUpdateResult {
    if ($script:updateResultShown -or -not (Test-Path -LiteralPath $script:updateResultPath)) { return }
    $script:updateResultShown = $true
    try {
        $result = Get-Content -Raw -LiteralPath $script:updateResultPath | ConvertFrom-Json
        $title = if ($result.success) { 'Update complete' } else { 'Update failed' }
        $icon = if ($result.success) { 'Info' } else { 'Error' }
        $script:notify.ShowBalloonTip(5000, $title, [string]$result.message, $icon)
    } catch {} finally { Remove-Item -LiteralPath $script:updateResultPath -Force -ErrorAction SilentlyContinue }
}

function Start-SelfUpdate {
    $updaterPath = Join-Path (Split-Path $PSCommandPath) 'Updater.ps1'
    if (-not (Test-Path -LiteralPath $updaterPath)) {
        [void][System.Windows.Forms.MessageBox]::Show('Updater.ps1 is missing. Reinstall the latest package manually.', 'Update unavailable', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $installRoot = Split-Path (Split-Path $PSCommandPath)
    $updateItem.Enabled = $false; $statusItem.Text = 'Starting update...'
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ParentProcessId {1} -InstallRoot "{2}" -Repository "CLSMCSMII/codex-usage-tray"' -f $updaterPath, $PID, $installRoot
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments
    $script:notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

function Start-UpdateCheck {
    if ($script:updateCheckProcess -and -not $script:updateCheckProcess.HasExited) { return }
    $updaterPath = Join-Path (Split-Path $PSCommandPath) 'Updater.ps1'
    if (-not (Test-Path -LiteralPath $updaterPath)) {
        [void][System.Windows.Forms.MessageBox]::Show('Updater.ps1 is missing. Reinstall the latest package manually.', 'Update unavailable', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $script:updatePreviousStatus = $statusItem.Text
    $statusItem.Text = 'Checking for update...'
    $updateItem.Enabled = $false
    $installRoot = Split-Path (Split-Path $PSCommandPath)
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallRoot "{1}" -Repository "CLSMCSMII/codex-usage-tray" -CheckOnly -CurrentVersion "{2}"' -f $updaterPath, $installRoot, $script:AppVersion
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $script:updateCheckProcess = [System.Diagnostics.Process]::new()
    $script:updateCheckProcess.StartInfo = $startInfo
    if (-not $script:updateCheckProcess.Start()) { throw 'Could not start the update check.' }
}

function Complete-UpdateCheck {
    if (-not $script:updateCheckProcess -or -not $script:updateCheckProcess.HasExited) { return }
    $output = $script:updateCheckProcess.StandardOutput.ReadToEnd()
    $errorOutput = $script:updateCheckProcess.StandardError.ReadToEnd()
    $exitCode = $script:updateCheckProcess.ExitCode
    $script:updateCheckProcess.Dispose()
    $script:updateCheckProcess = $null
    $updateItem.Enabled = $true
    $statusItem.Text = $script:updatePreviousStatus
    if ($exitCode -ne 0) {
        $message = if ($errorOutput) { $errorOutput.Trim() } else { "Update check exited with code $exitCode." }
        [void][System.Windows.Forms.MessageBox]::Show($message, 'Could not check for updates', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    try { $result = $output | ConvertFrom-Json }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show('GitHub returned an invalid update response.', 'Could not check for updates', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    if (-not $result.updateAvailable) { return }
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Current version: $($result.currentVersion)`r`nLatest version: $($result.latestVersion)`r`n`r`nDownload and install the update now?",
        'Codex Usage Tray update available',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) { Start-SelfUpdate }
}

function Format-WindowDuration {
    param([int]$Minutes)
    if ($Minutes -le 0) { return 'Unknown' }
    if ($Minutes % 1440 -eq 0) { return ('{0} days' -f ($Minutes / 1440)) }
    if ($Minutes % 60 -eq 0) { return ('{0} hours' -f ($Minutes / 60)) }
    return ('{0} minutes' -f $Minutes)
}

function New-DetailsWindow {
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "Codex Usage Tray v$script:AppVersion - usage and reset credits"
    $form.Size = [System.Drawing.Size]::new(560, 430)
    $form.MinimumSize = [System.Drawing.Size]::new(520, 360)
    $form.StartPosition = 'CenterScreen'
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
    $form.ShowInTaskbar = $false
    $form.KeyPreview = $true
    $form.add_KeyDown({ param($sender, $eventArgs) if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.Close() } })

    $usageLabel = [System.Windows.Forms.Label]::new(); $usageLabel.Text = 'Usage limits'; $usageLabel.AutoSize = $true; $usageLabel.Location = [System.Drawing.Point]::new(12, 12); $usageLabel.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $usageList = [System.Windows.Forms.ListView]::new(); $usageList.Location = [System.Drawing.Point]::new(12, 38); $usageList.Size = [System.Drawing.Size]::new(520, 115); $usageList.Anchor = 'Top,Left,Right'; $usageList.View = 'Details'; $usageList.FullRowSelect = $true; $usageList.GridLines = $true
    [void]$usageList.Columns.Add('Limit', 95); [void]$usageList.Columns.Add('Remaining', 90); [void]$usageList.Columns.Add('Window', 90); [void]$usageList.Columns.Add('Resets (local time)', 220)

    $creditsLabel = [System.Windows.Forms.Label]::new(); $creditsLabel.Text = 'Available reset credits'; $creditsLabel.AutoSize = $true; $creditsLabel.Location = [System.Drawing.Point]::new(12, 169); $creditsLabel.Font = [System.Drawing.Font]::new('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $creditsList = [System.Windows.Forms.ListView]::new(); $creditsList.Location = [System.Drawing.Point]::new(12, 195); $creditsList.Size = [System.Drawing.Size]::new(520, 145); $creditsList.Anchor = 'Top,Bottom,Left,Right'; $creditsList.View = 'Details'; $creditsList.FullRowSelect = $true; $creditsList.GridLines = $true
    [void]$creditsList.Columns.Add('Status', 90); [void]$creditsList.Columns.Add('Expires (local time)', 230); [void]$creditsList.Columns.Add('Time remaining', 160)

    $detailsStatus = [System.Windows.Forms.Label]::new(); $detailsStatus.Text = 'Loading...'; $detailsStatus.AutoEllipsis = $true; $detailsStatus.Location = [System.Drawing.Point]::new(12, 354); $detailsStatus.Size = [System.Drawing.Size]::new(520, 28); $detailsStatus.Anchor = 'Bottom,Left,Right'
    $form.Controls.AddRange(@($usageLabel, $usageList, $creditsLabel, $creditsList, $detailsStatus))
    $form.Tag = [pscustomobject]@{ UsageList = $usageList; CreditsList = $creditsList; Status = $detailsStatus }
    return $form
}

function Update-DetailsWindow {
    param($Data)
    if (-not $script:detailsForm -or $script:detailsForm.IsDisposed) { return }
    $controls = $script:detailsForm.Tag
    $controls.UsageList.Items.Clear(); $controls.CreditsList.Items.Clear()
    if ($Data.Snapshot) {
        foreach ($w in @($Data.Snapshot.Windows)) {
            $resetText = if ($w.ResetsAt) { ([DateTime]::Parse([string]$w.ResetsAt)).ToString('f') } else { 'Unknown' }
            $item = [System.Windows.Forms.ListViewItem]::new(([string]$w.Name))
            [void]$item.SubItems.Add(('{0:N1}%' -f [double]$w.RemainingPercent))
            [void]$item.SubItems.Add((Format-WindowDuration ([int]$w.WindowMinutes)))
            [void]$item.SubItems.Add($resetText); [void]$controls.UsageList.Items.Add($item)
        }
    } else {
        [void]$controls.UsageList.Items.Add([System.Windows.Forms.ListViewItem]::new('No local usage data'))
    }
    foreach ($credit in @($Data.Credits)) {
        $expiry = [DateTime]::Parse([string]$credit.ExpiresAtLocal)
        $remaining = $expiry - [DateTime]::Now
        $remainingText = if ($remaining.TotalSeconds -le 0) { 'Expired' } elseif ($remaining.TotalDays -ge 1) { '{0}d {1}h' -f [Math]::Floor($remaining.TotalDays), $remaining.Hours } else { '{0}h {1}m' -f [Math]::Floor($remaining.TotalHours), $remaining.Minutes }
        $item = [System.Windows.Forms.ListViewItem]::new(([string]$credit.Status))
        [void]$item.SubItems.Add($expiry.ToString('f')); [void]$item.SubItems.Add($remainingText); [void]$controls.CreditsList.Items.Add($item)
    }
    if (@($Data.Credits).Count -eq 0) { [void]$controls.CreditsList.Items.Add([System.Windows.Forms.ListViewItem]::new('No available credits')) }
    $checkedAt = ([DateTime]::Parse([string]$Data.FetchedAt)).ToString('T')
    if ($Data.Snapshot -and [string]$Data.Snapshot.DataSource -eq 'live') {
        $sourceText = "Live usage and credits checked $checkedAt"
    } elseif ($Data.Snapshot) {
        $snapshotAt = ([DateTime]::Parse([string]$Data.Snapshot.Timestamp)).ToString('g')
        $sourceText = "Local usage snapshot $snapshotAt; credits checked $checkedAt"
    } else { $sourceText = "No usage snapshot; credits checked $checkedAt" }
    if ($Data.Error) { $sourceText += '; credits unavailable: ' + [string]$Data.Error }
    elseif ($Data.UsageError) { $sourceText += '; live usage unavailable' }
    $controls.Status.Text = $sourceText
}

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
            $script:lastSnapshot = $Snapshot
            $w = $Snapshot.Windows[0]; $percent = [double]$w.RemainingPercent
            $tip = 'Codex v{0} remaining {1:N0}% ({2})' -f $script:AppVersion, $percent, $Snapshot.LimitId
            $statusItem.Text = 'Remaining: {0:N1}%' -f $percent
            $windowItem.Text = if ($w.WindowMinutes) { 'Window: {0}' -f ([TimeSpan]::FromMinutes($w.WindowMinutes).ToString()) } else { 'Window: unknown' }
            $resetItem.Text = if ($w.ResetsAt) { 'Resets: {0:g}' -f $w.ResetsAt } else { 'Reset: unknown' }
        }
        $newIcon = New-UsageIcon $percent
        $script:notify.Icon = $newIcon
        if ($script:lastIcon) { $script:lastIcon.Dispose() }
        $script:lastIcon = $newIcon
        $script:notify.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
        Show-PendingUpdateResult
    } catch {
        $statusItem.Text = 'Could not read Codex usage'; $windowItem.Text = $_.Exception.Message; $resetItem.Text = ''
    }
}

function Start-DetailsRefresh {
    if (-not $script:detailsForm -or $script:detailsForm.IsDisposed) {
        $script:detailsForm = New-DetailsWindow
        $script:detailsForm.add_FormClosed({ $script:detailsForm = $null })
    }
    $script:detailsForm.Show(); $script:detailsForm.Activate()
    $script:detailsForm.Tag.Status.Text = 'Loading reset credits...'
    if ($script:detailsProcess -and -not $script:detailsProcess.HasExited) { return }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -NoUi -Json -Details' -f $PSCommandPath
    if ($SessionsPath) { $arguments += ' -SessionsPath "{0}"' -f $SessionsPath }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new(); $startInfo.FileName = 'powershell.exe'; $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true; $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    $script:detailsProcess = [System.Diagnostics.Process]::new(); $script:detailsProcess.StartInfo = $startInfo
    if (-not $script:detailsProcess.Start()) { $script:detailsForm.Tag.Status.Text = 'Could not start the details reader.' }
}

function Complete-DetailsRefresh {
    if (-not $script:detailsProcess -or -not $script:detailsProcess.HasExited) { return }
    $output = $script:detailsProcess.StandardOutput.ReadToEnd(); $errorOutput = $script:detailsProcess.StandardError.ReadToEnd(); $exitCode = $script:detailsProcess.ExitCode
    $script:detailsProcess.Dispose(); $script:detailsProcess = $null
    if (-not $script:detailsForm -or $script:detailsForm.IsDisposed) { return }
    if ($exitCode -ne 0) { $script:detailsForm.Tag.Status.Text = if ($errorOutput) { $errorOutput.Trim() } else { "Details reader exited with code $exitCode." }; return }
    try { Update-DetailsWindow ($output | ConvertFrom-Json) } catch { $script:detailsForm.Tag.Status.Text = 'Could not parse details: ' + $_.Exception.Message }
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
$script:detailsProcess = $null
$script:updateCheckProcess = $null
$script:updatePreviousStatus = ''
$script:detailsForm = $null
$script:lastSnapshot = $null
$script:nextRefresh = [DateTime]::MinValue
$refreshItem.add_Click({ Start-UsageRefresh })
$updateItem.add_Click({ Start-UpdateCheck })
$script:notify.add_MouseClick({ param($sender, $eventArgs) if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-DetailsRefresh } })
$timer = [System.Windows.Forms.Timer]::new(); $timer.Interval = 250; $timer.add_Tick({
    Complete-UsageRefresh
    Complete-DetailsRefresh
    Complete-UpdateCheck
    if (-not $script:refreshProcess -and [DateTime]::Now -ge $script:nextRefresh) { Start-UsageRefresh }
}); $timer.Start()
$exitItem.add_Click({
    $timer.Stop()
    if ($script:refreshProcess -and -not $script:refreshProcess.HasExited) { $script:refreshProcess.Kill() }
    if ($script:detailsProcess -and -not $script:detailsProcess.HasExited) { $script:detailsProcess.Kill() }
    if ($script:updateCheckProcess -and -not $script:updateCheckProcess.HasExited) { $script:updateCheckProcess.Kill() }
    if ($script:detailsForm -and -not $script:detailsForm.IsDisposed) { $script:detailsForm.Close() }
    $script:notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

Start-UsageRefresh
[System.Windows.Forms.Application]::Run()
$timer.Dispose(); $menu.Dispose(); $script:notify.Dispose(); if ($script:lastIcon) { $script:lastIcon.Dispose() }
