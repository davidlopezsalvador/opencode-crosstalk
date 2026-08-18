# Tests de cross quarantine (Fase 4b): DLQ flag=HUMAN_REVIEW + outbox QUARANTINE.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-quarantine.ps1
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
    $script:DlqFile = Join-Path $dir 'dlq-mensajes.md'
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

Write-Host "== T-quarantine: escribe DLQ flag=HUMAN_REVIEW =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason 'no se puede probar seguridad' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.ok) 'quarantine ok' $r.err
Assert-True ($r.dlq_written) 'dlq escrito' $r.dlq_written
$content = Get-Content -LiteralPath $script:DlqFile -Raw
Assert-True ($content -match 'flag=HUMAN_REVIEW') 'flag HUMAN_REVIEW en dlq' $content
Assert-True ($content -match "'no se puede probar seguridad'") 'razon como resumen' $content

Write-Host "== T-quarantine: marca outbox QUARANTINE =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.quarantine) 'outbox marcado QUARANTINE' $r.quarantine
$entry = @(Read-OutboxLog -Path $script:OutboxFile | Where-Object { $_.msg_id -eq 'msg_q' }) | Select-Object -First 1
Assert-True ($entry.estado -eq 'QUARANTINE') 'ESTADO=QUARANTINE persistido' $entry.estado

Write-Host "== T-quarantine: msg inexistente -> OUTBOX_MSG_NOT_FOUND =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_no_existe' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'OUTBOX_MSG_NOT_FOUND') 'msg no encontrado' $r.err

Write-Host "== T-quarantine: --check-log diagnostica por opencode.log (caso 524) =="
$now = (Get-Date).ToUniversalTime()
$qts1 = $now.AddMinutes(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
$qts2 = $now.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
$logWith524 = @"
timestamp=$qts1 level=ERROR run=r1 message="stream error" session.id=ses_X provider=openai
timestamp=$qts2 level=ERROR run=r1 message="stream error 524" session.id=ses_X
"@
New-Fixture $logWith524
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -LogPath $script:LogFile -AuditPath $script:AuditFile -CheckLog
Assert-True ($r.log_diagnostic.ok) 'diagnostico ok' $r.log_diagnostic.err
Assert-True ($r.log_diagnostic.classification -eq 'PROVIDER_DOWN') 'caso 524 -> PROVIDER_DOWN' $r.log_diagnostic.classification
$content = Get-Content -LiteralPath $script:DlqFile -Raw
Assert-True ($content -match 'log=PROVIDER_DOWN') 'clasificacion anexada al resumen' $content

Write-Host "== T-quarantine: validaciones =="
New-Fixture
$r = Set-CrossQuarantine -MsgId '' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --msg-id -> USAGE_ERROR' $r.err
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason '' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --reason -> USAGE_ERROR' $r.err

Write-Host "== T-quarantine: audit QUARANTINE =="
New-Fixture
$r = Set-CrossQuarantine -MsgId 'msg_q' -Reason 'r' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| QUARANTINE \| ESCRITO \|') 'audit tipo QUARANTINE / ESCRITO' $audit

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
