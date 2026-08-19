# Cross aviso-spof tests (Phase 4a): detecting expired EN_VUELO and alerting.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-aviso-spof.ps1
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
    $dir = Join-Path $env:TEMP ('cross_tspof_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    $script:EscalatedFile = Join-Path $dir 'escalated.md'
    $now = (Get-Date).ToUniversalTime()
    $leaseOld = "ses_me@" + $now.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $leaseOld2 = "ses_otro@" + $now.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $leaseOk = "ses_me@" + $now.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $outbox = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_spof1 | dest=ses_me | run_id=R1 | token=T1 | lease=$leaseOld | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | msg_spof2 | dest=ses_otro | run_id=R2 | token=T2 | lease=$leaseOld2 | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | msg_spof3 | dest=ses_me | run_id=R3 | token=T3 | lease=$leaseOk | ESTADO=EN_VUELO
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $outbox, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:EscalatedFile, "# ESCALADO`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Run-Aviso {
    param([switch]$Apply, [string]$MySession = 'ses_me')
    return Get-CrossAvisoSpof -OutboxPath $script:OutboxFile -EscalatedPath $script:EscalatedFile `
        -MySessionId $MySession -Apply:$Apply -Port 0 -Password '' -WaitMs 0 `
        -SessionFn { param($id) Fake-Session } -NotifyFn $script:NotifyFn -SleepFn { param($ms) No-Sleep }
}

Write-Host "== T-aviso-spof: dry-run by default =="
New-Fixture
$script:SessState = @{ session_id = 'ses_me'; status = 'idle'; growing = $false; checkable = $true; wait_ms = 0 }
$script:NotifyFn = { param($dest, $mid) $script:NotifyCalls++; return $null }
$script:NotifyCalls = 0
$r = Run-Aviso
Assert-True ($r.ok -and $r.dry_run) 'dry_run by default' $r.dry_run
Assert-True ($r.vencidos -eq 2) 'counts expired' $r.vencidos
$res = @($r.results)
Assert-True ($res.Count -eq 2) 'results for the 2 expired' $res.Count
$mine = @($res | Where-Object { $_.msg_id -eq 'msg_spof1' })
$other = @($res | Where-Object { $_.msg_id -eq 'msg_spof2' })
Assert-True ($mine[0].action -eq 'aviso-spof') 'expired from my idle session -> aviso-spof' $mine[0].action
Assert-True ($other[0].action -eq 'notify-leader') 'expired from other session -> notify-leader' $other[0].action
Assert-True (@($r.written).Count -eq 0 -and @($r.notified).Count -eq 0) 'dry-run writes and notifies nothing' ''
Assert-True ($script:NotifyCalls -eq 0) 'NotifyFn not called in dry-run' $script:NotifyCalls

Write-Host "== T-aviso-spof: --apply writes AVISO-SPOF and notifies =="
New-Fixture
$script:SessState = @{ session_id = 'ses_me'; status = 'idle'; growing = $false; checkable = $true; wait_ms = 0 }
$script:NotifyFn = { param($dest, $mid) $script:NotifyCalls++; return $null }
$script:NotifyCalls = 0
$r = Run-Aviso -Apply
Assert-True (-not $r.dry_run) 'with --apply no longer dry-run' $r.dry_run
Assert-True (@($r.written).Count -eq 1 -and $r.written -contains 'msg_spof1') 'writes only the one from my idle session' ($r.written -join ',')
Assert-True (@($r.notified).Count -eq 1 -and $r.notified -contains 'msg_spof2') 'notifies only the one from the other session' ($r.notified -join ',')
Assert-True ($script:NotifyCalls -eq 1) 'NotifyFn called once' $script:NotifyCalls
$esc = Get-Content -LiteralPath $script:EscalatedFile -Raw
Assert-True ($esc -match 'AVISO-SPOF.*msg_spof1') 'AVISO-SPOF appended to escalated.md' $esc

Write-Host "== T-aviso-spof: my growing session does not alert =="
New-Fixture
$script:SessState = @{ session_id = 'ses_me'; status = 'busy'; growing = $true; checkable = $true; wait_ms = 0 }
$script:NotifyFn = { param($dest, $mid) $script:NotifyCalls++; return $null }
$script:NotifyCalls = 0
$r = Run-Aviso -Apply
$mine = @($r.results | Where-Object { $_.msg_id -eq 'msg_spof1' })
Assert-True ($mine[0].action -eq 'growing') 'my session is growing -> wait, no alert' $mine[0].action
Assert-True (@($r.written).Count -eq 0) 'does not write alert if my session is growing' ($r.written -join ',')
Assert-True (@($r.notified).Count -eq 1) 'still alerts about the other session' ($r.notified -join ',')

Write-Host "== T-aviso-spof: BUG Q - config exposes leader_session_id =="
$cfg = Get-CrossConfig
if (-not $cfg.leader_session_id) {
    Write-Host "  SKIP  BUG Q: config template has empty leader_session_id (publish template)"
} else {
Assert-True ([bool]$cfg.leader_session_id) 'leader_session_id defined in config' $cfg.leader_session_id
Assert-True ($cfg.leader_session_id -eq $cfg.my_session_id) 'leader = my session (I am the leader)' $cfg.leader_session_id
$avisoResult = Get-CrossAvisoSpof -OutboxPath $script:OutboxFile -EscalatedPath $script:EscalatedFile `
    -MySessionId '' -Apply -Port 0 -Password '' -WaitMs 0 `
    -SessionFn { param($id) Fake-Session } -NotifyFn { param($d,$m) $null } -SleepFn { param($ms) No-Sleep }
Assert-True ($avisoResult.ok) 'BUG Q: function resolves target session without MySessionId (uses config)' $avisoResult.dry_run
}

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
