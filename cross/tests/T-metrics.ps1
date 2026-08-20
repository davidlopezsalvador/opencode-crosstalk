# Cross metrics tests (F4/F6): historical format tolerance in delivery_log.
# - CONFIRMADO with ack=false/attempt=0 (old experimental format) counts as ACK, not OTHER.
# - CONFIRMADO fire-and-forget (no ack) also counts as ACK.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-metrics.ps1
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

Write-Host "== T-metrics: CONFIRMADO with historical ack=false -> ACK, not OTHER =="
New-Fixture @'
{"ts":"2026-08-13T01:11:48Z","msg_id":"e2e_happy","dest":"ses_X","state":"CONFIRMADO","ack":false,"ack_id":"","attempt":0,"ack_latency_ms":0,"cmd":"send"}
{"ts":"2026-08-13T01:11:56Z","msg_id":"e2e_happy","dest":"ses_X","state":"CONFIRMADO","ack":false,"ack_id":"","attempt":0,"ack_latency_ms":0,"cmd":"send"}
{"ts":"2026-08-13T14:50:18Z","msg_id":"m1","dest":"ses_A","state":"CONFIRMADO","ack":true,"ack_id":"MSG-x","attempt":1,"ack_latency_ms":1200,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.ok) 'metrics ok' $r.err
Assert-True ($r.total -eq 3) 'total 3 lines' $r.total
Assert-True ($r.by_outcome.ACK -eq 3) 'ACK=3 (includes 2 historical with ack=false)' ($r.by_outcome | ConvertTo-Json -Compress)
Assert-True ($r.by_outcome.OTHER -eq 0) 'OTHER=0 (no longer falls to OTHER)' $r.by_outcome.OTHER
Assert-True ($r.rates.ack -eq 100.0) 'ack rate 100%' $r.rates.ack

Write-Host "== T-metrics: NACK by reason_code still counts =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"n1","dest":"ses_A","state":"NACKED","ack":false,"reason_code":"NACK_DEST_NOT_FOUND","reason":"dest does not exist","attempt":1,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"n2","dest":"ses_A","state":"NACKED","ack":false,"reason_code":"NACK_TIMEOUT","reason":"no ack","attempt":2,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.by_outcome.NACK -eq 2) 'NACK=2 by reason_code' $r.by_outcome.NACK
Assert-True ($r.top_nack.Count -eq 2) 'top_nack 2 reasons' $r.top_nack.Count

Write-Host "== T-metrics: EXPIRADO + ACK_TIMEOUT -> TIMEOUT; EN_VUELO -> NO_ACK =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"t1","dest":"ses_A","state":"EXPIRADO","ack":false,"err":"ACK_TIMEOUT","attempt":2,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"t2","dest":"ses_A","state":"EN_VUELO","ack":false,"attempt":1,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.by_outcome.TIMEOUT -eq 1) 'TIMEOUT=1' $r.by_outcome.TIMEOUT
Assert-True ($r.by_outcome.NO_ACK -eq 1) 'NO_ACK=1' $r.by_outcome.NO_ACK

