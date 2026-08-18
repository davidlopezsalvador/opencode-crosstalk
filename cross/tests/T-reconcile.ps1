# Cross reconcile tests (Phase 4a): verify that a deliverable reached its destination.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-reconcile.ps1
$ErrorActionPreference = 'Stop'
$mod = Join-Path $PSScriptRoot '..\modules\cross-diagnostic.psm1'
Import-Module $mod -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    param([string]$CheckContent = '', [bool]$CreateCheck = $true, [string]$Token = 'abc123', [string]$MsgId = 'msg_trecon')
    $dir = Join-Path $env:TEMP ('cross_trecon_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    $script:CheckFile = Join-Path $dir 'check.md'
    $outbox = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | $MsgId | dest=ses_X | run_id=R1 | token=$Token | lease=ses_X@2026-08-12T00:05:00Z | ESTADO=EN_VUELO
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $outbox, (New-Object System.Text.UTF8Encoding($false)))
    if ($CreateCheck) {
        [System.IO.File]::WriteAllText($script:CheckFile, $CheckContent, (New-Object System.Text.UTF8Encoding($false)))
    }
}
function Run-Reconcile {
    param([string]$MsgId = 'msg_trecon', [string]$ExpectedToken = '', [string]$CheckFile = '')
    if (-not $CheckFile) { $CheckFile = $script:CheckFile }
    return Get-CrossReconcile -MsgId $MsgId -CheckFile $CheckFile -ExpectedToken $ExpectedToken -OutboxPath $script:OutboxFile
}

Write-Host "== T-reconcile: CONFIRMED =="
New-Fixture "any line`nDelivered with token abc123 and ready"
$r = Run-Reconcile
Assert-True ($r.ok -and $r.verdict -eq 'CONFIRMED') 'outbox token found -> CONFIRMED' $r.verdict
Assert-True ($r.expected_token -eq 'abc123') 'token read from outbox' $r.expected_token
Assert-True ($r.file.line_found -eq 2) 'line where token appears' $r.file.line_found
Assert-True ($r.recommendation -eq 'mark_confirmed') 'recommendation mark_confirmed' $r.recommendation

Write-Host "== T-reconcile: AMBIGUOUS =="
New-Fixture "line without the expected token`nother line"
$r = Run-Reconcile
Assert-True ($r.verdict -eq 'AMBIGUOUS') 'check exists but without token -> AMBIGUOUS' $r.verdict
Assert-True ($r.recommendation -eq 'investigate') 'recommendation investigate' $r.recommendation

Write-Host "== T-reconcile: NOT_FOUND (check does not exist) =="
New-Fixture 'x' $false
$r = Run-Reconcile
Assert-True ($r.verdict -eq 'NOT_FOUND') 'non-existent check -> NOT_FOUND' $r.verdict
Assert-True (-not $r.file.exists) 'file.exists false' $r.file.exists

Write-Host "== T-reconcile: empty file -> AMBIGUOUS/retry =="
New-Fixture ''
$r = Run-Reconcile
Assert-True ($r.verdict -eq 'AMBIGUOUS') 'empty check -> AMBIGUOUS' $r.verdict
Assert-True ($r.recommendation -eq 'retry') 'empty check -> retry (not written)' $r.recommendation

Write-Host "== T-reconcile: expected-token override =="
New-Fixture "text with token XYZ999" $true 'abc123'
$r = Run-Reconcile -ExpectedToken 'XYZ999'
Assert-True ($r.verdict -eq 'CONFIRMED') 'token override -> CONFIRMED' $r.verdict
Assert-True ($r.expected_token -eq 'XYZ999') 'expected_token is the override' $r.expected_token

Write-Host "== T-reconcile: outbox without msg =="
New-Fixture 'abc123' $true 'abc123' 'msg_otro'
$r = Run-Reconcile 'msg_no_existe'
Assert-True ($r.ok -and $r.expected_token -eq '') 'no outbox entry, expected_token empty' $r.expected_token
Assert-True ($r.verdict -eq 'AMBIGUOUS') 'no token to search, cannot confirm' $r.verdict

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
