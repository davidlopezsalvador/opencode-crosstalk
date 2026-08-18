# Tests de cross status (Fase 4a): resumen de outbox + idempotencia + escalated + dlq.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-status.ps1
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
function No-Sleep([int]$ms) { }
function Fake-Session { param([string]$id) return $script:SessState }
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tstatus_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    $script:StateFile = Join-Path $dir 'idempotencia-procesados.md'
    $script:EscalatedFile = Join-Path $dir 'escalated.md'
    $script:DlqFile = Join-Path $dir 'dlq-mensajes.md'
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $now = (Get-Date).ToUniversalTime()
    $leaseOk = "ses_X@" + $now.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $leaseOld = "ses_X@" + $now.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $outbox = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_st1 | dest=ses_X | run_id=R1 | token=T1 | lease=$leaseOk | ESTADO=CONFIRMADO
[2026-08-12T00:00:00Z] OUTBOX | msg_st2 | dest=ses_X | run_id=R1 | token=T2 | lease=$leaseOk | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | msg_st3 | dest=ses_X | run_id=R1 | token=T3 | lease=$leaseOld | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | msg_st4 | dest=ses_Y | run_id=R2 | token=T4 | lease=$leaseOk | ESTADO=NACKED
"
    $idem = "# IDEMPOTENCIA
## Activo
msg_st1 | 2026-08-12 00:00:00 | M | PROCESADO
msg_st2 | 2026-08-12 00:00:00 | M | PROCESADO
msg_st3 | 2026-08-12 00:00:00 | M | CLAIMED_BY=ses_owner
msg_st4 | 2026-08-12 00:00:00 | M | SUPERSEDED_BY=ses_Z
"
    $esc = "# ESCALADO
URGENTE | para=ses_lider | msg_esc1 | run_id=run_esc | de=ses_A | expira=2026-08-12T00:05:00Z | 'urgente pendiente'
URGENTE | para=ses_lider | msg_esc2 | run_id=run_esc | de=ses_A | expira=2026-08-12T00:05:00Z | 'urgente ya recibido' RECIBIDO
AVISO-SPOF | msg_id=msg_spof | para=ses_X | de=ses_A | expira=2026-08-12T00:05:00Z | 'aviso spof'
"
    $dlq = "# DLQ
[2026-08-12T00:00:00Z] DLQ | msg_d1 | para=ses_X | de=ses_A | reintentos=3 | ESTADO=SIN RECOGER | flag=HUMAN_REVIEW | 'sin recoger'
[2026-08-12T00:00:00Z] DLQ | msg_d2 | para=ses_X | de=ses_A | reintentos=2 | ESTADO=RECOGIDO | flag=TECHNICAL | 'recogido'
"
    $audit = "# audit_log.md
