# Tests de transporte: autodeteccion, health, cache, errores.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-transport.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$mod = Join-Path $PSScriptRoot '..\modules\cross-transport.psm1'
Import-Module $mod -Force

$pass = 0; $fail = 0
function Assert-True {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

Write-Host "== T-transport: config =="
$cfg = Import-CrossConfig
Assert-True ($null -ne $cfg) 'Import-CrossConfig devuelve objeto' ($cfg.GetType().Name)
Assert-True ($cfg.my_role -eq 'lider') 'config.my_role=lider' $cfg.my_role
Assert-True ($cfg.protocol_version.Length -gt 0) 'config.protocol_version presente'

Write-Host "== T-transport: password =="
$pw = Get-CrossPassword
if ($pw) {
    Assert-True ($pw.value.Length -gt 0) 'password obtenida' 'vacia'
    Assert-True ($pw.source -in @('env','env_file')) 'password.source valido' $pw.source
} else {
    Assert-True $false 'password obtenida' 'sin env ni .env'
}

Write-Host "== T-transport: health raw =="
$ep = Resolve-CrossEndpoint -HealthSkip
Assert-True ($ep.ok) 'Resolve-CrossEndpoint ok' ($ep.err)
if ($ep.ok) {
    Assert-True ($ep.port -gt 0) 'puerto > 0' $ep.port
    Assert-True ($ep.password_source -in @('env','env_file','override')) 'password_source valido' $ep.password_source
    $h = Test-CrossHealthRaw -Port $ep.port -Password $ep.password
    Assert-True ($h.status -eq 200) 'health HTTP 200' $h.status
    Assert-True ($h.healthy) 'health healthy=true' $h.healthy
}

Write-Host "== T-transport: override de puerto =="
$ep2 = Resolve-CrossEndpoint -Port 13537 -HealthSkip
Assert-True ($ep2.ok) 'override puerto ok' ($ep2.err)
if ($ep2.ok) {
    Assert-True ($ep2.detection_method -eq 'override') 'detection_method=override' $ep2.detection_method
}

Write-Host "== T-transport: errores =="
$epBad = Resolve-CrossEndpoint -Port 1 -Password "wrong-password-xyz"
Assert-True (-not $epBad.ok) 'puerto 1 + password invalida -> fail' ($epBad.err)
if (-not $epBad.ok) {
    Assert-True ($epBad.err -in @('UNHEALTHY','AUTH_FAILED')) 'err clasificado' $epBad.err
}

Write-Host "== T-transport: cache =="
$pwHash = Get-PasswordHash $ep.password
Write-CrossPortCache -Port $ep.port -PasswordHash $pwHash
$cached = Get-CrossPortFromCache -TtlSeconds 60 -PasswordHash $pwHash
Assert-True ($cached -eq $ep.port) 'cache escrito y leido' $cached
$badHash = Get-PasswordHash 'wrong'
$cachedBad = Get-CrossPortFromCache -TtlSeconds 60 -PasswordHash $badHash
Assert-True ($null -eq $cachedBad) 'cache con password wrong rechazada' $cachedBad

Write-Host "== T-transport: Get-CrossPortFromLog (regex main.log) =="
$logsRoot = Join-Path $env:TEMP ('cross_tlogs_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $logsRoot '2026-08-13') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $logsRoot '2026-08-12') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $logsRoot '2026-08-12\main.log'), "algo sin url`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $logsRoot '2026-08-13\main.log'), "info line`nserver ready. opencode:// opbgr. url: 'http://127.0.0.1:61234'`n", (New-Object System.Text.UTF8Encoding($false)))
$oldEnv = [Environment]::GetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR')
try {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $logsRoot)
    $port = Get-CrossPortFromLog
    Assert-True ($port -eq 61234) 'regex extrae puerto del main.log mas reciente' $port
} finally {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $oldEnv)
}
$logsEmpty = Join-Path $env:TEMP ('cross_tlogs_empty_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logsEmpty -Force | Out-Null
$oldEnv2 = [Environment]::GetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR')
try {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $logsEmpty)
    Assert-True ($null -eq (Get-CrossPortFromLog)) 'dir sin main.log -> null' (Get-CrossPortFromLog)
} finally {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $oldEnv2)
}

Write-Host "== T-transport: Get-CrossPortByScan (scan TCP + health) =="
$rango = @($ep.port, $ep.port + 1)
$scanned = Get-CrossPortByScan -ScanRange $rango
Assert-True ($scanned -eq $ep.port) 'scan encuentra el puerto real (solo el sano)' $scanned

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
