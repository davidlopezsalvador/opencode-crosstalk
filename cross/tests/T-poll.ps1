# Cross poll tests (Phase 4a): per-message diagnosis per table 12.9.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-poll.ps1
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
    param([string]$Estado = 'EN_VUELO', [string]$MsgId = 'msg_tpoll', [string]$Dest = 'ses_X',
          [string]$Lease = '', [string]$AuditContent = '')
    $dir = Join-Path $env:TEMP ('cross_tpoll_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | $MsgId | dest=$Dest | run_id=R1 | token=T1 | lease=$Lease | ESTADO=$Estado
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:AuditFile, $AuditContent, (New-Object System.Text.UTF8Encoding($false)))
}
function Run-Poll {
    param([string]$MsgId = 'msg_tpoll', [int]$TimeoutSec = 0)
    return Get-CrossPoll -MsgId $MsgId -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile `
        -TimeoutSec $TimeoutSec -IntervalMs 100 -Port 0 -Password '' `
        -SessionFn { param($id) Fake-Session } -SleepFn { param($ms) No-Sleep }
}
$now = (Get-Date).ToUniversalTime()

Write-Host "== T-poll: NOT_FOUND =="
New-Fixture 'CONFIRMADO' 'msg_otro'
$r = Run-Poll 'msg_no_existe'
Assert-True (-not $r.ok -and $r.err -eq 'OUTBOX_MSG_NOT_FOUND') 'unknown msg -> OUTBOX_MSG_NOT_FOUND' $r.err
Assert-True ($r.diagnostic -eq 'NOT_FOUND') 'diagnostic NOT_FOUND' $r.diagnostic

Write-Host "== T-poll: ACKED (outbox CONFIRMADO) =="
New-Fixture 'CONFIRMADO'
$r = Run-Poll
Assert-True ($r.ok -and $r.diagnostic -eq 'ACKED') 'CONFIRMADO -> ACKED' $r.diagnostic
Assert-True ($r.outbox_state -eq 'CONFIRMADO') 'outbox_state CONFIRMADO' $r.outbox_state