| timestamp | origen | destino | token | tipo | estado | nota |
|---|---|---|---|---|---|---|
| 2026-08-12 00:00:00 | ses_A | ses_X | T1 | ENV | CONFIRMADO | msg=msg_st1 |
| 2026-08-12 00:00:01 | ses_A | ses_X | T1 | ENV | NACKED | rc=CAPACITY msg=msg_st1X |
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $outbox, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:StateFile, $idem, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:EscalatedFile, $esc, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:DlqFile, $dlq, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:AuditFile, $audit, (New-Object System.Text.UTF8Encoding($false)))
}
function Run-Status {
    param([string]$MsgId = '', [string]$RunId = '', [string]$Agent = '')
    return Get-CrossStatus -MsgId $MsgId -RunId $RunId -Agent $Agent `
        -OutboxPath $script:OutboxFile -StatePath $script:StateFile `
        -EscalatedPath $script:EscalatedFile -DlqPath $script:DlqFile `
        -AuditPath $script:AuditFile `
        -Port 0 -Password '' -WaitMs 0 `
        -SessionFn { param($id) Fake-Session } -SleepFn { param($ms) No-Sleep }
}

Write-Host "== T-status: resumen global =="
New-Fixture
$script:SessState = @{ session_id = 'ses_X'; status = 'idle'; growing = $false; checkable = $true; wait_ms = 0 }
$r = Run-Status
Assert-True ($r.ok) 'status ok' ''
Assert-True ($r.outbox_by_state.CONFIRMADO -eq 1 -and $r.outbox_by_state.EN_VUELO -eq 2 -and $r.outbox_by_state.NACKED -eq 1) 'outbox_by_state cuenta' ($r.outbox_by_state | ConvertTo-Json -Compress)
$expired = @($r.expired_unmanaged)
Assert-True ($expired.Count -eq 1 -and $expired[0].msg_id -eq 'msg_st3') 'expired_unmanaged detecta lease vencido' $expired.Count

Write-Host "== T-status: idempotencia y orphaned =="
Assert-True ($r.idempotencia_by_state.PROCESADO -eq 2 -and $r.idempotencia_by_state.CLAIMED -eq 1) 'idempotencia_by_state' ($r.idempotencia_by_state | ConvertTo-Json -Compress)
$orphan = @($r.claimed_orphaned)
Assert-True ($orphan.Count -eq 1 -and $orphan[0].msg_id -eq 'msg_st3') 'claimed_orphaned lista el CLAIMED' $orphan.Count
Assert-True ($orphan[0].claimer_checked) 'claimer_checked con SessionFn' $orphan[0].claimer_checked
Assert-True ($orphan[0].claimer_status -eq 'idle') 'O2: claimer_status presente' $orphan[0].claimer_status

Write-Host "== T-status: escalated y aviso-spof =="
$escP = @($r.escalated_pending)
Assert-True ($escP.Count -eq 1 -and $escP[0].msg_id -eq 'msg_esc1') 'escalated_pending solo no recibidos' $escP.Count
Assert-True ($escP[0].recibido -eq $false) 'campo recibido false' $escP[0].recibido
$avisos = @($r.aviso_spof)
Assert-True ($avisos.Count -eq 1) 'aviso_spof lista AVISO-SPOF' $avisos.Count

Write-Host "== T-status: dlq =="
$dU = @($r.dlq_unread)
Assert-True ($dU.Count -eq 1 -and $dU[0].msg_id -eq 'msg_d1') 'dlq_unread solo SIN RECOGER' $dU.Count
Assert-True ($r.dlq_by_flag.HUMAN_REVIEW -eq 1) 'dlq_by_flag HUMAN_REVIEW' ($r.dlq_by_flag | ConvertTo-Json -Compress)
Assert-True ($r.dlq_by_flag.TECHNICAL -eq $null -and $r.dlq_by_flag.UNKNOWN -eq 1) 'BUG R: flag no cerrado -> UNKNOWN' ($r.dlq_by_flag | ConvertTo-Json -Compress)

Write-Host "== T-status: filtros por agente y msg =="
$rA = Run-Status -Agent 'ses_Y'
Assert-True ($rA.outbox_by_state.NACKED -eq 1 -and $rA.outbox_by_state.Count -eq 1) 'filtro --agent' ($rA.outbox_by_state | ConvertTo-Json -Compress)
$rM = Run-Status -MsgId 'msg_st1'
Assert-True ($rM.outbox_by_state.CONFIRMADO -eq 1 -and $rM.outbox_by_state.Count -eq 1) 'filtro --msg' ($rM.outbox_by_state | ConvertTo-Json -Compress)
$rR = Run-Status -RunId 'R2'
Assert-True ($rR.outbox_by_state.NACKED -eq 1) 'filtro --run-id' ($rR.outbox_by_state | ConvertTo-Json -Compress)

Write-Host "== T-status: lifecycle por msg =="
$rL = Run-Status -MsgId 'msg_st4'
Assert-True ($null -ne $rL.lifecycle) 'lifecycle presente' ''
Assert-True (@($rL.lifecycle.outbox).Count -eq 1 -and @($rL.lifecycle.idempotencia).Count -eq 1) 'lifecycle trae outbox+idempotencia' ''
$rL1 = Run-Status -MsgId 'msg_st1'
Assert-True (@($rL1.lifecycle.audit).Count -eq 1) 'lifecycle.audit solo la linea de msg_st1' @($rL1.lifecycle.audit).Count
Assert-True (@($rL1.lifecycle.audit) -notmatch 'msg_st1X') 'BUG M: msg_st1X no contamina lifecycle de msg_st1' (@($rL1.lifecycle.audit) -join '; ')
$rNo = Run-Status
Assert-True ($null -eq $rNo.lifecycle) 'sin --msg no hay lifecycle' ''

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
