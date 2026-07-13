$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot '..\src\CodexUsageTray.ps1'
$temp = Join-Path $PSScriptRoot ('.tmp-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $line = '{"timestamp":"2026-07-13T00:00:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","plan_type":"test","primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1783904400},"secondary":null}}}'
    [IO.File]::WriteAllText((Join-Path $temp 'fixture.jsonl'), $line)
    $result = & $app -NoUi -SessionsPath $temp
    if (-not $result) { throw 'Expected a usage snapshot.' }
    if ($result.LimitId -ne 'codex') { throw 'Wrong limit id.' }
    if ([Math]::Abs($result.Windows[0].UsedPercent - 42.5) -gt 0.001) { throw ('Wrong percentage. Result: ' + ($result | ConvertTo-Json -Compress -Depth 6)) }
    if ($result.Windows[0].WindowMinutes -ne 300) { throw 'Wrong window.' }
    Write-Host 'PASS: parser reads the latest Codex rate-limit event.' -ForegroundColor Green
} finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