Write-Host "== T-metrics: broken lines are ignored (do not break metrics) =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"ok1","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
this line is not json
{"ts":"2026-08-13T12:00:02Z","msg_id":"ok2","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.ok) 'metrics ok with broken line' $r.err
Assert-True ($r.total -eq 2) 'total 2 (broken line ignored)' $r.total

Write-Host "== T-metrics: agent filter and since/until window =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"a1","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"b1","dest":"ses_B","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
{"ts":"2026-08-13T13:00:00Z","msg_id":"a2","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile -ByAgent 'ses_A' -Since '2026-08-13T12:30:00Z'
Assert-True ($r.total -eq 1) 'filter by-agent + since -> 1 line' $r.total
Assert-True ($r.by_agent.ses_A -eq 1) 'by_agent.ses_A=1' ($r.by_agent | ConvertTo-Json -Compress)
$r = Get-CrossMetrics -LogPath $script:LogFile -Until '2026-08-13T12:00:30Z'
Assert-True ($r.total -eq 2) 'filter until -> 2 lines' $r.total
$r = Get-CrossMetrics -LogPath $script:LogFile -Since '2026-08-13T12:30:00Z' -Until '2026-08-13T12:59:59Z'
Assert-True ($r.total -eq 0) 'since+until window with no overlap -> 0' $r.total

Write-Host "== T-metrics: empty dest -> (no dest) in by_agent =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"n1","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
'@
$r = Get-CrossMetrics -LogPath $script:LogFile
Assert-True ($r.by_agent.'(sin dest)' -eq 1) 'by_agent (no dest)=1' ($r.by_agent | ConvertTo-Json -Compress)

Write-Host "== T-metrics: invalid since/until -> USAGE_ERROR (D1) =="
New-Fixture '{"ts":"2026-08-13T12:00:00Z","msg_id":"x","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}' 
$r = Get-CrossMetrics -LogPath $script:LogFile -Since 'ayer'
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'invalid since -> USAGE_ERROR' $r.err
$r = Get-CrossMetrics -LogPath $script:LogFile -Until 'no-es-fecha'
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'invalid until -> USAGE_ERROR' $r.err

Write-Host "== T-metrics: non-existent log -> LOG_NOT_FOUND =="
$r = Get-CrossMetrics -LogPath (Join-Path $env:TEMP 'no_existe_metrics.jsonl')
Assert-True (-not $r.ok -and $r.err -eq 'LOG_NOT_FOUND') 'log not found' $r.err

Write-Host "== T-metrics: Export-CrossMetrics Prometheus text (v1.14) =="
New-Fixture @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"ok1","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"ack_latency_ms":500,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"ok2","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"ack_latency_ms":1000,"cmd":"send"}
{"ts":"2026-08-13T12:00:02Z","msg_id":"ok3","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"ack_latency_ms":1500,"cmd":"send"}
{"ts":"2026-08-13T12:00:03Z","msg_id":"nk1","dest":"ses_A","state":"NACKED","ack":false,"reason_code":"NACK_CAPACITY","attempt":1,"cmd":"send"}
{"ts":"2026-08-13T12:00:04Z","msg_id":"t1","dest":"ses_A","state":"EXPIRADO","ack":false,"err":"ACK_TIMEOUT","attempt":2,"cmd":"send"}
{"ts":"2026-08-13T12:00:05Z","msg_id":"pv","dest":"ses_A","state":"EN_VUELO","ack":false,"attempt":1,"cmd":"send"}
{"ts":"2026-08-13T12:00:06Z","msg_id":"q1","dest":"ses_A","state":"DLQ","ack":false,"attempt":4,"cmd":"dlq"}
{"ts":"2026-08-13T12:00:07Z","msg_id":"q2","dest":"ses_A","state":"QUARANTINE","ack":false,"attempt":3,"cmd":"quarantine"}
'@
$e = Export-CrossMetrics -LogPath $script:LogFile -OutboxPath (Join-Path $env:TEMP 'outbox_no_existe.md')
Assert-True ($e.ok) 'export ok' $e.err
Assert-True ($e.text -match '(?m)^# TYPE cross_messages_total counter$') 'TYPE cross_messages_total' $e.text
Assert-True ($e.text -match '(?m)^cross_messages_total 8$') 'cross_messages_total 8' $e.text
Assert-True ($e.text -match '(?m)^cross_messages_acked_total 3$') 'acked_total 3' $e.text
Assert-True ($e.text -match '(?m)^cross_messages_nacked_total 1$') 'nacked_total 1' $e.text
Assert-True ($e.text -match '(?m)^cross_messages_timeout_total 1$') 'timeout_total 1' $e.text
Assert-True ($e.text -match '(?m)^cross_messages_noack_total 1$') 'noack_total 1' $e.text
Assert-True ($e.text -match '(?m)^cross_messages_error_total 0$') 'error_total 0' $e.text
Assert-True ($e.text -match '(?m)^cross_delivery_latency_ms\{quantile="0\.5"\} 1000$') 'latency P50 quantile (repo Floor index)' $e.text
Assert-True ($e.text -match '(?m)^cross_delivery_latency_ms\{quantile="0\.95"\} 1500$') 'latency P95 quantile' $e.text
Assert-True ($e.text -match '(?m)^cross_outbox_pending 0$') 'outbox_pending gauge 0 (no outbox file)' $e.text
Assert-True ($e.text -match '(?m)^cross_messages_dlq 1$') 'dlq gauge 1' $e.text
Assert-True ($e.text -match '(?m)^cross_messages_quarantine 1$') 'quarantine gauge 1' $e.text
Assert-True ($e.text -match '(?m)^# HELP cross_messages_total Total messages tracked in delivery_log\.jsonl') 'HELP documents delivery_log scope' $e.text
$eOut = Export-CrossMetrics -LogPath $script:LogFile -OutputPath (Join-Path $env:TEMP ('cross_metrics_' + [System.Guid]::NewGuid().ToString('N') + '.prom'))
Assert-True ($eOut.ok -and (Test-Path -LiteralPath $eOut.output)) 'output file written' $eOut.output
Assert-True (-not $eOut.PSObject.Properties['text']) 'no text when output file used' 'text present'
$eErr = Export-CrossMetrics -LogPath (Join-Path $env:TEMP 'no_existe_prom.jsonl')
Assert-True (-not $eErr.ok -and $eErr.err -eq 'LOG_NOT_FOUND') 'export LOG_NOT_FOUND' $eErr.err
$eErr2 = Export-CrossMetrics -LogPath $script:LogFile -Since 'ayer'
Assert-True (-not $eErr2.ok -and $eErr2.err -eq 'USAGE_ERROR') 'export USAGE_ERROR' $eErr2.err

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
