# Tests de cross dlq (Fase 4b): DLQ con flag cerrado + marca outbox ESTADO=DLQ.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-dlq.ps1
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
    $dir = Join-Path $env:TEMP ('cross_tdlq_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $script:DlqFile = Join-Path $dir 'dlq-mensajes.md'
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:DlqFile, "# DLQ`n", (New-Object System.Text.UTF8Encoding($false)))
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_d | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=EXPIRADO | attempt=3
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}

Write-Host "== T-dlq: linea canonica con flag cerrado =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -To 'ses_X' -Retries '3' -Flag 'HUMAN_REVIEW' -Summary 'no responde el agente' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.ok) 'dlq ok' $r.err
Assert-True ($r.written) 'escrito' $r.written
Assert-True ($r.line -match '^\[.*\] DLQ \| msg_d \| para=ses_X \| de=ses_LEADER \| reintentos=3 \| ESTADO=SIN RECOGER \| flag=HUMAN_REVIEW') 'formato canonico' $r.line
Assert-True ($r.line -match "'no responde el agente'") 'resumen entre comillas' $r.line

Write-Host "== T-dlq: persiste en dlq-mensajes.md =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -To 'ses_X' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
$content = Get-Content -LiteralPath $script:DlqFile -Raw
Assert-True ($content -match 'DLQ \| msg_d \| para=ses_X') 'DLQ en archivo' $content

Write-Host "== T-dlq: marca outbox ESTADO=DLQ =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.outbox_marked) 'outbox marcado' $r.outbox_marked
$entry = @(Read-OutboxLog -Path $script:OutboxFile | Where-Object { $_.msg_id -eq 'msg_d' }) | Select-Object -First 1
Assert-True ($entry.estado -eq 'DLQ') 'ESTADO=DLQ persistido' $entry.estado

Write-Host "== T-dlq: dest por defecto desde outbox =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.line -match 'para=ses_X') 'dest tomado del outbox' $r.line

Write-Host "== T-dlq: flag no cerrado -> DLQ_FLAG_INVALID =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag 'FLAG_LIBRE' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'DLQ_FLAG_INVALID') 'flag libre rechazado' $r.err

Write-Host "== T-dlq: flags cerrados validos =="
foreach ($f in @('HUMAN_REVIEW', 'NACK_ORIGINATED', 'QUARANTINE', 'PROVIDER_DOWN')) {
    New-Fixture
    $r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag $f -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
    Assert-True ($r.ok -and $r.line -match "flag=$f") "flag valido $f" $r.err
}

Write-Host "== T-dlq: sin msg_id -> USAGE_ERROR =="
New-Fixture
$r = Write-CrossDlq -MsgId '' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --msg-id -> USAGE_ERROR' $r.err

Write-Host "== T-dlq: reintentos autoderivado de attempt (BUG Z) =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.line -match 'reintentos=2') 'attempt=3 -> reintentos=2 (max(0,attempt-1))' $r.line
New-Fixture
$content2 = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_d | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=EXPIRADO | attempt=1
"
[System.IO.File]::WriteAllText($script:OutboxFile, $content2, (New-Object System.Text.UTF8Encoding($false)))
$r = Write-CrossDlq -MsgId 'msg_d' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.line -match 'reintentos=0') 'attempt=1 -> reintentos=0' $r.line

Write-Host "== T-dlq: audit DLQ =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| DLQ \| ESCRITO \|') 'audit tipo DLQ / ESCRITO' $audit

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
