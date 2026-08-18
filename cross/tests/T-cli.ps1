# Tests end-to-end de la CLI cross.ps1 (Fase 1).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-cli.ps1
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '..\cross.ps1'

$pass = 0; $fail = 0
function Assert-True {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
$config = Get-Content (Join-Path $PSScriptRoot '..\cross.config.json') -Raw | ConvertFrom-Json
$crossRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$mySession = $config.my_session_id
function Invoke-CrossCli {
    param([string[]]$CliArgs)
    $tmp = Join-Path $env:TEMP ("cross_cli_" + [System.Guid]::NewGuid().ToString('N') + ".json")
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli @CliArgs 2>$null | Out-File -LiteralPath $tmp -Encoding ascii
    $raw = Get-Content -LiteralPath $tmp -Raw
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    return $raw
}
function Get-Json {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    try { return ($Raw | ConvertFrom-Json) } catch { return $null }
}

Write-Host "== T-cli: health =="
$r = Get-Json (Invoke-CrossCli @('health'))
Assert-True ($null -ne $r) 'health emite JSON' 'null'
Assert-True ($r.ok -eq $true) 'health ok=true' $r.ok
Assert-True ($r.healthy -eq $true) 'health healthy=true' $r.healthy
Assert-True ($r.port -gt 0) 'health port>0' $r.port

Write-Host "== T-cli: whoami =="
$r = Get-Json (Invoke-CrossCli @('whoami'))
Assert-True ($r.ok -eq $true) 'whoami ok' $r.ok
Assert-True ($r.session_id.Length -gt 0) 'whoami session_id' $r.session_id
Assert-True ($r.model.Length -gt 0) 'whoami model' $r.model

Write-Host "== T-cli: sessions =="
$r = Get-Json (Invoke-CrossCli @('sessions'))
Assert-True ($r.ok -eq $true) 'sessions ok' $r.ok
Assert-True ($r.count -ge 1) 'sessions count>=1' $r.count
Assert-True ($r.sessions.Count -eq $r.count) 'sessions array coincide' $r.sessions.Count

Write-Host "== T-cli: sessions --directory =="
$r = Get-Json (Invoke-CrossCli @('sessions', '--directory', $crossRoot))
Assert-True ($r.ok -eq $true) 'sessions --directory ok' $r.ok
Assert-True ($r.count -ge 1) 'sessions dir count>=1' $r.count
Assert-True (@($r.sessions | Where-Object { $_.directory -match 'CROSS' }).Count -eq $r.count) 'todas con dir CROSS' ''

Write-Host "== T-cli: read =="
$r = Get-Json (Invoke-CrossCli @('read', '--session', $mySession, '--limit', '2'))
Assert-True ($r.ok -eq $true) 'read ok' $r.ok
Assert-True ($r.count -ge 1) 'read count>=1' $r.count
Assert-True (@($r.messages).Count -eq $r.count) 'read messages coincide' ''
Assert-True (@($r.messages | Where-Object { $_.id -match '^msg_' }).Count -eq $r.count) 'ids msg_' ''

Write-Host "== T-cli: read --role=user =="
$r = Get-Json (Invoke-CrossCli @('read', "--session=$mySession", '--role=user', '--limit=2'))
Assert-True ($r.ok -eq $true) 'read --role ok' $r.ok
Assert-True (@($r.messages | Where-Object { $_.role -ne 'user' }).Count -eq 0) 'todos role=user' ''

Write-Host "== T-cli: errores =="
$r = Get-Json (Invoke-CrossCli @('badcmd'))
Assert-True ($r.code -eq 64 -and -not $r.ok) 'subcomando desconocido -> 64' $r.err
$r = Get-Json (Invoke-CrossCli @('read'))
Assert-True ($r.code -eq 64) 'read sin --session -> 64' $r.err

Write-Host "== T-cli: salidas humanas =="
$out = Invoke-CrossCli @('health', '--human')
Assert-True ($out -match 'cross health -> OK') 'health --human texto' $out
$out = Invoke-CrossCli @('sessions', '--human')
Assert-True ($out -match 'sesion') 'sessions --human lista' $out

Write-Host "== T-cli: config --set tipos y validacion =="
$r = Get-Json (Invoke-CrossCli @('config', '--set=port_cache_ttl_s=45'))
Assert-True ($r.ok -eq $true) 'config --set int ok' $r.ok
$r = Get-Json (Invoke-CrossCli @('config', '--get=port_cache_ttl_s'))
Assert-True ($r.value.GetType().Name -notin @('String','string')) 'config set conserva int (no string)' $r.value
$null = Invoke-CrossCli @('config', '--set=port_cache_ttl_s=60')
$r = Get-Json (Invoke-CrossCli @('config', '--set=my_session_id=abc'))
Assert-True (-not $r.ok -and $r.code -eq 64) 'config set valida ses_ -> 64' $r.detail

Write-Host "== T-cli: read 404 =="
$r = Get-Json (Invoke-CrossCli @('read', '--session=ses_no_existe_xyz', '--limit=1'))
Assert-True (-not $r.ok -and $r.err -eq 'NOT_FOUND') 'read sesion inexistente NOT_FOUND' $r.err

Write-Host "== T-cli: read --role case-insensitive =="
$r = Get-Json (Invoke-CrossCli @('read', "--session=$mySession", '--role=USER', '--limit=2'))
Assert-True ($r.ok -eq $true) 'read --role=USER ok' $r.ok
Assert-True (@($r.messages | Where-Object { $_.role.ToLower() -ne 'user' }).Count -eq 0) 'todos role=user (case-insens)' ''

Write-Host "== T-cli: poll/status/reconcile/aviso-spof wiring =="
$dir = Join-Path $env:TEMP ('cross_tcli4a_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$ob = Join-Path $dir 'outbox.md'
[System.IO.File]::WriteAllText($ob, "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_w1 | dest=ses_X | run_id=R | token=TK1 | lease=ses_X@2026-08-12T00:05:00Z | ESTADO=CONFIRMADO
", (New-Object System.Text.UTF8Encoding($false)))

$r = Get-Json (Invoke-CrossCli @('poll'))
Assert-True (-not $r.ok -and $r.code -eq 64 -and $r.err -eq 'USAGE_ERROR') 'poll sin --msg -> USAGE_ERROR' $r.err
$r = Get-Json (Invoke-CrossCli @('poll', "--msg=msg_w1", '--outbox-file', $ob))
Assert-True ($r.ok -and $r.diagnostic -eq 'ACKED') 'poll CONFIRMADO -> ACKED' $r.diagnostic
$r = Get-Json (Invoke-CrossCli @('poll', "--msg-id=msg_w1", '--outbox-file', $ob))
Assert-True ($r.ok -and $r.diagnostic -eq 'ACKED') 'poll acepta --msg-id' $r.diagnostic

$r = Get-Json (Invoke-CrossCli @('status', '--outbox-file', $ob))
Assert-True ($r.ok -and $r.outbox_by_state.CONFIRMADO -eq 1) 'status con outbox ok' ($r | ConvertTo-Json -Compress)

$r = Get-Json (Invoke-CrossCli @('reconcile', "--msg=msg_w1"))
Assert-True (-not $r.ok -and $r.code -eq 64) 'reconcile sin --check-file -> 64' $r.detail
$cf = Join-Path $dir 'check.md'
[System.IO.File]::WriteAllText($cf, "lista`ncon TK1 aqui", (New-Object System.Text.UTF8Encoding($false)))
$r = Get-Json (Invoke-CrossCli @('reconcile', "--msg=msg_w1", '--check-file', $cf, '--outbox-file', $ob))
Assert-True ($r.ok -and $r.verdict -eq 'CONFIRMED') 'reconcile CONFIRMED' $r.verdict

$r = Get-Json (Invoke-CrossCli @('aviso-spof', '--outbox-file', $ob, '--for', 'ses_X'))
Assert-True ($r.ok -and $r.dry_run) 'aviso-spof dry_run por defecto' ($r | ConvertTo-Json -Compress)

Write-Host "== T-cli: metrics con --log-path y --since invalido =="
$metricsDir = Join-Path $env:TEMP ('cross_tcli_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $metricsDir | Out-Null
$mlog = Join-Path $metricsDir 'delivery_log.jsonl'
[System.IO.File]::WriteAllText($mlog, @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"m1","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"m2","dest":"ses_A","state":"NACKED","ack":false,"reason_code":"NACK_TIMEOUT","attempt":1,"cmd":"send"}
{"ts":"2026-08-13T13:00:00Z","msg_id":"m3","dest":"ses_A","state":"CONFIRMADO","ack":false,"attempt":0,"cmd":"send"}
'@, (New-Object System.Text.UTF8Encoding($false)))
$r = Get-Json (Invoke-CrossCli @('metrics', '--log-path', $mlog))
Assert-True ($r.ok -and $r.code -eq 0) 'metrics CLI ok' $r.err
Assert-True ($r.total -eq 3) 'metrics CLI total=3' $r.total
Assert-True ($r.by_outcome.ACK -eq 2 -and $r.by_outcome.NACK -eq 1) 'ACK=2 NACK=1 (formato historico cuenta ACK)' ($r.by_outcome | ConvertTo-Json -Compress)
$r = Get-Json (Invoke-CrossCli @('metrics', '--log-path', $mlog, '--since', 'ayer'))
Assert-True (-not $r.ok -and $r.code -eq 64 -and $r.err -eq 'USAGE_ERROR') 'metrics --since invalido -> code 64 USAGE_ERROR' $r.err
$r = Get-Json (Invoke-CrossCli @('metrics', '--log-path', (Join-Path $env:TEMP 'no_existe_metrics.jsonl')))
Assert-True (-not $r.ok -and $r.code -eq 64 -and $r.err -eq 'LOG_NOT_FOUND') 'metrics log inexistente -> LOG_NOT_FOUND' $r.err

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
