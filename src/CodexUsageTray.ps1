param([switch]$NoUi, [switch]$Json, [switch]$Details, [switch]$LocalOnly, [switch]$HiddenLaunch, [string]$SessionsPath, [string]$CodexHome)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.4.3'
$script:ApiTimeoutSec = 20
$script:ChildProcessTimeoutSec = 45
$script:UpdateCheckTimeoutSec = 180
$script:MaxLocalSnapshotAgeHours = 24
$script:AccountLoginTimeoutSec = 300

$script:installRoot = Split-Path (Split-Path $PSCommandPath)
$script:launcherPath = Join-Path $script:installRoot 'Launcher.vbs'
$script:defaultCodexHome = if ($env:CODEX_HOME) { [IO.Path]::GetFullPath($env:CODEX_HOME) } else { [IO.Path]::GetFullPath((Join-Path $HOME '.codex')) }
$script:accountsRoot = Join-Path $env:LOCALAPPDATA 'CodexUsageTrayAccounts'
$script:settingsRoot = Join-Path $env:LOCALAPPDATA 'CodexUsageTrayData'
$script:settingsPath = Join-Path $script:settingsRoot 'settings.json'

function Initialize-HiddenLauncher {
    if (Test-Path -LiteralPath $script:launcherPath) { return }
    @'
Option Explicit
Dim shell, fileSystem, installRoot, appPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
installRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
appPath = fileSystem.BuildPath(installRoot, "src\CodexUsageTray.ps1")
command = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & Chr(34) & appPath & Chr(34) & " -HiddenLaunch"
shell.CurrentDirectory = shell.ExpandEnvironmentStrings("%TEMP%")
shell.Run command, 0, False
'@ | Set-Content -LiteralPath $script:launcherPath -Encoding ASCII
}

if (-not $NoUi -and -not $HiddenLaunch) {
    Initialize-HiddenLauncher
    $launcherArgument = '"' + $script:launcherPath + '"'
    Start-Process (Join-Path $env:SystemRoot 'System32\wscript.exe') -WindowStyle Hidden -WorkingDirectory ([IO.Path]::GetTempPath()) -ArgumentList @('//B', '//NoLogo', $launcherArgument)
    return
}

$script:singleInstanceMutex = $null
if (-not $NoUi) {
    $createdNew = $false
    $script:singleInstanceMutex = [System.Threading.Mutex]::new($true, 'Local\CLSMCSMII.CodexUsageTray', [ref]$createdNew)
    if (-not $createdNew) {
        $script:singleInstanceMutex.Dispose()
        return
    }
}

function Get-CodexSessionsPath {
    param([string]$Override)
    if ($Override) { return $Override }
    $homePath = if ($CodexHome) { $CodexHome } else { $script:defaultCodexHome }
    return (Join-Path $homePath 'sessions')
}

function ConvertFrom-JwtPayload {
    param([string]$Token)
    if (-not $Token) { return $null }
    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { return $null }
        $payload = [string]$parts[1]
        $payload += '=' * ((4 - ($payload.Length % 4)) % 4)
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.Replace('-', '+').Replace('_', '/')))
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

