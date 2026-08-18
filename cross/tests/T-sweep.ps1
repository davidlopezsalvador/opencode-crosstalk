# Auto-sweep of expired tests (F2): Invoke-CrossAutoSweep marks EXPIRADO the expired EN_VUELO.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-sweep.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
$dir = Join-Path $env:TEMP ('cross_tsweep_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$Outbox = Join-Path $dir 'outbox.md'
$Audit = Join-Path $dir 'audit_log.md'
$past = (Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
$future = (Get-Date).ToUniversalTime().AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ')

function Set-OutboxLines {
    param([string[]]$Lines)
    $content = "# OUTBOX`n## Activo`n"
    foreach ($l in $Lines) { $content += $l + "`n" }
    [System.IO.File]::WriteAllText($Outbox, $content, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "== T-sweep: marks EXPIRADO only the expired =="
Set-OutboxLines @(
    "[2026-08-12T00:00:00Z] OUTBOX | msg_s1 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$past | ESTADO=EN_VUELO",
    "[2026-08-12T00:00:00Z] OUTBOX | msg_s2 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$future | ESTADO=EN_VUELO",
    "[2026-08-12T00:00:00Z] OUTBOX | msg_s3 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$past | ESTADO=EN_VUELO"
)
$r = Invoke-CrossAutoSweep -Path $Outbox -AuditPath $Audit -Apply
Assert-True ($r.ok -and @($r.swept).Count -eq 2) 'sweeps 2 expired' ($r | ConvertTo-Json -Compress)
$lines = @(Get-Content -LiteralPath $Outbox)
$s1 = $lines | Where-Object { $_ -match 'msg_s1' }
$s2 = $lines | Where-Object { $_ -match 'msg_s2' }
$s3 = $lines | Where-Object { $_ -match 'msg_s3' }
Assert-True ($s1 -match 'ESTADO=EXPIRADO') 'msg_s1 expired -> EXPIRADO' $s1
Assert-True ($s2 -match 'ESTADO=EN_VUELO') 'msg_s2 valid untouched' $s2
Assert-True ($s3 -match 'ESTADO=EXPIRADO') 'msg_s3 expired -> EXPIRADO' $s3
Assert-True ((Test-Path -LiteralPath $Audit) -and @(Get-Content -LiteralPath $Audit).Count -eq 2) 'audit records 2 SCAN EXPIRADO' $Audit

Write-Host "== T-sweep: ExcludeMsgId respects the current in-flight msg =="
Set-OutboxLines @(
    "[2026-08-12T00:00:00Z] OUTBOX | msg_s4 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$past | ESTADO=EN_VUELO",
    "[2026-08-12T00:00:00Z] OUTBOX | msg_s5 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$past | ESTADO=EN_VUELO"
)
$r = Invoke-CrossAutoSweep -Path $Outbox -AuditPath $Audit -ExcludeMsgId 'msg_s4' -Apply
Assert-True (@($r.swept).Count -eq 1 -and $r.swept[0] -eq 'msg_s5') 'excludes msg_s4, sweeps msg_s5' ($r | ConvertTo-Json -Compress)
$lines = @(Get-Content -LiteralPath $Outbox)
Assert-True (($lines | Where-Object { $_ -match 'msg_s4' }) -match 'ESTADO=EN_VUELO') 'msg_s4 untouched (excluded)' ''
Assert-True (($lines | Where-Object { $_ -match 'msg_s5' }) -match 'ESTADO=EXPIRADO') 'msg_s5 -> EXPIRADO' ''

Write-Host "== T-sweep: no expired does not mutate =="
Set-OutboxLines @(
    "[2026-08-12T00:00:00Z] OUTBOX | msg_s6 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$future | ESTADO=EN_VUELO"
)
$before = (Get-Content -LiteralPath $Outbox -Raw)
$r = Invoke-CrossAutoSweep -Path $Outbox -AuditPath $Audit -Apply
$after = (Get-Content -LiteralPath $Outbox -Raw)
Assert-True ($r.ok -and @($r.swept).Count -eq 0 -and $before -eq $after) 'no expired does not touch' ($r | ConvertTo-Json -Compress)

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
