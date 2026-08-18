# Tests de cross ack (Fase 4b): emision de ACK al destino.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-ack.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tack_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }

$config = Get-Content (Join-Path $PSScriptRoot '..\cross.config.json') -Raw | ConvertFrom-Json
$mySession = [string]$config.my_session_id
$myModel = [string]$config.my_model

Write-Host "== T-ack: ACK 4 segmentos (modelo autoderivado de config) =="
New-Fixture
$r = Send-CrossAck -Token 'T1' -ForMsgId 'msg_x' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'ack ok' $r.err
Assert-True ($r.segments -eq 4) '4 segmentos (ACK:token:id:modelo autoderivado)' $r.segments
Assert-True ($r.ack_text -eq "ACK:T1:${mySession}:${myModel}") 'texto ACK con modelo de config' $r.ack_text
Assert-True ($script:Sent.dest -eq 'ses_Y') 'destino de envio' $script:Sent.dest

Write-Host "== T-ack: ACK 4 segmentos (con modelo) =="
New-Fixture
$r = Send-CrossAck -Token 'T1' -ForMsgId 'msg_x' -Dest 'ses_Y' -Model 'model-b' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.segments -eq 4) '4 segmentos (ACK:token:id:modelo)' $r.segments
Assert-True ($r.ack_text -eq "ACK:T1:${mySession}:model-b") 'modelo en ultima posicion' $r.ack_text

Write-Host "== T-ack: ACK 5 segmentos (token con sufijo + modelo) =="
New-Fixture
$r = Send-CrossAck -Token 'T1:sub' -ForMsgId 'msg_x' -Dest 'ses_Y' -Model 'model-b' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.segments -eq 5) '5 segmentos (token con ':' + modelo)' $r.segments
$p = Parse-CrossAckText $r.ack_text
Assert-True ($p.ack -and $p.token -eq 'T1:sub') 'parser recupera token completo con sufijo' "$($p.token)"
Assert-True ($p.emisor -eq $mySession) 'parser recupera emisor' $p.emisor
Assert-True ($p.modelo -eq 'model-b') 'parser recupera modelo' $p.modelo

Write-Host "== T-ack: token vacio -> USAGE_ERROR =="
New-Fixture
$r = Send-CrossAck -Token '' -ForMsgId 'msg_x' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'token vacio rechazado' $r.err

Write-Host "== T-ack: dest por defecto = mi sesion =="
New-Fixture
$r = Send-CrossAck -Token 'T1' -ForMsgId 'msg_x' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.to -eq $mySession) 'dest default my_session_id' $r.to

Write-Host "== T-ack: audit registrado =="
New-Fixture
$r = Send-CrossAck -Token 'T1' -ForMsgId 'msg_x' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match 'msg=msg_x') 'audit con msg_id' $audit
Assert-True ($audit -match '\| ACK \| ENVIADO \|') 'audit tipo ACK / ENVIADO' $audit

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