Write-Host "== T-poll: NACKED (audit, priority over session) =="
$script:SessState = @{ session_id = 'ses_X'; status = 'busy'; growing = $true; checkable = $true; wait_ms = 0 }
$audit = "| 2026-08-12T00:00:00Z | ses_A | ses_X | TK1 | ENV | NACKED | rc=PROVIDER_DOWN msg=msg_tpoll |`n"
New-Fixture 'EN_VUELO' 'msg_tpoll' 'ses_X' ("ses_X@" + $now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ')) $audit
$r = Run-Poll
Assert-True ($r.diagnostic -eq 'NACKED') 'EN_VUELO + audit NACKED -> NACKED' $r.diagnostic
Assert-True ($r.nack_reason -eq 'PROVIDER_DOWN') 'NACK reason read' $r.nack_reason

Write-Host "== T-poll: BUG M - shared prefix msg_id does not match =="
$script:SessState = @{ session_id = 'ses_X'; status = 'busy'; growing = $true; checkable = $true; wait_ms = 0 }
$auditPre = "| 2026-08-12T00:00:00Z | ses_A | ses_X | TK1 | ENV | NACKED | rc=CAPACITY msg=msg_tpollX |`n"
New-Fixture 'EN_VUELO' 'msg_tpoll' 'ses_X' ("ses_X@" + $now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ')) $auditPre
$r = Run-Poll
Assert-True ($r.diagnostic -ne 'NACKED') 'NACK from msg_tpollX does not contaminate msg_tpoll' $r.diagnostic
Assert-True ($r.diagnostic -eq 'WORKING') 'msg_tpoll stays WORKING (busy+growing)' $r.diagnostic

Write-Host "== T-poll: WORKING (busy + growing) =="
$script:SessState = @{ session_id = 'ses_X'; status = 'busy'; growing = $true; checkable = $true; wait_ms = 0 }
New-Fixture 'EN_VUELO' 'msg_tpoll' 'ses_X' ("ses_X@" + $now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$r = Run-Poll
Assert-True ($r.diagnostic -eq 'WORKING') 'busy+growing -> WORKING' $r.diagnostic
Assert-True ($r.session_status -eq 'busy' -and $r.session_growing -eq $true) 'session status/growing propagated' "$($r.session_status)|$($r.session_growing)"

Write-Host "== T-poll: ACKED_QUIETA (busy + quiet) =="
$script:SessState = @{ session_id = 'ses_X'; status = 'busy'; growing = $false; checkable = $true; wait_ms = 0 }
New-Fixture 'EN_VUELO' 'msg_tpoll' 'ses_X' ("ses_X@" + $now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$r = Run-Poll
Assert-True ($r.diagnostic -eq 'ACKED_QUIETA') 'busy+quiet -> ACKED_QUIETA' $r.diagnostic

Write-Host "== T-poll: QUIETA_SIN_ACK (idle + quiet) =="
$script:SessState = @{ session_id = 'ses_X'; status = 'idle'; growing = $false; checkable = $true; wait_ms = 0 }
New-Fixture 'EN_VUELO' 'msg_tpoll' 'ses_X' ("ses_X@" + $now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$r = Run-Poll
Assert-True ($r.diagnostic -eq 'QUIETA_SIN_ACK') 'idle+quiet -> QUIETA_SIN_ACK' $r.diagnostic

Write-Host "== T-poll: EXPIRED (lease expired) =="
$script:SessState = @{ session_id = 'ses_X'; status = 'busy'; growing = $true; checkable = $true; wait_ms = 0 }
New-Fixture 'EN_VUELO' 'msg_tpoll' 'ses_X' ("ses_X@" + $now.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$r = Run-Poll
Assert-True ($r.diagnostic -eq 'EXPIRED') 'EN_VUELO with expired lease -> EXPIRED' $r.diagnostic
Assert-True ($r.lease_expired) 'lease_expired true' $r.lease_expired

Write-Host "== T-poll: TERMINAL (QUARANTINE) =="
New-Fixture 'QUARANTINE'
$r = Run-Poll
Assert-True ($r.diagnostic -eq 'TERMINAL') 'QUARANTINE -> TERMINAL' $r.diagnostic

Write-Host "== T-poll: loop with deadline terminates =="
$script:SessState = @{ session_id = 'ses_X'; status = 'busy'; growing = $true; checkable = $true; wait_ms = 0 }
New-Fixture 'EN_VUELO' 'msg_tpoll' 'ses_X' ("ses_X@" + $now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Run-Poll 'msg_tpoll' 1
$sw.Stop()
Assert-True ($r.ok) 'poll with deadline returns ok' $r.diagnostic
Assert-True ($sw.Elapsed.TotalSeconds -ge 1) 'timeout respected' $sw.Elapsed.TotalSeconds
Assert-True ($sw.Elapsed.TotalSeconds -lt 5) 'did not hang' $sw.Elapsed.TotalSeconds

Write-Host "== T-poll: BUG O - SleepFn respected in loop =="
$script:SessState = @{ session_id = 'ses_X'; status = 'busy'; growing = $true; checkable = $true; wait_ms = 0 }
New-Fixture 'EN_VUELO' 'msg_tpoll' 'ses_X' ("ses_X@" + $now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$script:SleepCalls = 0
$fnSleep = { param([int]$ms) $script:SleepCalls++ }
$resLoop = Get-CrossPoll -MsgId 'msg_tpoll' -OutboxPath $script:OutboxFile -AuditPath $script:AuditFile `
    -TimeoutSec 1 -IntervalMs 5000 -Port 0 -Password '' `
    -SessionFn { param($id) Fake-Session } -SleepFn $fnSleep
Assert-True ($script:SleepCalls -ge 1) 'SleepFn invoked in loop' $script:SleepCalls

Write-Host "== T-poll: Get-PollDiagnostic table (direct branches) =="
$d1 = Get-PollDiagnostic -OutboxEstado 'EXPIRADO'
Assert-True ($d1.diagnostic -eq 'TERMINAL') 'outbox EXPIRADO -> TERMINAL' $d1.diagnostic
$d2 = Get-PollDiagnostic -OutboxEstado 'TRANSFERIDO'
Assert-True ($d2.diagnostic -eq 'TERMINAL') 'outbox TRANSFERIDO -> TERMINAL' $d2.diagnostic
$d3 = Get-PollDiagnostic -OutboxEstado 'EN_VUELO' -AckDetected $true
Assert-True ($d3.diagnostic -eq 'ACKED') 'AckDetected -> ACKED' $d3.diagnostic
$d4 = Get-PollDiagnostic -OutboxEstado 'EN_VUELO' -NackDetected $true
Assert-True ($d4.diagnostic -eq 'NACKED') 'NackDetected -> NACKED' $d4.diagnostic
$d5 = Get-PollDiagnostic -OutboxEstado 'EN_VUELO' -LeaseVencido $true
Assert-True ($d5.diagnostic -eq 'EXPIRED') 'LeaseVencido -> EXPIRED' $d5.diagnostic
$d6 = Get-PollDiagnostic -OutboxEstado 'EN_VUELO'
Assert-True ($d6.diagnostic -eq 'UNKNOWN') 'null session -> UNKNOWN' $d6.diagnostic
$d7 = Get-PollDiagnostic -OutboxEstado 'EN_VUELO' -SessionState @{ status = 'error'; growing = $false; checkable = $true }
Assert-True ($d7.diagnostic -eq 'PROVIDER_DOWN') 'session error -> PROVIDER_DOWN' $d7.diagnostic
$d8 = Get-PollDiagnostic -OutboxEstado 'EN_VUELO' -SessionState @{ status = 'error'; growing = $false; checkable = $true }
Assert-True ($d8.confidence -eq 'alta') 'PROVIDER_DOWN confidence high' $d8.confidence
$d9 = Get-PollDiagnostic -OutboxEstado 'EN_VUELO' -SessionState @{ status = 'none'; growing = $true; checkable = $true }
Assert-True ($d9.diagnostic -eq 'CRECE_SIN_ACK') 'session growing with unknown status -> CRECE_SIN_ACK' $d9.diagnostic
$d10 = Get-PollDiagnostic -OutboxEstado 'EN_VUELO' -SessionState @{ status = 'none'; growing = $false; checkable = $true }
Assert-True ($d10.diagnostic -eq 'QUIETA_SIN_ACK') 'session quiet with unknown status -> QUIETA_SIN_ACK' $d10.diagnostic

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
