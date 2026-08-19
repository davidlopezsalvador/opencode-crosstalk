# Transport tests: auto-detection, health, cache, errors.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-transport.ps1
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
Assert-True ($null -ne $cfg) 'Import-CrossConfig returns object' ($cfg.GetType().Name)
Assert-True ($cfg.my_role -eq 'leader') 'config.my_role=leader' $cfg.my_role
Assert-True ($cfg.protocol_version.Length -gt 0) 'config.protocol_version present'

Write-Host "== T-transport: password =="
$pw = Get-CrossPassword
if ($pw) {
    Assert-True ($pw.value.Length -gt 0) 'password obtained' 'empty'
    Assert-True ($pw.source -in @('env','env_file')) 'password.source valid' $pw.source
} else {
    Assert-True $false 'password obtained' 'no env nor .env'
}

Write-Host "== T-transport: health raw =="
$ep = Resolve-CrossEndpoint -HealthSkip
Assert-True ($ep.ok) 'Resolve-CrossEndpoint ok' ($ep.err)
if ($ep.ok) {
    Assert-True ($ep.port -gt 0) 'port > 0' $ep.port
    Assert-True ($ep.password_source -in @('env','env_file','override')) 'password_source valid' $ep.password_source
    $h = Test-CrossHealthRaw -Port $ep.port -Password $ep.password
    Assert-True ($h.status -eq 200) 'health HTTP 200' $h.status
    Assert-True ($h.healthy) 'health healthy=true' $h.healthy
}

Write-Host "== T-transport: port override =="
$ep2 = Resolve-CrossEndpoint -Port 13537 -HealthSkip
Assert-True ($ep2.ok) 'port override ok' ($ep2.err)
if ($ep2.ok) {
    Assert-True ($ep2.detection_method -eq 'override') 'detection_method=override' $ep2.detection_method
}

Write-Host "== T-transport: errors =="
$epBad = Resolve-CrossEndpoint -Port 1 -Password "wrong-password-xyz"
Assert-True (-not $epBad.ok) 'port 1 + invalid password -> fail' ($epBad.err)
if (-not $epBad.ok) {
    Assert-True ($epBad.err -in @('UNHEALTHY','AUTH_FAILED')) 'err classified' $epBad.err
}

Write-Host "== T-transport: cache =="
$pwHash = Get-PasswordHash $ep.password
Write-CrossPortCache -Port $ep.port -PasswordHash $pwHash
$cached = Get-CrossPortFromCache -TtlSeconds 60 -PasswordHash $pwHash
Assert-True ($cached -eq $ep.port) 'cache written and read' $cached
$badHash = Get-PasswordHash 'wrong'
$cachedBad = Get-CrossPortFromCache -TtlSeconds 60 -PasswordHash $badHash
Assert-True ($null -eq $cachedBad) 'cache with wrong password rejected' $cachedBad

Write-Host "== T-transport: Get-CrossPortFromLog (main.log regex) =="
$logsRoot = Join-Path $env:TEMP ('cross_tlogs_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $logsRoot '2026-08-13') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $logsRoot '2026-08-12') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $logsRoot '2026-08-12\main.log'), "something without url`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $logsRoot '2026-08-13\main.log'), "info line`nserver ready. opencode:// opbgr. url: 'http://127.0.0.1:61234'`n", (New-Object System.Text.UTF8Encoding($false)))
(Get-Item (Join-Path $logsRoot '2026-08-13')).LastWriteTime = (Get-Date)
(Get-Item (Join-Path $logsRoot '2026-08-12')).LastWriteTime = (Get-Date).AddDays(-1)
$oldEnv = [Environment]::GetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR')
try {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $logsRoot)
    $port = Get-CrossPortFromLog
    Assert-True ($port -eq 61234) 'regex extracts port from most recent main.log' $port
} finally {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $oldEnv)
}
$logsEmpty = Join-Path $env:TEMP ('cross_tlogs_empty_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logsEmpty -Force | Out-Null
$oldEnv2 = [Environment]::GetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR')
try {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $logsEmpty)
    Assert-True ($null -eq (Get-CrossPortFromLog)) 'dir without main.log -> null' (Get-CrossPortFromLog)
} finally {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $oldEnv2)
}

Write-Host "== T-transport: Get-CrossPortByScan (TCP scan + health) =="
$rango = @($ep.port, $ep.port + 1)
$scanned = Get-CrossPortByScan -ScanRange $rango
Assert-True ($scanned -eq $ep.port) 'scan finds the real port (only the healthy one)' $scanned

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