function Get-CodexPlanDisplayName {
    param([string]$PlanType)
    $normalized = ([string]$PlanType).Trim().ToLowerInvariant()
    switch ($normalized) {
        'team' { return 'Business' }
        'business' { return 'Business' }
        'enterprise' { return 'Enterprise' }
        'edu' { return 'Edu' }
        'pro' { return 'Pro' }
        'plus' { return 'Plus' }
        'free' { return 'Free' }
        '' { return '' }
        default {
            return [Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase(($normalized -replace '[_-]+', ' '))
        }
    }
}

function Get-CodexAccountProfile {
    param([Parameter(Mandatory)][string]$HomePath, [bool]$IsDefault = $false)
    try { $fullHome = [IO.Path]::GetFullPath($HomePath) } catch { return $null }
    $authPath = Join-Path $fullHome 'auth.json'
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) { return $null }
    try {
        $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
        if (-not $auth.tokens.access_token) { return $null }
        $claims = ConvertFrom-JwtPayload ([string]$auth.tokens.id_token)
        $displayName = if ($claims -and $claims.name) { [string]$claims.name } elseif ($claims -and $claims.email) { [string]$claims.email } else { 'ChatGPT account' }
        $displayName = ($displayName -replace '[\x00-\x1F]', ' ').Trim()
        if ($displayName.Length -gt 60) { $displayName = $displayName.Substring(0, 60) }
        $email = if ($claims -and $claims.email) { ([string]$claims.email -replace '[\x00-\x1F]', ' ').Trim() } else { '' }
        $authClaims = $null
        if ($claims) {
            $authClaimProperty = $claims.PSObject.Properties['https://api.openai.com/auth']
            if ($authClaimProperty) { $authClaims = $authClaimProperty.Value }
        }
        $accountId = if ($auth.tokens.account_id) { [string]$auth.tokens.account_id } else { '' }
        if (-not $accountId -and $authClaims) {
            $accountProperty = $authClaims.PSObject.Properties['chatgpt_account_id']
            if ($accountProperty) { $accountId = [string]$accountProperty.Value }
        }
        $planType = ''
        if ($authClaims) {
            $planProperty = $authClaims.PSObject.Properties['chatgpt_plan_type']
            if ($planProperty) { $planType = ([string]$planProperty.Value -replace '[\x00-\x1F]', ' ').Trim() }
        }
        $planDisplayName = Get-CodexPlanDisplayName $planType
        $identityLabel = if ($email) { $email } else { $displayName }
        $menuLabel = if ($planDisplayName) { '{0} ({1})' -f $identityLabel, $planDisplayName } else { $identityLabel }
        [pscustomobject]@{
            DisplayName = $displayName
            Email = $email
            AccountId = $accountId
            PlanType = $planType
            PlanDisplayName = $planDisplayName
            MenuLabel = $menuLabel
            CodexHome = $fullHome
            IsDefault = $IsDefault
        }
    } catch { return $null }
}

function Get-CodexAccountProfiles {
    param([string]$DefaultHome = $script:defaultCodexHome, [string]$ProfilesRoot = $script:accountsRoot)
    $profiles = @()
    $defaultProfile = Get-CodexAccountProfile -HomePath $DefaultHome -IsDefault $true
    if ($defaultProfile) { $profiles += $defaultProfile }
    if (Test-Path -LiteralPath $ProfilesRoot -PathType Container) {
        foreach ($directory in @(Get-ChildItem -LiteralPath $ProfilesRoot -Directory -ErrorAction SilentlyContinue)) {
            $profile = Get-CodexAccountProfile -HomePath $directory.FullName
            if ($profile) { $profiles += $profile }
        }
    }
    $seen = @{}
    @($profiles | Where-Object {
        $key = if ($_.AccountId) { 'account:' + $_.AccountId } else { 'path:' + $_.CodexHome.ToLowerInvariant() }
        if ($seen.ContainsKey($key)) { return $false }
        $seen[$key] = $true
        return $true
    } | Sort-Object @{ Expression = { -not $_.IsDefault } }, Email, PlanDisplayName, DisplayName)
}

function Read-SelectedCodexHome {
    param([string]$Path = $script:settingsPath)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $settings = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
        if (-not $settings.selectedCodexHome) { return $null }
        return [IO.Path]::GetFullPath([string]$settings.selectedCodexHome)
    } catch { return $null }
}

