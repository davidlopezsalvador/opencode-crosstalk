# Contract tests (Fase 1, v1.9): envelope JSON v2 - round-trip, v1 fallback,
# body mixto, prevalencia v2, ConvertTo-CrossV1.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-contract.ps1
$ErrorActionPreference = 'Stop'
$mod = Join-Path $PSScriptRoot '..\modules\cross-envelope.psm1'
Import-Module $mod -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

Write-Host "== T-contract: round-trip v2 (message) =="
$env = New-CrossEnvelope -MsgId 'msg_lead_001' -RunId 'R1' -Token 'T1' -Text 'Simple task'
$p = Parse-CrossEnvelope -Text $env
Assert-True ($p.valid -and $p.format -eq 'v2-json') 'v2 valid + format v2-json' $env
Assert-True ($p.msg_id -eq 'msg_lead_001') 'msg_id preserved' $p.msg_id
Assert-True ($p.run_id -eq 'R1') 'run_id preserved' $p.run_id
Assert-True ($p.token -eq 'T1') 'token preserved' $p.token
Assert-True ($p.type -eq 'message') 'type message' $p.type
Assert-True ($p.requires_ack -eq $true) 'requires_ack default true' $p.requires_ack
Assert-True ($p.payload_text -eq 'Simple task') 'payload.text preserved' $p.payload_text
Assert-True ($p.timestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') 'timestamp ISO8601' $p.timestamp

Write-Host "== T-contract: round-trip v2 (fields opcionales + unicode) =="
$env2 = New-CrossEnvelope -MsgId 'msg_002' -RunId 'R2' -Token 'T2' -RequiresAck $false -Lease 'ses_A@2026-08-21T15:00:00Z' -Successor 'ses_B' -Text "Unicode: jp rus ar | pipe = equals"
$p2 = Parse-CrossEnvelope -Text $env2
Assert-True ($p2.valid) 'v2 with optional fields valid' ''
Assert-True ($p2.requires_ack -eq $false) 'requires_ack=false preserved' $p2.requires_ack
Assert-True ($p2.lease -eq 'ses_A@2026-08-21T15:00:00Z') 'lease preserved' $p2.lease
Assert-True ($p2.successor -eq 'ses_B') 'successor preserved' $p2.successor
Assert-True ($p2.payload_text -eq "Unicode: jp rus ar | pipe = equals") 'payload with pipes preserved' $p2.payload_text

Write-Host "== T-contract: round-trip ACK/NACK JSON =="
$ack = New-CrossAckJson -Token 'MSG-abc123' -MsgId 'msg_lead_001' -Emitter 'ses_B' -Model 'model-b'
$pa = Parse-CrossEnvelope -Text $ack
Assert-True ($pa.valid -and $pa.type -eq 'ack') 'ack JSON valid' $ack
Assert-True ($pa.token -eq 'MSG-abc123' -and $pa.emitter -eq 'ses_B' -and $pa.model -eq 'model-b') 'ack fields' "$($pa.token)|$($pa.emitter)|$($pa.model)"
$nack = New-CrossNackJson -Token 'MSG-abc123' -MsgId 'msg_lead_001' -Emitter 'ses_B' -Model 'model-b' -Reason 'TASK_TOO_COMPLEX' -Detail 'Cannot access external APIs'
$pn = Parse-CrossEnvelope -Text $nack
Assert-True ($pn.valid -and $pn.type -eq 'nack') 'nack JSON valid' $nack
Assert-True ($pn.token -eq 'MSG-abc123' -and $pn.reason -eq 'TASK_TOO_COMPLEX' -and $pn.detail -eq 'Cannot access external APIs') 'nack fields' "$($pn.token)|$($pn.reason)|$($pn.detail)"

Write-Host "== T-contract: Parse-CrossAckText v2 (via cross-delivery) =="
$r = Parse-CrossAckText $ack
Assert-True ($r.ack -and $r.token -eq 'MSG-abc123' -and $r.emisor -eq 'ses_B' -and $r.modelo -eq 'model-b') 'Parse-CrossAckText ack v2' "$($r.ack)|$($r.token)"
$r2 = Parse-CrossAckText $nack
Assert-True ($r2.nack -and $r2.token -eq 'MSG-abc123' -and $r2.razon -eq 'TASK_TOO_COMPLEX') 'Parse-CrossAckText nack v2' "$($r2.nack)|$($r2.razon)"

Write-Host "== T-contract: body mixto (texto + ENVELOPE-V2) =="
$mixed = "Analiza el informe y responde.`nENVELOPE-V2: $ack"
$rm = Parse-CrossAckText $mixed
Assert-True ($rm.ack -and $rm.token -eq 'MSG-abc123') 'mixed body ack detected' "$($rm.ack)|$($rm.token)"

Write-Host "== T-contract: JSON puro como respuesta completa =="
$rp = Parse-CrossAckText $ack
Assert-True ($rp.ack -and $rp.token -eq 'MSG-abc123') 'pure JSON response detected' "$($rp.ack)|$($rp.token)"

Write-Host "== T-contract: type=message NO cuenta como ack/nack =="
$rm2 = Parse-CrossAckText $env
Assert-True (-not $rm2.ack -and -not $rm2.nack -and -not $rm2.protocolo) 'type=message not ack/nack' "$($rm2.ack)|$($rm2.nack)"

Write-Host "== T-contract: fallback v1 (regresion) =="
$c1 = Parse-CrossAckText 'ACK:PROPUESTA-R1:ses_BBB:model-b'
Assert-True ($c1.ack -and $c1.token -eq 'PROPUESTA-R1' -and $c1.emisor -eq 'ses_BBB' -and $c1.modelo -eq 'model-b') 'v1 ACK 4-seg' "$($c1.token)|$($c1.emisor)"
$c2 = Parse-CrossAckText 'ACK:TOKEN:ses_CCC'
Assert-True ($c2.ack -and $c2.token -eq 'TOKEN' -and $c2.emisor -eq 'ses_CCC') 'v1 ACK 3-seg' "$($c2.token)|$($c2.emisor)"
$c3 = Parse-CrossAckText 'NACK:PROPUESTA-R1:ses_BBB:model-b:CAPACITY'
Assert-True ($c3.nack -and $c3.token -eq 'PROPUESTA-R1' -and $c3.razon -eq 'CAPACITY') 'v1 NACK 5-seg' "$($c3.token)|$($c3.razon)"
$c4 = Parse-CrossAckText 'NACK:TK:ses_A:model-b:CAPACITY:msg_123:RUN_456'
Assert-True ($c4.nack -and $c4.token -eq 'TK' -and $c4.razon -eq 'CAPACITY' -and $c4.msg_id -eq 'msg_123' -and $c4.run_id -eq 'RUN_456') 'v1 NACK enriquecido 7-seg' "$($c4.token)|$($c4.msg_id)"
$c5 = Parse-CrossAckText 'MODEL-A E2E OK. Firma: TOKEN:MSG-c9d8a9ee7451:ses_BBBB:model-a'
Assert-True ($c5.ack -and $c5.token -like 'MSG-*' -and $c5.emisor -eq 'ses_BBBB') 'v1 E1 TOKEN:MSG-' "$($c5.token)|$($c5.emisor)"
$c6 = Parse-CrossAckText 'entendido ACK-PROTOCOLO:1.6.1 ok'
Assert-True ($c6.protocolo -and $c6.token -eq '1.6.1') 'v1 ACK-PROTOCOLO' "$($c6.protocolo)|$($c6.token)"
$c7 = Parse-CrossAckText 'normal response'
Assert-True (-not $c7.ack -and -not $c7.nack -and -not $c7.protocolo) 'v1 normal response no match' "$($c7.ack)|$($c7.nack)"

Write-Host "== T-contract: ENVELOPE-V2 invalido + v1 valido -> fallback v1 =="
$bad = "ENVELOPE-V2: {not json} ACK:T1:ses_X:m1"
$rb = Parse-CrossAckText $bad
Assert-True ($rb.ack -and $rb.token -eq 'T1') 'invalid v2 falls back to v1 ACK' "$($rb.ack)|$($rb.token)"

Write-Host "== T-contract: ENVELOPE-V2 con v=1 -> fallback v1 =="
$v1env = '{"v":1,"type":"message","msg_id":"m_1","timestamp":"2026-08-21T00:00:00Z"}'
$rv1 = Parse-CrossEnvelope -Text "ENVELOPE-V2: $v1env"
Assert-True (-not $rv1.valid) 'v=1 rejected by Parse-CrossEnvelope' "$($rv1.valid)"
$rv1b = Parse-CrossAckText "ENVELOPE-V2: $v1env ACK:T2:ses_Y:m2"
Assert-True ($rv1b.ack -and $rv1b.token -eq 'T2') 'v=1 falls back to v1 ACK' "$($rv1b.ack)|$($rv1b.token)"

Write-Host "== T-contract: ENVELOPE-V2 type desconocido -> fallback v1 =="
$unkEnv = '{"v":2,"type":"weird","msg_id":"m_2","timestamp":"2026-08-21T00:00:00Z"}'
$ru = Parse-CrossEnvelope -Text "ENVELOPE-V2: $unkEnv"
Assert-True (-not $ru.valid) 'unknown type rejected' "$($ru.valid)"

Write-Host "== T-contract: ENVELOPE-V2 requires_ack no-bool -> fallback v1 =="
$badBool = '{"v":2,"type":"message","msg_id":"m_3","requires_ack":"yes","timestamp":"2026-08-21T00:00:00Z"}'
$rb2 = Parse-CrossEnvelope -Text "ENVELOPE-V2: $badBool"
Assert-True (-not $rb2.valid) 'requires_ack non-bool rejected' "$($rb2.valid)"

Write-Host "== T-contract: ENVELOPE-V2 timestamp no-ISO -> fallback v1 =="
$badTs = '{"v":2,"type":"message","msg_id":"m_4","timestamp":"ayer"}'
$rb3 = Parse-CrossEnvelope -Text "ENVELOPE-V2: $badTs"
Assert-True (-not $rb3.valid) 'timestamp non-ISO rejected' "$($rb3.valid)"

Write-Host "== T-contract: prevalencia v2 sobre v1 en el mismo texto =="
$both = "ENVELOPE-V2: $ack ACK:OTRO:ses_Z:m9"
$rb4 = Parse-CrossAckText $both
Assert-True ($rb4.ack -and $rb4.token -eq 'MSG-abc123' -and $rb4.emisor -eq 'ses_B') 'v2 wins over v1' "$($rb4.token)|$($rb4.emisor)"

Write-Host "== T-contract: ConvertTo-CrossV1 round-trip =="
$v1msg = ConvertTo-CrossV1 -ParsedEnvelope $p
Assert-True ($v1msg -match '^\[msg_id=msg_lead_001 \| run_id=R1 \| token=T1 \| requiere_ack=true') 'message v2 -> v1 envelope' $v1msg
$v1ack = ConvertTo-CrossV1 -ParsedEnvelope $pa
Assert-True ($v1ack -eq 'ACK:MSG-abc123:ses_B:model-b') 'ack v2 -> v1 ACK' $v1ack
$v1nack = ConvertTo-CrossV1 -ParsedEnvelope $pn
Assert-True ($v1nack -eq 'NACK:MSG-abc123:ses_B:model-b:TASK_TOO_COMPLEX') 'nack v2 -> v1 NACK' $v1nack

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }