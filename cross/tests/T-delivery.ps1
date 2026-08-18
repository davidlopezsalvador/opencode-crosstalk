# Tests del motor de entrega (Fase 3): envelope, parseo ACK/NACK, scan y New-CrossDelivery con transporte fake.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-delivery.ps1
$ErrorActionPreference = 'Stop'
$mod = Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1'
Import-Module $mod -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function No-Sleep([int]$ms) { }
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tdelivery_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    Set-FixtureContent
}
function Set-FixtureContent {
    param([string]$Estado = 'EN_VUELO', [string]$Lease = 'ses_A@2026-08-12T00:03:00Z', [string]$MsgId = 'msg_f3')
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | $MsgId | dest=ses_X | run_id=R1 | token=T1 | lease=$Lease | ESTADO=$Estado
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-OutboxLine {
    return (Get-Content -LiteralPath $script:OutboxFile | Where-Object { $_ -match 'OUTBOX' })
}

Write-Host "== T-delivery: envelope (sobre 12.1) =="
$env = Format-CrossEnvelope -MsgId 'msg_x' -RunId 'R' -Token 'TK' -Lease 'a@UTC' -Sucesor 'b' -Timestamp '2026-08-12T00:00:00Z'
Assert-True ($env -match '^\[msg_id=msg_x \|') 'envelope empieza con msg_id' $env
Assert-True ($env -match 'requiere_ack=true') 'requiere_ack=true presente' $env
Assert-True ($env -match 'sucesor=b') 'sucesor presente' $env
Assert-True ($env -match 'timestamp=2026-08-12T00:00:00Z') 'timestamp presente' $env
$env2 = Format-CrossEnvelope -MsgId 'm' -RequiereAck $false
Assert-True ($env2 -match 'requiere_ack=false') 'requiere_ack=false' $env2

Write-Host "== T-delivery: parseo ACK =="
$p = Parse-CrossAckText 'ACK:PROPUESTA-R1:ses_BBB:model-b'
Assert-True ($p.ack) 'ACK detectado' ''
Assert-True ($p.token -eq 'PROPUESTA-R1') 'token del ACK' $p.token
Assert-True ($p.emisor -eq 'ses_BBB') 'emisor del ACK' $p.emisor
Assert-True ($p.modelo -eq 'model-b') 'modelo del ACK' $p.modelo
$p2 = Parse-CrossAckText 'ACK:TOKEN:ses_CCC'
Assert-True ($p2.ack -and $p2.emisor -eq 'ses_CCC' -and -not $p2.modelo) 'ACK sin modelo tolerado' ''
$p3 = Parse-CrossAckText 'x ACK:MI-TOKEN:ses_A:m1:ses_B:m2'
Assert-True ($p3.token -eq 'MI-TOKEN:ses_A:m1' -and $p3.emisor -eq 'ses_B' -and $p3.modelo -eq 'm2') 'ACK con token con sufijo (5 segmentos)' "$($p3.token)|$($p3.emisor)|$($p3.modelo)"

Write-Host "== T-delivery: E1 - variantes reales de ACK (hallazgo E2E) =="
$e1a = Parse-CrossAckText 'MODEL-A E2E OK. Firma: TOKEN:MSG-c9d8a9ee7451:ses_BBBB:model-a'
Assert-True ($e1a.ack -and $e1a.token -eq 'MSG-c9d8a9ee7451' -and $e1a.emisor -eq 'ses_BBBB' -and $e1a.modelo -eq 'model-a') 'E1: Firma TOKEN:MSG-... con emisor/modelo' "$($e1a.token)|$($e1a.emisor)|$($e1a.modelo)"
$e1b = Parse-CrossAckText 'E2E MODEL-F: ... token MSG-1913cf464d20) ...'
Assert-True ($e1b.ack -and $e1b.token -eq 'MSG-1913cf464d20') 'E1: token MSG-... en medio del texto' "$($e1b.token)"
$e1c = Parse-CrossAckText 'TAREA-E2E:ACK:ses_BBBB:model-b'
Assert-True ($e1c.ack -and $e1c.token -eq 'ses_BBBB' -and $e1c.emisor -eq 'model-b') 'E1: :ACK: precedido de dos puntos' "$($e1c.token)|$($e1c.emisor)"
$e1d = Parse-CrossAckText 'respuesta normal sin tokens MSG'
Assert-True (-not $e1d.ack -and -not $e1d.nack) 'E1: texto normal sigue sin ser ack' ''
$e1e = Parse-CrossAckText 'Firma: TOKEN:MSG-c9d8a9ee7451:ses_A:m1'
Assert-True ($e1e.ack -and $e1e.token -eq 'MSG-c9d8a9ee7451' -and $e1e.emisor -eq 'ses_A') 'E1: TOKEN: al inicio con emisor' "$($e1e.token)|$($e1e.emisor)"

Write-Host "== T-delivery: parseo NACK =="
$n = Parse-CrossAckText 'NACK:PROPUESTA-R1:ses_BBB:model-b:CAPACITY'
Assert-True ($n.nack) 'NACK detectado' ''
Assert-True ($n.token -eq 'PROPUESTA-R1') 'token del NACK' $n.token
Assert-True ($n.razon -eq 'CAPACITY') 'razon cerrada del NACK' $n.razon
$n2 = Parse-CrossAckText 'NACK:TK:ses_A:PROVIDER_DOWN'
Assert-True ($n2.nack -and $n2.razon -eq 'PROVIDER_DOWN') 'NACK 4 segmentos -> razon ultimo' $n2.razon
$n3 = Parse-CrossAckText 'NACK:TK:ses_A:model-b:CAPACITY:msg_123:RUN_456'
Assert-True ($n3.nack -and $n3.razon -eq 'CAPACITY' -and $n3.emisor -eq 'ses_A' -and $n3.modelo -eq 'model-b' -and $n3.token -eq 'TK') 'NACK enriquecido (6 segmentos) -> razon correcta' "$($n3.token)|$($n3.emisor)|$($n3.modelo)|$($n3.razon)"
Assert-True ($n3.msg_id -eq 'msg_123' -and $n3.run_id -eq 'RUN_456') 'NACK enriquecido -> msg_id/run_id' "$($n3.msg_id)|$($n3.run_id)"
$n4 = Parse-CrossAckText 'NACK:MI-TOKEN:part:ses_A:model-b:CAPACITY'
Assert-True ($n4.nack -and $n4.token -eq 'MI-TOKEN:part' -and $n4.emisor -eq 'ses_A' -and $n4.razon -eq 'CAPACITY') 'NACK con token con sufijo (5 segmentos)' "$($n4.token)|$($n4.emisor)|$($n4.razon)"

Write-Host "== T-delivery: parseo handshake protocolo =="
$h = Parse-CrossAckText 'entendido ACK-PROTOCOLO:1.6.1 ok'
Assert-True ($h.protocolo -and $h.token -eq '1.6.1') 'ACK-PROTOCOLO:1.6.1' $h.token
$h2 = Parse-CrossAckText 'NACK-PROTOCOLO:2.0'
Assert-True ($h2.protocolo -and $h2.razon -eq 'NACK-PROTOCOLO') 'NACK-PROTOCOLO' ''

Write-Host "== T-delivery: sin ack en texto normal =="
$np = Parse-CrossAckText 'respuesta normal'
Assert-True (-not $np.ack -and -not $np.nack -and -not $np.protocolo) 'texto normal no es ack' ''

Write-Host "== T-delivery: motor -> ACK exito =="
New-Fixture
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -SendFn { param($s,$b) @{ status = 204; body = '' } } -ReadFn { param($s) @(@{ role = 'user'; text = 'ACK:T1:ses_X:m1' }) } -SleepFn { param($ms) }
Assert-True ($res.ok -and $res.state -eq 'CONFIRMADO' -and $res.ack) 'entrega con ACK -> CONFIRMADO' ($res | ConvertTo-Json -Compress)
Assert-True ((Get-OutboxLine) -match 'ESTADO=CONFIRMADO') 'outbox ESTADO=CONFIRMADO' (Get-OutboxLine)

Write-Host "== T-delivery: motor -> NACK =="
New-Fixture
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -SendFn { param($s,$b) @{ status = 204; body = '' } } -ReadFn { param($s) @(@{ role = 'user'; text = 'NACK:T1:ses_X:m1:CAPACITY' }) } -SleepFn { param($ms) }
Assert-True (-not $res.ok -and $res.err -eq 'NACK' -and $res.state -eq 'NACKED') 'NACK -> NACKED' ($res | ConvertTo-Json -Compress)
Assert-True ($res.reason -eq 'CAPACITY') 'razon NACK propagada' $res.reason
Assert-True ((Get-OutboxLine) -match 'ESTADO=NACKED') 'outbox ESTADO=NACKED' (Get-OutboxLine)

Write-Host "== T-delivery: motor -> sin ACK y destino quieto -> EXPIRADO =="
New-Fixture
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -SendFn { param($s,$b) @{ status = 204; body = '' } } -ReadFn { param($s) @() } -GrowingFn { $false } -SleepFn { param($ms) }
Assert-True (-not $res.ok -and $res.err -eq 'ACK_TIMEOUT' -and $res.state -eq 'EXPIRADO') 'sin ACK + quieto -> EXPIRADO' ($res | ConvertTo-Json -Compress)
Assert-True ((Get-OutboxLine) -match 'ESTADO=EXPIRADO') 'outbox ESTADO=EXPIRADO' (Get-OutboxLine)

Write-Host "== T-delivery: motor -> crece 1a ventana (renueva lease) y luego expira =="
New-Fixture
$calls = 0
$growingFn = { param($ms); $script:growingCalls++; return ($script:growingCalls -eq 1) }
$script:growingCalls = 0
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -SendFn { param($s,$b) @{ status = 204; body = '' } } -ReadFn { param($s) @() } -GrowingFn $growingFn -SleepFn { param($ms) }
Assert-True (-not $res.ok -and $res.err -eq 'ACK_TIMEOUT') 'crece pero nunca llega ACK -> EXPIRADO' ($res | ConvertTo-Json -Compress)
Assert-True ((Get-OutboxLine) -match 'lease=[^|]*@\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z') 'lease renovado con deadline UTC nuevo' (Get-OutboxLine)

Write-Host "== T-delivery: motor -> HTTP 404 =="
New-Fixture
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_zzz' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -SendFn { param($s,$b) @{ status = 404; body = '' } }
Assert-True (-not $res.ok -and $res.err -eq 'DEST_NOT_FOUND' -and $res.state -eq 'EXPIRADO') '404 -> DEST_NOT_FOUND' ($res | ConvertTo-Json -Compress)

Write-Host "== T-delivery: motor -> 500 y luego ACK (retry) =="
New-Fixture
$attempts = 0
$sendFn = { param($s,$b) $script:sendCalls++; if ($script:sendCalls -eq 1) { @{ status = 500; body = '' } } else { @{ status = 204; body = '' } } }
$script:sendCalls = 0
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 2 -SendFn $sendFn -ReadFn { param($s) @(@{ role = 'user'; text = 'ACK:T1:ses_X:m1' }) } -SleepFn { param($ms) }
Assert-True ($res.ok -and $res.state -eq 'CONFIRMADO') '500 -> retry -> CONFIRMADO' ($res | ConvertTo-Json -Compress)
Assert-True ($script:sendCalls -eq 2) 'se hicieron 2 intentos' $script:sendCalls

Write-Host "== T-delivery: motor -> fire-and-forget (sin requiere_ack) =="
New-Fixture
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -RequiereAck $false -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -SendFn { param($s,$b) @{ status = 204; body = '' } }
Assert-True ($res.ok -and $res.state -eq 'CONFIRMADO' -and -not $res.ack) '204 sin ack -> CONFIRMADO' ($res | ConvertTo-Json -Compress)
Assert-True ((Get-OutboxLine) -match 'ESTADO=CONFIRMADO') 'outbox ESTADO=CONFIRMADO (fire-and-forget)' (Get-OutboxLine)

Write-Host "== T-delivery: motor -> --no-wait (PENDING) =="
New-Fixture
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -NoWait -SendFn { param($s,$b) @{ status = 204; body = '' } }
Assert-True ($res.ok -and $res.state -eq 'PENDING' -and $res.no_wait -and -not $res.ack) '--no-wait -> PENDING ok' ($res | ConvertTo-Json -Compress)
Assert-True ((Get-OutboxLine) -match 'ESTADO=EN_VUELO') 'outbox sigue EN_VUELO (no-wait)' (Get-OutboxLine)

Write-Host "== T-delivery: motor -> 429 retry -> ACK =="
New-Fixture
$script:sendCalls = 0
$sendFn = { param($s,$b) $script:sendCalls++; if ($script:sendCalls -eq 1) { @{ status = 429; body = '' } } else { @{ status = 204; body = '' } } }
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 2 -SendFn $sendFn -ReadFn { param($s) @(@{ role = 'user'; text = 'ACK:T1:ses_X:m1' }) } -SleepFn { param($ms) }
Assert-True ($res.ok -and $res.state -eq 'CONFIRMADO') '429 -> retry -> CONFIRMADO' ($res | ConvertTo-Json -Compress)
Assert-True ($script:sendCalls -eq 2) '429: 2 intentos' $script:sendCalls

Write-Host "== T-delivery: motor -> timeout red (0) retry -> ACK =="
New-Fixture
$script:sendCalls = 0
$sendFn = { param($s,$b) $script:sendCalls++; if ($script:sendCalls -eq 1) { @{ status = 0; body = '' } } else { @{ status = 204; body = '' } } }
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 2 -SendFn $sendFn -ReadFn { param($s) @(@{ role = 'user'; text = 'ACK:T1:ses_X:m1' }) } -SleepFn { param($ms) }
Assert-True ($res.ok -and $res.state -eq 'CONFIRMADO') 'red timeout (0) -> retry -> CONFIRMADO' ($res | ConvertTo-Json -Compress)

Write-Host "== T-delivery: motor -> 401 AUTH_FAILED (no retry) =="
New-Fixture
$script:sendCalls = 0
$sendFn = { param($s,$b) $script:sendCalls++; @{ status = 401; body = '' } }
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 3 -SendFn $sendFn -SleepFn { param($ms) }
Assert-True (-not $res.ok -and $res.err -eq 'AUTH_FAILED' -and $res.reason_code -eq 'NACK_CONFIG_ERROR' -and $res.attempt -eq 1) '401 -> AUTH_FAILED sin retry (attempt 1)' ($res | ConvertTo-Json -Compress)

Write-Host "== T-delivery: motor -> reason_code en ACK_TIMEOUT =="
New-Fixture
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -SendFn { param($s,$b) @{ status = 204; body = '' } } -ReadFn { param($s) @() } -GrowingFn { $false } -SleepFn { param($ms) }
Assert-True ($res.reason_code -eq 'NACK_TIMEOUT') 'ACK_TIMEOUT -> reason_code NACK_TIMEOUT' $res.reason_code

Write-Host "== T-delivery: NACK enriquecido propagado =="
New-Fixture
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 1 -SendFn { param($s,$b) @{ status = 204; body = '' } } -ReadFn { param($s) @(@{ role = 'user'; text = 'NACK:T1:ses_X:m1:CAPACITY:msg_f3:R1' }) } -SleepFn { param($ms) }
Assert-True (-not $res.ok -and $res.state -eq 'NACKED' -and $res.reason -eq 'CAPACITY') 'NACK enriquecido -> NACKED CAPACITY' ($res | ConvertTo-Json -Compress)
Assert-True ($res.nack_msg_id -eq 'msg_f3' -and $res.nack_run_id -eq 'R1') 'NACK enriquecido -> msg_id/run_id en resultado' "$($res.nack_msg_id)|$($res.nack_run_id)"

Write-Host "== T-delivery: msg_id con delimitadores (BUG B) =="
$dirB = Join-Path $env:TEMP ('cross_tdelivery_b_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dirB | Out-Null
$obB = Join-Path $dirB 'outbox.md'
$contentB = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_123 | dest=ses_X | run_id=R | token=T | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | msg_1234 | dest=ses_X | run_id=R | token=T | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=EN_VUELO
"
[System.IO.File]::WriteAllText($obB, $contentB, (New-Object System.Text.UTF8Encoding($false)))
$u = Set-OutboxEstado -MsgId 'msg_1234' -Estado 'CONFIRMADO' -Path $obB
$linesB = @(Get-Content -LiteralPath $obB | Where-Object { $_ -match '^\[.*OUTBOX' })
Assert-True ($u.ok -and $linesB[1] -match 'ESTADO=CONFIRMADO' -and $linesB[0] -match 'ESTADO=EN_VUELO') 'Set-OutboxEstado msg_1234 no toca msg_123' ($linesB -join ' | ')
$rB = Renew-CrossLease -MsgId 'msg_123' -Path $obB -Minutes 3
$linesB2 = @(Get-Content -LiteralPath $obB | Where-Object { $_ -match '^\[.*OUTBOX' })
Assert-True ($rB.ok -and $linesB2[0] -match 'lease=ses_A@' -and -not ($linesB2[0] -match 'ESTADO=CONFIRMADO')) 'Renew-CrossLease msg_123 no toca msg_1234' ($linesB2 -join ' | ')

Write-Host "== T-delivery: attempt persistido en outbox (BUG L) =="
New-Fixture
$script:sendCalls = 0
$sendFn = { param($s,$b) $script:sendCalls++; if ($script:sendCalls -eq 1) { @{ status = 500; body = '' } } else { @{ status = 204; body = '' } } }
$res = New-CrossDelivery -MsgId 'msg_f3' -Dest 'ses_X' -Text 'hola' -Token 'T1' -OutboxPath $script:OutboxFile -AckTimeoutSec 1 -MaxAttempts 2 -SendFn $sendFn -ReadFn { param($s) @(@{ role = 'user'; text = 'ACK:T1:ses_X:m1' }) } -SleepFn { param($ms) }
Assert-True ($res.ok -and $res.attempt -eq 2) 'entrega con retry -> attempt 2' $res.attempt
Assert-True ((Get-OutboxLine) -match 'attempt=2') 'outbox persiste attempt=2' (Get-OutboxLine)
$att = Set-OutboxAttempt -MsgId 'msg_f3' -Attempt 3 -Path $script:OutboxFile
Assert-True ($att.ok -and ((Get-OutboxLine) -match 'attempt=3')) 'Set-OutboxAttempt -> attempt=3' (Get-OutboxLine)

Write-Host "== T-delivery: scan (Find-CrossOutboxPending) =="
$dir = Join-Path $env:TEMP ('cross_tdelivery_scan_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$ob = Join-Path $dir 'outbox.md'
$nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$future = (Get-Date).ToUniversalTime().AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
$past = (Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
$content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | m1 | dest=ses_X | run_id=R | token=T | lease=ses_A@$future | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | m2 | dest=ses_X | run_id=R | token=T | lease=ses_A@$past | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | m3 | dest=ses_X | run_id=R | token=T | lease=ses_A@$nowUtc | ESTADO=CONFIRMADO
"
[System.IO.File]::WriteAllText($ob, $content, (New-Object System.Text.UTF8Encoding($false)))
$pending = @(Find-CrossOutboxPending -Path $ob)
Assert-True ($pending.Count -eq 2) 'solo EN_VUELO (2)' $pending.Count
$m2 = $pending | Where-Object { $_.msg_id -eq 'm2' }
$m1 = $pending | Where-Object { $_.msg_id -eq 'm1' }
Assert-True ($m2.vencido) 'm2 vencido=true' ''
Assert-True (-not $m1.vencido) 'm1 vencido=false' ''
Assert-True ($m2.dest -eq 'ses_X' -and $m2.token -eq 'T') 'campos dest/token parseados' ''

Write-Host "== T-delivery: Write-CrossDeliveryLog (formato JSONL + audit) =="
$dir = Join-Path $env:TEMP ('cross_tdelivery_log_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$dl = Join-Path $dir 'delivery_log.jsonl'
$aud = Join-Path $dir 'audit_log.md'
$result = @{
    state = 'CONFIRMADO'; ok = $true; err = ''; reason_code = ''
    attempt = 2; http_status = 204; ack = $true; ack_id = 'ACK-123'
    ack_model = 'm1'; reason = ''; ack_latency_ms = 1500; session_growing = $false
}
$line = Write-CrossDeliveryLog -MsgId 'msg_log1' -Dest 'ses_X' -Token 'TK1' -Result $result -Cmd 'send' -Detail 'ack recibido' -LogPath $dl -AuditPath $aud
Assert-True ($line.ts -match '^2026-\d{2}-') 'devuelve linea con ts' $line.ts
$json = Get-Content -LiteralPath $dl -Raw | ConvertFrom-Json
Assert-True ($json.msg_id -eq 'msg_log1' -and $json.dest -eq 'ses_X' -and $json.token -eq 'TK1') 'campos msg_id/dest/token' "$($json.msg_id)|$($json.dest)|$($json.token)"
Assert-True ($json.state -eq 'CONFIRMADO' -and $json.ack -and $json.ack_id -eq 'ACK-123' -and $json.ack_latency_ms -eq 1500) 'campos result propagados' ($json | ConvertTo-Json -Compress)
$auditLine = Get-Content -LiteralPath $aud | Where-Object { $_ -match 'TK1' }
Assert-True ($auditLine -match 'CONFIRMADO' -and $auditLine -match 'ack_ms=1500') 'audit con estado+ack_ms' $auditLine
Assert-True ($auditLine -match 'ack recibido') 'nota Detail en audit' $auditLine
$r2 = Write-CrossDeliveryLog -MsgId 'msg_log2' -Dest 'ses_Y' -Token 'TK2' -Result @{ state = 'EXPIRADO'; ok = $false; err = 'ACK_TIMEOUT'; reason_code = 'NACK_TIMEOUT' } -LogPath $dl -AuditPath $aud
$auditLine2 = Get-Content -LiteralPath $aud | Where-Object { $_ -match 'TK2' }
Assert-True ($auditLine2 -match 'EXPIRADO' -and $auditLine2 -match 'rc=NACK_TIMEOUT') 'audit con estado+rc para EXPIRADO' $auditLine2
$json2 = @(Get-Content -LiteralPath $dl | ForEach-Object { $_ | ConvertFrom-Json })
Assert-True ($json2.Count -ge 2) 'delivery_log append-only (2 lineas)' $json2.Count
Assert-True ($json2[1].msg_id -eq 'msg_log2' -and $json2[1].state -eq 'EXPIRADO') '2a linea correcta' ($json2[1].msg_id)

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
