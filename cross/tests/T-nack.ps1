# Tests de cross nack (Fase 4b): emision de NACK con razon cerrada y trazabilidad.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-nack.ps1
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
    $dir = Join-Path $env:TEMP ('cross_tnack_' + [System.Guid]::NewGuid().ToString('N'))
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

Write-Host "== T-nack: NACK 5 segmentos (modelo autoderivado de config, sin ids) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'nack ok' $r.err
Assert-True ($r.segments -eq 5) '5 segmentos (NACK:token:id:modelo:razon autoderivado)' $r.segments
Assert-True ($r.nack_text -eq "NACK:T1:${mySession}:${myModel}:CAPACITY") 'texto NACK basico con modelo de config' $r.nack_text

Write-Host "== T-nack: NACK 5 segmentos (con modelo) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.segments -eq 5) '5 segmentos (NACK:token:id:modelo:razon)' $r.segments
$p = Parse-CrossAckText $r.nack_text
Assert-True ($p.nack -and $p.razon -eq 'CAPACITY') 'parser recupera razon' "$($p.razon)"
Assert-True ($p.emisor -eq $mySession) 'parser recupera emisor' $p.emisor

Write-Host "== T-nack: msg_id sin run_id NO enriquece la trama (5 segmentos) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'TOOL_MISSING' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.segments -eq 5) '5 segmentos (msg_id solo no enriquece)' $r.segments
$p = Parse-CrossAckText $r.nack_text
Assert-True ($p.razon -eq 'TOOL_MISSING') 'razon en 5 segmentos' $p.razon

Write-Host "== T-nack: propagacion nack_msg_id/nack_run_id (7 segmentos, enriquecido) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_orig' -ForRunId 'run_orig' -Reason 'PROVIDER_DOWN' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.segments -eq 7) '7 segmentos (con msg_id y run_id)' $r.segments
$p = Parse-CrossAckText $r.nack_text
Assert-True ($p.msg_id -eq 'msg_orig' -and $p.run_id -eq 'run_orig') 'parser extrae msg_id/run_id' "$($p.msg_id)|$($p.run_id)"
Assert-True ($p.razon -eq 'PROVIDER_DOWN') 'razon propagada' $p.razon

Write-Host "== T-nack: BUG Y - enriquecido SIN --model autoderiva de config (7 segmentos) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -ForRunId 'R1' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'nack enriquecido ok' $r.err
Assert-True ($r.segments -eq 7) '7 segmentos (nunca trama ambigua de 6)' $r.segments
Assert-True ($r.nack_text -eq "NACK:T1:${mySession}:${myModel}:CAPACITY:msg_x:R1") 'modelo autoderivado en posicion 3' $r.nack_text
$p = Parse-CrossAckText $r.nack_text
Assert-True ($p.razon -eq 'CAPACITY' -and $p.msg_id -eq 'msg_x' -and $p.run_id -eq 'R1' -and $p.modelo -eq $myModel) 'parser sin ambiguedad (razon/modelo/ids correctos)' "$($p.razon)|$($p.modelo)|$($p.msg_id)|$($p.run_id)"

Write-Host "== T-nack: razones cerradas =="
foreach ($razon in @('CAPACITY', 'TOOL_MISSING', 'AMBIGUOUS_TASK', 'PROVIDER_DOWN', 'OTHER')) {
    New-Fixture
    $r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason $razon -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
    Assert-True ($r.ok -and $r.reason -eq $razon) "razon valida $razon" $r.err
}

Write-Host "== T-nack: razon no cerrada -> NACK_REASON_INVALID =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'PORQUE_NO' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'NACK_REASON_INVALID') 'razon libre rechazada' $r.err

Write-Host "== T-nack: token vacio -> USAGE_ERROR =="
New-Fixture
$r = Send-CrossNack -Token '' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'token vacio rechazado' $r.err

Write-Host "== T-nack: audit registrado con razon =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -Note 'contexto agotado' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| NACK \| ENVIADO \|') 'audit tipo NACK / ENVIADO' $audit
Assert-True ($audit -match 'nack razon=CAPACITY') 'audit con razon' $audit
Assert-True ($audit -match 'msg=msg_x') 'audit con msg_id' $audit

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
