# Tests de cross restart-task (Fase 4b): reenvio con MISMO msg_id, attempt+1.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-restart-task.ps1
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
    param([string]$Estado = 'EXPIRADO', [string]$Attempt = '1', [string]$MsgId = 'msg_r')
    $dir = Join-Path $env:TEMP ('cross_trestart_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | $MsgId | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=$Estado | attempt=$Attempt
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }

Write-Host "== T-restart-task: MISMO msg_id y attempt+1 =="
New-Fixture 'EXPIRADO' '1'
$r = Restart-CrossTask -MsgId 'msg_r' -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'restart ok' $r.err
Assert-True ($r.same_msg_id -eq $true) 'mismo msg_id' $r.same_msg_id
Assert-True ($r.msg_id -eq 'msg_r') 'msg_id conservado' $r.msg_id
Assert-True ($r.attempt -eq 2) 'attempt+1' $r.attempt
$entry = @(Read-OutboxLog -Path $script:OutboxFile | Where-Object { $_.msg_id -eq 'msg_r' }) | Select-Object -First 1
Assert-True ($entry.attempt -eq 2) 'attempt persistido en outbox' $entry.attempt
Assert-True ($entry.estado -eq 'EN_VUELO') 'outbox vuelve a EN_VUELO' $entry.estado

Write-Host "== T-restart-task: reenvia al destino original =="
New-Fixture 'EXPIRADO' '1'
$r = Restart-CrossTask -MsgId 'msg_r' -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($script:Sent.dest -eq 'ses_X') 'reenvio al dest original' $script:Sent.dest

Write-Host "== T-restart-task: --to sobrescribe destino =="
New-Fixture 'EXPIRADO' '1'
$r = Restart-CrossTask -MsgId 'msg_r' -To 'ses_Z' -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.dest -eq 'ses_Z') 'dest sobrescrito' $r.dest
Assert-True ($script:Sent.dest -eq 'ses_Z') 'envio al dest nuevo' $script:Sent.dest

Write-Host "== T-restart-task: msg inexistente -> OUTBOX_MSG_NOT_FOUND =="
New-Fixture 'EXPIRADO' '1'
$r = Restart-CrossTask -MsgId 'msg_no_existe' -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'OUTBOX_MSG_NOT_FOUND') 'msg no encontrado' $r.err

Write-Host "== T-restart-task: attempt en max -> MAX_RETRIES_EXCEEDED =="
New-Fixture 'EXPIRADO' '2'
$r = Restart-CrossTask -MsgId 'msg_r' -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'MAX_RETRIES_EXCEEDED') 'max reintentos excedido' $r.err
Assert-True ($r.attempt -eq 2) 'attempt reportado' $r.attempt

Write-Host "== T-restart-task: --max-attempts personalizado (BUG CC) =="
New-Fixture 'EXPIRADO' '4'
$r = Restart-CrossTask -MsgId 'msg_r' -MaxAttempts 5 -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'restart con max-attempts ok' $r.err
Assert-True ($r.attempt -eq 5) 'attempt+1 dentro del max personalizado' $r.attempt
New-Fixture 'EXPIRADO' '5'
$r = Restart-CrossTask -MsgId 'msg_r' -MaxAttempts 5 -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'MAX_RETRIES_EXCEEDED') 'max-attempts personalizado respetado' $r.err

Write-Host "== T-restart-task: audit RESTART =="
New-Fixture 'EXPIRADO' '1'
$r = Restart-CrossTask -MsgId 'msg_r' -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| RESTART \| EN_VUELO \|') 'audit tipo RESTART / EN_VUELO' $audit
Assert-True ($audit -match 'mismo msg_id') 'audit nota mismo msg_id' $audit

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
