$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$errorsFound = 0
Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter '*.ps1' -File | ForEach-Object {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $errorsFound++
        Write-Host "FAIL: $($_.FullName)" -ForegroundColor Red
        $parseErrors | ForEach-Object { Write-Host ("  line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    }
}
if ($errorsFound -gt 0) { throw "$errorsFound PowerShell file(s) contain syntax errors." }
Write-Host 'PASS: every PowerShell file parses successfully.' -ForegroundColor Green
