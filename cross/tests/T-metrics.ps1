# Tests de cross metrics (F4/F6): tolerancia a formato historico en delivery_log.
# - CONFIRMADO con ack=false/attempt=0 (formato experimental viejo) cuenta como ACK, no OTHER.
# - CONFIRMADO fire-and-forget (sin ack) tambien cuenta como ACK.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-metrics.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-diagnostic.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
$script:LogFile = ''
function New-Fixture {
    param([string]$Content)
    $dir = Join-Path $env:TEMP ('cross_tmetrics_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:LogFile = Join-Path $dir 'delivery_log.jsonl'
    [System.IO.File]::WriteAllText($script:LogFile, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "== T-metrics: CONFIRMADO con ack=false historico -> ACK, no OTHER =="
New-Fixture @'
{"ts":"2026-08-13T01:11:48Z","msg_id":"e2e_happy","dest":"ses_X","state":"CONFIRMADO","ack":false,"ack_id":"","attempt":0,"ack_latency_ms":0,"cmd":"send"}
{"ts":"2026-08-13T01:11:56Z","msg_id":"e2e_happy","dest":"ses_X","state":"CONFIRMADO","ack":false,"ack_id":"","attempt":0,"ack_latency_ms":0,"cmd":"send"}
{"ts":"2026-08-13T14:50:18Z","msg_id":"m1","dest":"ses_A","state":"CONFIRMADO","ack":true,"ack_id":"MSG-x","attempt":1,"ack_latency_ms":1200,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.ok) 'metrics ok' $r.err
Assert-True ($r.total -eq 3) 'total 3 lineas' $r.total
Assert-True ($r.by_outcome.ACK -eq 3) 'ACK=3 (incluye 2 historicas con ack=false)' ($r.by_outcome | ConvertTo-Json -Compress)
Assert-True ($r.by_outcome.OTHER -eq 0) 'OTHER=0 (ya no caen a OTHER)' $r.by_outcome.OTHER
Assert-True ($r.rates.ack -eq 100.0) 'tasa ack 100%' $r.rates.ack

Write-Host "== T-metrics: NACK por reason_code sigue contando =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"n1","dest":"ses_A","state":"NACKED","ack":false,"reason_code":"NACK_DEST_NOT_FOUND","reason":"dest no existe","attempt":1,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"n2","dest":"ses_A","state":"NACKED","ack":false,"reason_code":"NACK_TIMEOUT","reason":"sin ack","attempt":2,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.by_outcome.NACK -eq 2) 'NACK=2 por reason_code' $r.by_outcome.NACK
Assert-True ($r.top_nack.Count -eq 2) 'top_nack 2 razones' $r.top_nack.Count

Write-Host "== T-metrics: EXPIRADO + ACK_TIMEOUT -> TIMEOUT; EN_VUELO -> NO_ACK =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"t1","dest":"ses_A","state":"EXPIRADO","ack":false,"err":"ACK_TIMEOUT","attempt":2,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"t2","dest":"ses_A","state":"EN_VUELO","ack":false,"attempt":1,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.by_outcome.TIMEOUT -eq 1) 'TIMEOUT=1' $r.by_outcome.TIMEOUT
Assert-True ($r.by_outcome.NO_ACK -eq 1) 'NO_ACK=1' $r.by_outcome.NO_ACK

Write-Host "== T-metrics: lineas rotas se ignoran (no rompen metrics) =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"ok1","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
esta linea no es json
{"ts":"2026-08-13T12:00:02Z","msg_id":"ok2","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.ok) 'metrics ok con linea rota' $r.err
Assert-True ($r.total -eq 2) 'total 2 (linea rota ignorada)' $r.total

Write-Host "== T-metrics: filtro por agent y ventana since/until =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"a1","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"b1","dest":"ses_B","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
{"ts":"2026-08-13T13:00:00Z","msg_id":"a2","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile -ByAgent 'ses_A' -Since '2026-08-13T12:30:00Z'
Assert-True ($r.total -eq 1) 'filtro by-agent + since -> 1 linea' $r.total
Assert-True ($r.by_agent.ses_A -eq 1) 'by_agent.ses_A=1' ($r.by_agent | ConvertTo-Json -Compress)
$r = Get-CrossMetrics -LogPath $script:LogFile -Until '2026-08-13T12:00:30Z'
Assert-True ($r.total -eq 2) 'filtro until -> 2 lineas' $r.total
$r = Get-CrossMetrics -LogPath $script:LogFile -Since '2026-08-13T12:30:00Z' -Until '2026-08-13T12:59:59Z'
Assert-True ($r.total -eq 0) 'ventana since+until sin solape -> 0' $r.total

Write-Host "== T-metrics: dest vacio -> (sin dest) en by_agent =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"n1","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.by_agent.'(sin dest)' -eq 1) 'by_agent (sin dest)=1' ($r.by_agent | ConvertTo-Json -Compress)

Write-Host "== T-metrics: since/until invalido -> USAGE_ERROR (D1) =="
New-Fixture '{"ts":"2026-08-13T12:00:00Z","msg_id":"x","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}' 
$r = Get-CrossMetrics -LogPath $script:LogFile -Since 'ayer'
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'since invalido -> USAGE_ERROR' $r.err
$r = Get-CrossMetrics -LogPath $script:LogFile -Until 'no-es-fecha'
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'until invalido -> USAGE_ERROR' $r.err

Write-Host "== T-metrics: log inexistente -> LOG_NOT_FOUND =="
$r = Get-CrossMetrics -LogPath (Join-Path $env:TEMP 'no_existe_metrics.jsonl')
Assert-True (-not $r.ok -and $r.err -eq 'LOG_NOT_FOUND') 'log no encontrado' $r.err

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
