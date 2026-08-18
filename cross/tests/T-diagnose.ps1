# Tests de cross diagnose (Fase 4b): clasificacion por log del servidor (caso 524).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-diagnose.ps1
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
$script:OutboxFile = ''
$script:LogFile = ''
function New-Fixture {
    param([string]$LogContent = '')
    $dir = Join-Path $env:TEMP ('cross_tdiag_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    $script:LogFile = Join-Path $dir 'opencode.log'
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_diag | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=EN_VUELO | attempt=1
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:LogFile, $LogContent, (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$now = (Get-Date).ToUniversalTime()
$ts1 = $now.AddMinutes(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
$ts2 = $now.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-Host "== T-diagnose: dest tomado del outbox =="
New-Fixture "timestamp=$ts1 level=INFO run=r1 message=foo session.id=ses_X`n"
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 10
Assert-True ($r.ok) 'diagnose ok' $r.err
Assert-True ($r.dest -eq 'ses_X') 'dest del outbox' $r.dest

Write-Host "== T-diagnose: caso 524 -> PROVIDER_DOWN =="
New-Fixture "timestamp=$ts1 level=ERROR run=r1 message=`"stream error 524`" session.id=ses_X`n"
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 10
Assert-True ($r.classification -eq 'PROVIDER_DOWN') '524 -> PROVIDER_DOWN' $r.classification
Assert-True ($r.action -match 'renovar lease') 'accion renovar lease' $r.action

Write-Host "== T-diagnose: ENOTFOUND / connect timeout / Rate limit -> PROVIDER_DOWN =="
foreach ($pat in @('connect timeout', 'ENOTFOUND', 'Rate limit exceeded', 'stream error 504')) {
    New-Fixture "timestamp=$ts1 level=ERROR run=r1 message=`"$pat`" session.id=ses_X`n"
    $r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 10
    Assert-True ($r.classification -eq 'PROVIDER_DOWN') "patron $pat -> PROVIDER_DOWN" $r.classification
}

Write-Host "== T-diagnose: exiting loop -> AGENT_SLEEPING =="
New-Fixture "timestamp=$ts1 level=INFO run=r1 message=`"exiting loop`" session.id=ses_X`n"
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 10
Assert-True ($r.classification -eq 'AGENT_SLEEPING') 'exiting loop -> AGENT_SLEEPING' $r.classification
Assert-True ($r.action -match 'escalada') 'accion escalada normal' $r.action

Write-Host "== T-diagnose: stream error distinto -> CONFIG_ERROR =="
New-Fixture "timestamp=$ts1 level=ERROR run=r1 message=`"stream error: model not found`" session.id=ses_X`n"
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 10
Assert-True ($r.classification -eq 'CONFIG_ERROR') 'stream error otro -> CONFIG_ERROR' $r.classification
Assert-True ($r.action -match 'DLQ') 'accion reportar en DLQ' $r.action

Write-Host "== T-diagnose: provider error sin codigo 5xx (model-d) -> PROVIDER_DOWN =="
foreach ($pat in @('AI_APICallError: Upstream request failed: Endpoint is unavailable', 'stream error', 'Upstream request failed: Endpoint is unavailable')) {
    New-Fixture "timestamp=$ts1 level=ERROR run=r1 message=`"$pat`" session.id=ses_X`n"
    $r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 10
    Assert-True ($r.classification -eq 'PROVIDER_DOWN') "provider sin 5xx ($pat) -> PROVIDER_DOWN" $r.classification
    Assert-True ($r.action -match 'renovar lease') 'accion renovar lease' $r.action
}

Write-Host "== T-diagnose: auth/modelo -> CONFIG_ERROR (no provider) =="
foreach ($pat in @('401', '403', 'invalid api key', 'unauthorized', 'model not found', 'invalid model', 'authentication failed')) {
    New-Fixture "timestamp=$ts1 level=ERROR run=r1 message=`"$pat`" session.id=ses_X`n"
    $r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 10
    Assert-True ($r.classification -eq 'CONFIG_ERROR') "auth/modelo ($pat) -> CONFIG_ERROR" $r.classification
}

Write-Host "== T-diagnose: sin lineas -> NO_DATA =="
New-Fixture "timestamp=$ts1 level=INFO run=r1 message=foo session.id=otra_sesion`n"
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 10
Assert-True ($r.classification -eq 'NO_DATA') 'sin lineas del destino -> NO_DATA' $r.classification

Write-Host "== T-diagnose: ventana de minutos respetada =="
New-Fixture "timestamp=$ts1 level=ERROR run=r1 message=`"stream error 524`" session.id=ses_X`n"
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath $script:LogFile -Minutes 1
Assert-True ($r.matched_count -eq 0) 'linea mas antigua que la ventana ignorada' $r.matched_count

Write-Host "== T-diagnose: log inexistente -> LOG_NOT_FOUND =="
New-Fixture
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -LogPath (Join-Path $env:TEMP 'no_existe.log') -Minutes 10
Assert-True (-not $r.ok -and $r.err -eq 'LOG_NOT_FOUND') 'log no encontrado' $r.err

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