function Save-SelectedCodexHome {
    param([Parameter(Mandatory)][string]$HomePath, [string]$Path = $script:settingsPath)
    $parent = Split-Path $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('settings-' + [guid]::NewGuid() + '.tmp')
    try {
        [pscustomobject]@{ selectedCodexHome = [IO.Path]::GetFullPath($HomePath) } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
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

function Get-FileTailLines {
    param([Parameter(Mandatory)][string]$Path, [int]$Count = 500)
    if ($Count -le 0) { return @() }
    $lines = [Collections.Generic.Queue[string]]::new($Count)
    $stream = $null
    $reader = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        while (($line = $reader.ReadLine()) -ne $null) {
            if ($lines.Count -eq $Count) { [void]$lines.Dequeue() }
            $lines.Enqueue($line)
        }
        return @($lines.ToArray())
    } catch {
        return @()
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Get-LatestCodexUsage {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $files = Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
    $latestSnapshot = $null
    foreach ($file in $files) {
        $lines = @(Get-FileTailLines -Path $file.FullName -Count 500)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -notmatch '"rate_limits"') { continue }
            try {
                $snapshot = ConvertTo-UsageSnapshot -Event ($lines[$i] | ConvertFrom-Json) -SourceFile $file.FullName
                if ($snapshot -and ($null -eq $latestSnapshot -or $snapshot.Timestamp -gt $latestSnapshot.Timestamp)) {
                    $latestSnapshot = $snapshot
                }
            } catch { continue }
        }
    }
    if ($latestSnapshot) {
        $snapshotAge = [DateTime]::Now - [DateTime]$latestSnapshot.Timestamp
        if ($snapshotAge.TotalHours -gt $script:MaxLocalSnapshotAgeHours -or $snapshotAge.TotalMinutes -lt -5) { return $null }
        $displayWindow = @($latestSnapshot.Windows)[0]
        if ($displayWindow.ResetsAt -and [DateTime]$displayWindow.ResetsAt -le [DateTime]::Now) { return $null }
    }
    return $latestSnapshot
}

function Get-CodexAccessToken {
    $codexHome = if ($CodexHome) { $CodexHome } else { $script:defaultCodexHome }
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
    $response = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage?supports_rewardless_invites=true' -TimeoutSec $script:ApiTimeoutSec -Headers @{
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
    $response = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/rate-limit-reset-credits' -TimeoutSec $script:ApiTimeoutSec -Headers @{
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
$script:accountProfiles = @(Get-CodexAccountProfiles)
$requestedCodexHome = Read-SelectedCodexHome
$script:selectedAccount = $null
if ($requestedCodexHome) {
    $script:selectedAccount = @($script:accountProfiles | Where-Object { $_.CodexHome -eq $requestedCodexHome } | Select-Object -First 1)
    if ($script:selectedAccount.Count -gt 0) { $script:selectedAccount = $script:selectedAccount[0] } else { $script:selectedAccount = $null }
}
if (-not $script:selectedAccount -and $script:accountProfiles.Count -gt 0) { $script:selectedAccount = $script:accountProfiles[0] }
$script:selectedCodexHome = if ($script:selectedAccount) { [string]$script:selectedAccount.CodexHome } else { $script:defaultCodexHome }
$menu = [System.Windows.Forms.ContextMenuStrip]::new()
$accountItem = $menu.Items.Add($(if ($script:selectedAccount) { [string]$script:selectedAccount.MenuLabel } else { 'No signed-in account' }))
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

function Stop-AccountChildProcesses {
    foreach ($name in @('refreshProcess', 'detailsProcess')) {
        $process = Get-Variable -Name $name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        try {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        } catch {} finally {
            try { $process.Dispose() } catch {}
            Set-Variable -Name $name -Scope Script -Value $null
        }
    }
    $refreshItem.Enabled = $true
}

function Select-CodexAccount {
    param([Parameter(Mandatory)][string]$HomePath)
    $profile = @(Get-CodexAccountProfiles | Where-Object { $_.CodexHome -eq [IO.Path]::GetFullPath($HomePath) } | Select-Object -First 1)
    if ($profile.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('That account login is no longer available. Add the account again.', 'Account unavailable', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        Refresh-AccountMenu
        return
    }
    $script:selectedAccount = $profile[0]
    $script:selectedCodexHome = [string]$script:selectedAccount.CodexHome
    Save-SelectedCodexHome -HomePath $script:selectedCodexHome
    Stop-AccountChildProcesses
    $script:lastSnapshot = $null
    Refresh-AccountMenu -PreferredHome $script:selectedCodexHome
    $statusItem.Text = 'Refreshing...'
    $windowItem.Text = ''
    $resetItem.Text = ''
    $pendingIcon = New-UsageIcon $null
    $script:notify.Icon = $pendingIcon
    if ($script:lastIcon) { $script:lastIcon.Dispose() }
    $script:lastIcon = $pendingIcon
    $refreshTooltip = 'Codex: refreshing {0}' -f $script:selectedAccount.MenuLabel
    $script:notify.Text = $refreshTooltip.Substring(0, [Math]::Min(63, $refreshTooltip.Length))
    Start-UsageRefresh
    if ($script:detailsForm -and -not $script:detailsForm.IsDisposed) { Start-DetailsRefresh }
}

function Refresh-AccountMenu {
    param([string]$PreferredHome)
    $accountItem.DropDownItems.Clear()
    $script:accountProfiles = @(Get-CodexAccountProfiles)
    $wantedHome = if ($PreferredHome) { [IO.Path]::GetFullPath($PreferredHome) } elseif ($script:selectedCodexHome) { [IO.Path]::GetFullPath($script:selectedCodexHome) } else { $script:defaultCodexHome }
    $selected = @($script:accountProfiles | Where-Object { $_.CodexHome -eq $wantedHome } | Select-Object -First 1)
    if ($selected.Count -gt 0) {
        $script:selectedAccount = $selected[0]
        $script:selectedCodexHome = [string]$script:selectedAccount.CodexHome
        $accountItem.Text = [string]$script:selectedAccount.MenuLabel
        $accountItem.ToolTipText = [string]$script:selectedAccount.MenuLabel
    } else {
        $script:selectedAccount = $null
        $script:selectedCodexHome = $script:defaultCodexHome
        $accountItem.Text = 'No signed-in account'
        $accountItem.ToolTipText = 'Add a ChatGPT account'
    }
    foreach ($profile in $script:accountProfiles) {
        $item = [System.Windows.Forms.ToolStripMenuItem]::new([string]$profile.MenuLabel)
        $item.Checked = ($profile.CodexHome -eq $script:selectedCodexHome)
        $item.Tag = [string]$profile.CodexHome
        $item.add_Click({ param($sender, $eventArgs) Select-CodexAccount -HomePath ([string]$sender.Tag) })
        [void]$accountItem.DropDownItems.Add($item)
    }
    if ($script:accountProfiles.Count -gt 0) { [void]$accountItem.DropDownItems.Add([System.Windows.Forms.ToolStripSeparator]::new()) }
    $addAccountItem = [System.Windows.Forms.ToolStripMenuItem]::new('Add account...')
    $addAccountItem.add_Click({ Start-AddAccountLogin })
    [void]$accountItem.DropDownItems.Add($addAccountItem)
    $reloadAccountsItem = [System.Windows.Forms.ToolStripMenuItem]::new('Refresh account list')
    $reloadAccountsItem.add_Click({ Refresh-AccountMenu })
    [void]$accountItem.DropDownItems.Add($reloadAccountsItem)
}

function Get-CodexExecutable {
    $candidates = @((Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'))
    foreach ($name in @('codex.exe', 'codex')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Source) { $candidates += [string]$command.Source }
    }
    $windowsAppsPrefix = (Join-Path $env:ProgramFiles 'WindowsApps').TrimEnd('\') + '\'
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not $candidate) { continue }
        try { $fullPath = [IO.Path]::GetFullPath($candidate) } catch { continue }
        if ($fullPath.StartsWith($windowsAppsPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { return $fullPath }
    }
    return $null
}

function Start-AddAccountLogin {
    if ($script:accountLoginProcess -and -not $script:accountLoginProcess.HasExited) {
        [void][System.Windows.Forms.MessageBox]::Show('An account sign-in is already in progress. Complete it in your browser first.', 'Sign-in in progress', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $codexExecutable = Get-CodexExecutable
    if (-not $codexExecutable) {
        $installChoice = [System.Windows.Forms.MessageBox]::Show(
            "Adding another account requires the standalone Codex CLI. The copy bundled inside the ChatGPT app is protected by Windows and cannot start a separate login.`r`n`r`nOpen the official Codex CLI installation instructions?",
            'Standalone Codex CLI required',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($installChoice -eq [System.Windows.Forms.DialogResult]::Yes) { Start-Process 'https://learn.chatgpt.com/docs/codex/cli' }
        return
    }
    $choice = [System.Windows.Forms.MessageBox]::Show('Your browser will open for ChatGPT sign-in. Sign in with the account you want to add, then return to the tray app.', 'Add ChatGPT account', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Information)
    if ($choice -ne [System.Windows.Forms.DialogResult]::OK) { return }
    New-Item -ItemType Directory -Path $script:accountsRoot -Force | Out-Null
    $profileHome = Join-Path $script:accountsRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $profileHome -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $profileHome 'config.toml') -Encoding UTF8 -Value 'cli_auth_credentials_store = "file"'
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $codexExecutable
    $startInfo.Arguments = 'login'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $profileHome
    $script:accountLoginProcess = [System.Diagnostics.Process]::new()
    $script:accountLoginProcess.StartInfo = $startInfo
    try {
        if (-not $script:accountLoginProcess.Start()) { throw 'Could not start ChatGPT sign-in.' }
        $script:accountLoginHome = $profileHome
        $script:accountLoginStartedAt = [DateTime]::Now
        $script:notify.ShowBalloonTip(5000, 'ChatGPT sign-in', 'Complete the account sign-in in your browser.', [System.Windows.Forms.ToolTipIcon]::Info)
    } catch {
        $script:accountLoginProcess.Dispose(); $script:accountLoginProcess = $null
        Remove-Item -LiteralPath $profileHome -Recurse -Force -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show('The standalone Codex sign-in could not start. Reinstall the Codex CLI or restart Windows, then try again.', 'Cannot add account', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Complete-AccountLogin {
    if (-not $script:accountLoginProcess) { return }
    if (-not $script:accountLoginProcess.HasExited) {
        if (([DateTime]::Now - $script:accountLoginStartedAt).TotalSeconds -le $script:AccountLoginTimeoutSec) { return }
        try { $script:accountLoginProcess.Kill(); [void]$script:accountLoginProcess.WaitForExit(5000) } catch {}
        $script:accountLoginProcess.Dispose(); $script:accountLoginProcess = $null
        [void][System.Windows.Forms.MessageBox]::Show('Account sign-in timed out. Choose Add account to try again.', 'Sign-in timed out', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $exitCode = $script:accountLoginProcess.ExitCode
    $script:accountLoginProcess.Dispose(); $script:accountLoginProcess = $null
    $profile = Get-CodexAccountProfile -HomePath $script:accountLoginHome
    if ($exitCode -eq 0 -and $profile) {
        Select-CodexAccount -HomePath $profile.CodexHome
        [void][System.Windows.Forms.MessageBox]::Show("$($profile.MenuLabel) was added and selected.", 'Account added', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } else {
        if (-not (Test-Path -LiteralPath (Join-Path $script:accountLoginHome 'auth.json') -PathType Leaf)) { Remove-Item -LiteralPath $script:accountLoginHome -Recurse -Force -ErrorAction SilentlyContinue }
        [void][System.Windows.Forms.MessageBox]::Show('ChatGPT sign-in did not complete. Choose Add account to try again.', 'Account not added', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
}

Refresh-AccountMenu -PreferredHome $script:selectedCodexHome

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

function Remove-PendingUpdateArchive {
    param($Result)
    if (-not $Result -or -not $Result.archivePath) { return }
    try {
        $installRoot = [IO.Path]::GetFullPath((Split-Path (Split-Path $PSCommandPath)))
        $candidate = [IO.Path]::GetFullPath([string]$Result.archivePath)
        $prefix = $installRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($candidate) -like 'pending-update-*.zip') {
            Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Start-SelfUpdate {
    param([Parameter(Mandatory)]$Update)
    $updaterPath = Join-Path (Split-Path $PSCommandPath) 'Updater.ps1'
    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show('Updater.ps1 is missing. Reinstall the latest package manually.', 'Update unavailable', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $archivePath = [string]$Update.archivePath
    $archiveSha256 = [string]$Update.archiveSha256
    $latestVersion = [string]$Update.latestVersion
    $sourceCommit = [string]$Update.sourceCommit
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or $archivePath.Contains('"') -or
        $archiveSha256 -notmatch '^[0-9a-fA-F]{64}$' -or $latestVersion.Contains('"') -or
        ($sourceCommit -and $sourceCommit -notmatch '^[0-9a-fA-F]{40}$')) {
        Remove-PendingUpdateArchive $Update
        [void][System.Windows.Forms.MessageBox]::Show('The approved update identity is invalid. Run the update check again.', 'Update unavailable', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    try { [void][version]$latestVersion }
    catch {
        Remove-PendingUpdateArchive $Update
        [void][System.Windows.Forms.MessageBox]::Show('The approved update version is invalid. Run the update check again.', 'Update unavailable', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $installRoot = Split-Path (Split-Path $PSCommandPath)
    $parentStartTicks = [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
    $updateItem.Enabled = $false; $statusItem.Text = 'Starting update...'
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ParentProcessId {1} -ParentProcessStartTimeUtcTicks {2} -InstallRoot "{3}" -Repository "CLSMCSMII/codex-usage-tray" -SourceArchive "{4}" -ExpectedArchiveSha256 "{5}" -ExpectedVersion "{6}" -DeleteSourceArchive' -f $updaterPath, $PID, $parentStartTicks, $installRoot, $archivePath, $archiveSha256, $latestVersion
    if ($sourceCommit) { $arguments += ' -SourceCommit "{0}"' -f $sourceCommit }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $arguments
    $startInfo.WorkingDirectory = [IO.Path]::GetTempPath()
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start the updater.' }
    } catch {
        $process.Dispose()
        $updateItem.Enabled = $true
        $statusItem.Text = $script:updatePreviousStatus
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Update unavailable', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $process.Dispose()
    $script:pendingUpdate = $null
    $script:notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}

function Start-UpdateCheck {
    if ($script:updateCheckProcess -and -not $script:updateCheckProcess.HasExited) { return }
    $updaterPath = Join-Path (Split-Path $PSCommandPath) 'Updater.ps1'
    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show('Updater.ps1 is missing. Reinstall the latest package manually.', 'Update unavailable', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $script:updatePreviousStatus = $statusItem.Text
    $statusItem.Text = 'Checking for update...'
    $updateItem.Enabled = $false
    $installRoot = Split-Path (Split-Path $PSCommandPath)
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallRoot "{1}" -Repository "CLSMCSMII/codex-usage-tray" -CheckOnly -PersistArchive -CurrentVersion "{2}"' -f $updaterPath, $installRoot, $script:AppVersion
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
    $script:updateCheckProcessStartedAt = [DateTime]::Now
}

function Show-UpToDateWindow {
    param([string]$CurrentVersion, [string]$LatestVersion)
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Codex Usage Tray is up to date'
    $form.ClientSize = [System.Drawing.Size]::new(390, 145)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = [System.Drawing.Font]::new('Segoe UI', 9)
    $form.KeyPreview = $true

    $label = [System.Windows.Forms.Label]::new()
    $label.AutoSize = $false
    $label.Location = [System.Drawing.Point]::new(18, 17)
    $label.Size = [System.Drawing.Size]::new(354, 75)
    $label.Text = "Current version: $CurrentVersion`r`nLatest version: $LatestVersion`r`n`r`nNo update needed. You already have the latest version."

    $okButton = [System.Windows.Forms.Button]::new()
    $okButton.Text = 'OK'
    $okButton.Size = [System.Drawing.Size]::new(85, 28)
    $okButton.Location = [System.Drawing.Point]::new(287, 103)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $form.AcceptButton = $okButton
    $form.CancelButton = $okButton
    $form.add_KeyDown({ param($sender, $eventArgs) if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.Close() } })
    $form.Controls.AddRange(@($label, $okButton))
    try { [void]$form.ShowDialog() } finally { $form.Dispose() }
}

function Complete-UpdateCheck {
    if (-not $script:updateCheckProcess) { return }
    if (-not $script:updateCheckProcess.HasExited) {
        if (([DateTime]::Now - $script:updateCheckProcessStartedAt).TotalSeconds -le $script:UpdateCheckTimeoutSec) { return }
        try { $script:updateCheckProcess.Kill(); [void]$script:updateCheckProcess.WaitForExit(5000) } catch {}
        $script:updateCheckProcess.Dispose(); $script:updateCheckProcess = $null
        $updateItem.Enabled = $true; $statusItem.Text = $script:updatePreviousStatus
        [void][System.Windows.Forms.MessageBox]::Show('The update check timed out.', 'Could not check for updates', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
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
    $result = $null
    try {
        $result = $output | ConvertFrom-Json
        if ($result.archiveSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Invalid archive identity.' }
        if ($result.sourceCommit -and [string]$result.sourceCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid source commit.' }
        [void][version]([string]$result.currentVersion)
        [void][version]([string]$result.latestVersion)
    } catch {
        Remove-PendingUpdateArchive $result
        [void][System.Windows.Forms.MessageBox]::Show('GitHub returned an invalid update response.', 'Could not check for updates', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    if (-not $result.updateAvailable) {
        Remove-PendingUpdateArchive $result
        Show-UpToDateWindow -CurrentVersion ([string]$result.currentVersion) -LatestVersion ([string]$result.latestVersion)
        return
    }
    if (-not $result.archivePath -or -not (Test-Path -LiteralPath ([string]$result.archivePath) -PathType Leaf)) {
        [void][System.Windows.Forms.MessageBox]::Show('The checked update archive is missing. Run the update check again.', 'Could not check for updates', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    $commitText = if ($result.sourceCommit) { "`r`nSource commit: $(([string]$result.sourceCommit).Substring(0, 12))" } else { '' }
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "Current version: $($result.currentVersion)`r`nLatest version: $($result.latestVersion)$commitText`r`n`r`nInstall this exact verified archive now?",
        'Codex Usage Tray update available',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:pendingUpdate = $result
        Start-SelfUpdate -Update $result
    } else {
        Remove-PendingUpdateArchive $result
    }
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
function Set-StartupShortcut {
    Initialize-HiddenLauncher
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupShortcut)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = '//B //NoLogo "' + $script:launcherPath + '"'
    $shortcut.WorkingDirectory = [IO.Path]::GetTempPath()
    $shortcut.Description = 'Codex usage indicator'
    $shortcut.Save()
}
$startupItem.Checked = [bool](Test-Path -LiteralPath $startupShortcut)
if ($startupItem.Checked) { Set-StartupShortcut }
$startupItem.add_Click({
    if ($startupItem.Checked) {
        Set-StartupShortcut
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
        $newIcon = New-UsageIcon $null
        $script:notify.Icon = $newIcon
        if ($script:lastIcon) { $script:lastIcon.Dispose() }
        $script:lastIcon = $newIcon
        $script:notify.Text = 'Codex: usage unavailable'
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
    if ($script:selectedCodexHome) { $arguments += ' -CodexHome "{0}"' -f $script:selectedCodexHome }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new(); $startInfo.FileName = 'powershell.exe'; $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true; $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    $script:detailsProcess = [System.Diagnostics.Process]::new(); $script:detailsProcess.StartInfo = $startInfo
    if (-not $script:detailsProcess.Start()) {
        $script:detailsProcess.Dispose(); $script:detailsProcess = $null
        $script:detailsForm.Tag.Status.Text = 'Could not start the details reader.'
        return
    }
    $script:detailsProcessStartedAt = [DateTime]::Now
}

function Complete-DetailsRefresh {
    if (-not $script:detailsProcess) { return }
    if (-not $script:detailsProcess.HasExited) {
        if (([DateTime]::Now - $script:detailsProcessStartedAt).TotalSeconds -le $script:ChildProcessTimeoutSec) { return }
        try { $script:detailsProcess.Kill(); [void]$script:detailsProcess.WaitForExit(5000) } catch {}
        $script:detailsProcess.Dispose(); $script:detailsProcess = $null
        if ($script:detailsForm -and -not $script:detailsForm.IsDisposed) { $script:detailsForm.Tag.Status.Text = 'The details request timed out.' }
        return
    }
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
    if ($script:selectedCodexHome) { $arguments += ' -CodexHome "{0}"' -f $script:selectedCodexHome }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $script:refreshProcess = [System.Diagnostics.Process]::new()
    $script:refreshProcess.StartInfo = $startInfo
    if (-not $script:refreshProcess.Start()) {
        $script:refreshProcess.Dispose(); $script:refreshProcess = $null
        $refreshItem.Enabled = $true
        throw 'Could not start the usage reader.'
    }
    $script:refreshProcessStartedAt = [DateTime]::Now
}

function Complete-UsageRefresh {
    if (-not $script:refreshProcess) { return }
    if (-not $script:refreshProcess.HasExited) {
        if (([DateTime]::Now - $script:refreshProcessStartedAt).TotalSeconds -le $script:ChildProcessTimeoutSec) { return }
        try { $script:refreshProcess.Kill(); [void]$script:refreshProcess.WaitForExit(5000) } catch {}
        $script:refreshProcess.Dispose(); $script:refreshProcess = $null
        $refreshItem.Enabled = $true
        $script:nextRefresh = [DateTime]::Now.AddSeconds(60)
        Set-TrayUsage -Snapshot $null -ErrorMessage 'The usage request timed out.'
        return
    }
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
    try {
        $snapshot = if ($output.Trim()) { $output | ConvertFrom-Json } else { $null }
        Set-TrayUsage -Snapshot $snapshot
    } catch {
        Set-TrayUsage -Snapshot $null -ErrorMessage ('Could not parse usage response: ' + $_.Exception.Message)
    }
}

$script:refreshProcess = $null
$script:detailsProcess = $null
$script:updateCheckProcess = $null
$script:accountLoginProcess = $null
$script:accountLoginHome = $null
$script:refreshProcessStartedAt = [DateTime]::MinValue
$script:detailsProcessStartedAt = [DateTime]::MinValue
$script:updateCheckProcessStartedAt = [DateTime]::MinValue
$script:accountLoginStartedAt = [DateTime]::MinValue
$script:updatePreviousStatus = ''
$script:pendingUpdate = $null
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
    Complete-AccountLogin
    if (-not $script:refreshProcess -and [DateTime]::Now -ge $script:nextRefresh) { Start-UsageRefresh }
}); $timer.Start()
$exitItem.add_Click({
    $timer.Stop()
    if ($script:refreshProcess -and -not $script:refreshProcess.HasExited) { $script:refreshProcess.Kill() }
    if ($script:detailsProcess -and -not $script:detailsProcess.HasExited) { $script:detailsProcess.Kill() }
    if ($script:updateCheckProcess -and -not $script:updateCheckProcess.HasExited) { $script:updateCheckProcess.Kill() }
    if ($script:accountLoginProcess -and -not $script:accountLoginProcess.HasExited) { $script:accountLoginProcess.Kill() }
    Remove-PendingUpdateArchive $script:pendingUpdate
    Get-ChildItem -LiteralPath $script:installRoot -Filter 'pending-update-*.zip' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if ($script:detailsForm -and -not $script:detailsForm.IsDisposed) { $script:detailsForm.Close() }
    $script:notify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

try {
    Start-UsageRefresh
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Dispose(); $menu.Dispose(); $script:notify.Dispose()
    if ($script:lastIcon) { $script:lastIcon.Dispose() }
    if ($script:singleInstanceMutex) {
        try { $script:singleInstanceMutex.ReleaseMutex() } catch {}
        $script:singleInstanceMutex.Dispose()
    }
}
