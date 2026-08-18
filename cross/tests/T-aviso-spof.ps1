# Tests de cross aviso-spof (Fase 4a): deteccion de EN_VUELO vencidos y aviso.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-aviso-spof.ps1
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

Write-Host "== T-aviso-spof: dry-run por defecto =="
New-Fixture
$script:SessState = @{ session_id = 'ses_me'; status = 'idle'; growing = $false; checkable = $true; wait_ms = 0 }
$script:NotifyFn = { param($dest, $mid) $script:NotifyCalls++; return $null }
$script:NotifyCalls = 0
$r = Run-Aviso
Assert-True ($r.ok -and $r.dry_run) 'dry_run por defecto' $r.dry_run
Assert-True ($r.vencidos -eq 2) 'cuenta los vencidos' $r.vencidos
$res = @($r.results)
Assert-True ($res.Count -eq 2) 'resultados para los 2 vencidos' $res.Count
$mine = @($res | Where-Object { $_.msg_id -eq 'msg_spof1' })
$other = @($res | Where-Object { $_.msg_id -eq 'msg_spof2' })
Assert-True ($mine[0].action -eq 'aviso-spof') 'vencido de mi sesion quieta -> aviso-spof' $mine[0].action
Assert-True ($other[0].action -eq 'notify-lider') 'vencido de otra sesion -> notify-lider' $other[0].action
Assert-True (@($r.written).Count -eq 0 -and @($r.notified).Count -eq 0) 'dry-run no escribe ni notifica' ''
Assert-True ($script:NotifyCalls -eq 0) 'NotifyFn no llamado en dry-run' $script:NotifyCalls

Write-Host "== T-aviso-spof: --apply escribe AVISO-SPOF y notifica =="
New-Fixture
$script:SessState = @{ session_id = 'ses_me'; status = 'idle'; growing = $false; checkable = $true; wait_ms = 0 }
$script:NotifyFn = { param($dest, $mid) $script:NotifyCalls++; return $null }
$script:NotifyCalls = 0
$r = Run-Aviso -Apply
Assert-True (-not $r.dry_run) 'con --apply deja de ser dry-run' $r.dry_run
Assert-True (@($r.written).Count -eq 1 -and $r.written -contains 'msg_spof1') 'escribe solo el de mi sesion quieta' ($r.written -join ',')
Assert-True (@($r.notified).Count -eq 1 -and $r.notified -contains 'msg_spof2') 'notifica solo el de la otra sesion' ($r.notified -join ',')
Assert-True ($script:NotifyCalls -eq 1) 'NotifyFn llamado una vez' $script:NotifyCalls
$esc = Get-Content -LiteralPath $script:EscalatedFile -Raw
Assert-True ($esc -match 'AVISO-SPOF.*msg_spof1') 'AVISO-SPOF anexado a escalated.md' $esc

Write-Host "== T-aviso-spof: mi sesion creciendo no avisa =="
New-Fixture
$script:SessState = @{ session_id = 'ses_me'; status = 'busy'; growing = $true; checkable = $true; wait_ms = 0 }
$script:NotifyFn = { param($dest, $mid) $script:NotifyCalls++; return $null }
$script:NotifyCalls = 0
$r = Run-Aviso -Apply
$mine = @($r.results | Where-Object { $_.msg_id -eq 'msg_spof1' })
Assert-True ($mine[0].action -eq 'creciendo') 'mi sesion crece -> esperar, no aviso' $mine[0].action
Assert-True (@($r.written).Count -eq 0) 'no escribe aviso si mi sesion crece' ($r.written -join ',')
Assert-True (@($r.notified).Count -eq 1) 'aun asi avisa de la otra sesion' ($r.notified -join ',')

Write-Host "== T-aviso-spof: BUG Q - config expone lider_session_id =="
$cfg = Get-CrossConfig
Assert-True ([bool]$cfg.lider_session_id) 'lider_session_id definido en config' $cfg.lider_session_id
Assert-True ($cfg.lider_session_id -eq $cfg.my_session_id) 'lider = mi sesion (soy el lider)' $cfg.lider_session_id
$avisoResult = Get-CrossAvisoSpof -OutboxPath $script:OutboxFile -EscalatedPath $script:EscalatedFile `
    -MySessionId '' -Apply -Port 0 -Password '' -WaitMs 0 `
    -SessionFn { param($id) Fake-Session } -NotifyFn { param($d,$m) $null } -SleepFn { param($ms) No-Sleep }
Assert-True ($avisoResult.ok) 'BUG Q: funcion resuelve sesion destino sin MySessionId (usa config)' $avisoResult.dry_run

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
