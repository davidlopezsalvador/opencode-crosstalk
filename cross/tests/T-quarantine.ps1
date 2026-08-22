# Cross quarantine tests (Phase 4b): DLQ flag=HUMAN_REVIEW + outbox QUARANTINE.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-quarantine.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    param([string]$LogContent = '')
    $dir = Join-Path $env:TEMP ('cross_tquar_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $script:DlqFile = Join-Path $dir 'dlq-messages.md'
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    $script:LogFile = Join-Path $dir 'opencode.log'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:DlqFile, "# DLQ`n", (New-Object System.Text.UTF8Encoding($false)))
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_q | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=EXPIRADO | attempt=2
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:LogFile, $LogContent, (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}

Write-Host "== T-quarantine: writes DLQ flag=HUMAN_REVIEW =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason 'cannot verify safety' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.ok) 'quarantine ok' $r.err
Assert-True ($r.dlq_written) 'dlq written' $r.dlq_written
$content = Get-Content -LiteralPath $script:DlqFile -Raw
Assert-True ($content -match 'flag=HUMAN_REVIEW') 'flag HUMAN_REVIEW in dlq' $content
Assert-True ($content -match "'cannot verify safety'") 'reason as summary' $content

Write-Host "== T-quarantine: marks outbox QUARANTINE =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.quarantine) 'outbox marked QUARANTINE' $r.quarantine
$entry = @(Read-OutboxLog -Path $script:OutboxFile | Where-Object { $_.msg_id -eq 'msg_q' }) | Select-Object -First 1
Assert-True ($entry.estado -eq 'QUARANTINE') 'ESTADO=QUARANTINE persisted' $entry.estado

Write-Host "== T-quarantine: non-existent msg -> OUTBOX_MSG_NOT_FOUND =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_no_existe' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'OUTBOX_MSG_NOT_FOUND') 'msg not found' $r.err

Write-Host "== T-quarantine: --check-log classifies via structured diagnosis (D2, case 524 equivalent) =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile -CheckLog -HealthFn { $false }
Assert-True ($r.log_diagnostic.ok) 'diagnosis ok' $r.log_diagnostic.err
Assert-True ($r.log_diagnostic.classification -eq 'PROVIDER_DOWN') 'unhealthy server -> PROVIDER_DOWN' $r.log_diagnostic.classification
$content = Get-Content -LiteralPath $script:DlqFile -Raw
Assert-True ($content -match 'log=PROVIDER_DOWN') 'classification appended to summary' $content

Write-Host "== T-quarantine: validations =="
New-Fixture
$r = Set-CrossQuarantine -MsgId '' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'no --msg-id -> USAGE_ERROR' $r.err
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason '' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'no --reason -> USAGE_ERROR' $r.err

Write-Host "== T-quarantine: audit QUARANTINE =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| QUARANTINE \| ESCRITO \|') 'audit type QUARANTINE / WRITTEN' $audit

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
