$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot '..\src\CodexUsageTray.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-usage-accounts-' + [guid]::NewGuid())
$defaultHome = Join-Path $tempRoot 'default'
$profilesRoot = Join-Path $tempRoot 'profiles'
$sessions = Join-Path $tempRoot 'empty-sessions'
$testSettingsPath = Join-Path $tempRoot 'settings\settings.json'

function ConvertTo-Base64Url {
    param([string]$Text)
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-FakeAuthFile {
    param([string]$HomePath, [string]$Name, [string]$Email, [string]$AccountId, [string]$PlanType)
    New-Item -ItemType Directory -Path $HomePath -Force | Out-Null
    $header = ConvertTo-Base64Url '{"alg":"none","typ":"JWT"}'
    $payload = ConvertTo-Base64Url ([pscustomobject]@{
        name = $Name
        email = $Email
        'https://api.openai.com/auth' = [pscustomobject]@{
            chatgpt_account_id = $AccountId
            chatgpt_plan_type = $PlanType
        }
    } | ConvertTo-Json -Depth 4 -Compress)
    [pscustomobject]@{
        auth_mode = 'chatgpt'
        tokens = [pscustomobject]@{
            id_token = "$header.$payload.signature"
            access_token = 'not-a-real-access-token'
            refresh_token = 'not-a-real-refresh-token'
            account_id = $AccountId
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $HomePath 'auth.json') -Encoding UTF8
}

New-Item -ItemType Directory -Path $tempRoot, $profilesRoot, $sessions -Force | Out-Null
try {
    New-FakeAuthFile -HomePath $defaultHome -Name 'Primary User' -Email 'primary@example.test' -AccountId 'account-primary' -PlanType 'team'
    New-FakeAuthFile -HomePath (Join-Path $profilesRoot 'duplicate') -Name 'Duplicate User' -Email 'duplicate@example.test' -AccountId 'account-primary' -PlanType 'team'
    $secondHome = Join-Path $profilesRoot 'second'
    New-FakeAuthFile -HomePath $secondHome -Name 'Second User' -Email 'second@example.test' -AccountId 'account-second' -PlanType 'pro'

    . $app -NoUi -LocalOnly -SessionsPath $sessions
    $profiles = @(Get-CodexAccountProfiles -DefaultHome $defaultHome -ProfilesRoot $profilesRoot)
    if ($profiles.Count -ne 2) { throw "Expected two unique account profiles, found $($profiles.Count)." }
    if ($profiles[0].DisplayName -ne 'Primary User' -or -not $profiles[0].IsDefault) { throw 'The default account was not listed first.' }
    if ($profiles[0].MenuLabel -ne 'primary@example.test (Business)') { throw "Unexpected Business account label: $($profiles[0].MenuLabel)" }
    if (-not ($profiles | Where-Object { $_.Email -eq 'second@example.test' -and $_.MenuLabel -eq 'second@example.test (Pro)' })) { throw 'The second account email and plan were not decoded from its local ID token.' }
    if ((Get-CodexPlanDisplayName 'free') -ne 'Free' -or (Get-CodexPlanDisplayName 'plus') -ne 'Plus') { throw 'Known plan names are not formatted correctly.' }
    Write-Host 'PASS: account profiles show email and plan, map team to Business, and deduplicate without exposing tokens.' -ForegroundColor Green

    $testSettingsPath = Join-Path $tempRoot 'settings\settings.json'
    Save-SelectedCodexHome -HomePath $secondHome -Path $testSettingsPath
    $selected = Read-SelectedCodexHome -Path $testSettingsPath
    if ($selected -ne [IO.Path]::GetFullPath($secondHome)) { throw 'The selected account profile was not persisted.' }
    $settingsText = Get-Content -Raw -LiteralPath $testSettingsPath
    if ($settingsText -match 'access_token|refresh_token|id_token|not-a-real|second@example') { throw 'Tray settings contain account credentials or identity data.' }
    Write-Host 'PASS: account selection persists only the profile path.' -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
