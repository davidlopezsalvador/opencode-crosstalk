# Cross nudge tests (Phase 4b): firm prompt anti-'Continue'.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-nudge.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tnudge_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }

Write-Host "== T-nudge: firm prompt with token =="
New-Fixture
$r = Send-CrossNudge -To 'ses_X' -Task 'deliver report msg_1' -Token 'T1' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'nudge ok' $r.err
Assert-True ($r.prompt -match 'IGNORA|ignora') 'firm prompt' $r.prompt
Assert-True ($r.prompt -match "Continue") 'mentions Continue' $r.prompt
Assert-True ($r.prompt -match 'deliver report msg_1') 'task present' $r.prompt
Assert-True ($r.prompt -match 'token: T1') 'token present' $r.prompt
Assert-True ($script:Sent.dest -eq 'ses_X') 'send destination' $script:Sent.dest

Write-Host "== T-nudge: without token does not include token =="
New-Fixture
$r = Send-CrossNudge -To 'ses_X' -Task 'task' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.prompt -notmatch 'token:') 'without token omitted' $r.prompt

Write-Host "== T-nudge: validations =="
New-Fixture
$r = Send-CrossNudge -To '' -Task 'task' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'no --to -> USAGE_ERROR' $r.err
$r = Send-CrossNudge -To 'ses_X' -Task '' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'no --task -> USAGE_ERROR' $r.err

Write-Host "== T-nudge: audit NUDGE =="
New-Fixture
$r = Send-CrossNudge -To 'ses_X' -Task 'task' -Token 'T1' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| NUDGE \| ENVIADO \|') 'audit type NUDGE / SENT' $audit

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
