# Tests de mutaciones directas del outbox (cross-state): Get-OutboxEntry,
# Set-OutboxEstado, Renew-CrossLease, Set-OutboxAttempt, Update-OutboxLine.
# Complementa a T-delivery (que las ejerce via el motor) con casos directos
# de frontera: OUTBOX_MSG_NOT_FOUND, outbox inexistente, attempt insertado.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-outbox-mut.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
$script:OutboxFile = ''
function New-Fixture {
    param([string]$Content)
    $dir = Join-Path $env:TEMP ('cross_tobx_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    [System.IO.File]::WriteAllText($script:OutboxFile, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
$base = @"
# OUTBOX
## Activo (formato v1.6)
[2026-08-12T00:00:00Z] OUTBOX | msg_m1 | dest=ses_A | run_id=R1 | token=T1 | lease=ses_A@2026-08-12T00:03:00Z | attempt=1 | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | msg_m2 | dest=ses_A | run_id=R2 | token=T2 | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=EN_VUELO
"@

Write-Host "== T-outbox: Get-OutboxEntry devuelve la entrada parseada =="
New-Fixture $base
$e = Get-OutboxEntry -MsgId 'msg_m1' -Path $script:OutboxFile
Assert-True ($null -ne $e -and $e.msg_id -eq 'msg_m1') 'entry encontrado' ($null -ne $e)
Assert-True ($e.dest -eq 'ses_A' -and $e.token -eq 'T1' -and $e.estado -eq 'EN_VUELO') 'campos parseados' "$($e.dest)|$($e.token)|$($e.estado)"

Write-Host "== T-outbox: Set-OutboxEstado muta solo la linea correcta =="
$r = Set-OutboxEstado -MsgId 'msg_m1' -Estado 'CONFIRMADO' -Path $script:OutboxFile
Assert-True ($r.ok) 'Set-OutboxEstado ok' ($r | ConvertTo-Json -Compress)
$e = Get-OutboxEntry -MsgId 'msg_m1' -Path $script:OutboxFile
$e2 = Get-OutboxEntry -MsgId 'msg_m2' -Path $script:OutboxFile
Assert-True ($e.estado -eq 'CONFIRMADO') 'msg_m1 -> CONFIRMADO' $e.estado
Assert-True ($e2.estado -eq 'EN_VUELO') 'msg_m2 intacto' $e2.estado

Write-Host "== T-outbox: Renew-CrossLease renueva deadline conservando owner =="
$r = Renew-CrossLease -MsgId 'msg_m1' -Path $script:OutboxFile -Minutes 5
Assert-True ($r.ok) 'Renew ok' ($r | ConvertTo-Json -Compress)
$e = Get-OutboxEntry -MsgId 'msg_m1' -Path $script:OutboxFile
$now = (Get-Date).ToUniversalTime()
Assert-True ($e.lease -match '^ses_A@(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)$') 'lease con owner ses_A + deadline UTC' $e.lease
if ($e.lease -match '@(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)') {
    $deadline = [System.DateTime]::Parse($Matches[1]).ToUniversalTime()
    $diff = ($deadline - $now).TotalMinutes
    Assert-True ($diff -ge 4.9 -and $diff -le 5.1) 'deadline ~ +5 min' $diff
}
Assert-True ($e.estado -eq 'CONFIRMADO') 'estado conservado tras renew' $e.estado

Write-Host "== T-outbox: Set-OutboxAttempt sobre linea SIN attempt inserta antes de ESTADO =="
$r = Set-OutboxAttempt -MsgId 'msg_m2' -Attempt 2 -Path $script:OutboxFile
Assert-True ($r.ok) 'Set-OutboxAttempt ok' ($r | ConvertTo-Json -Compress)
$e = Get-OutboxEntry -MsgId 'msg_m2' -Path $script:OutboxFile
Assert-True ($e.attempt -eq 2) 'attempt=2 en msg_m2' $e.attempt
Assert-True ($e.estado -eq 'EN_VUELO') 'ESTADO conservado tras insertar attempt' $e.estado

Write-Host "== T-outbox: Set-OutboxAttempt sobre linea CON attempt lo reemplaza =="
New-Fixture $base
$r = Set-OutboxAttempt -MsgId 'msg_m1' -Attempt 3 -Path $script:OutboxFile
$e = Get-OutboxEntry -MsgId 'msg_m1' -Path $script:OutboxFile
Assert-True ($e.attempt -eq 3) 'attempt 1 -> 3' $e.attempt

Write-Host "== T-outbox: msg inexistente -> OUTBOX_MSG_NOT_FOUND =="
New-Fixture $base
$r = Set-OutboxEstado -MsgId 'no_existe' -Estado 'CONFIRMADO' -Path $script:OutboxFile
Assert-True (-not $r.ok -and $r.err -eq 'OUTBOX_MSG_NOT_FOUND') 'Set estado msg inexistente' $r.err
$r = Renew-CrossLease -MsgId 'no_existe' -Path $script:OutboxFile
Assert-True (-not $r.ok -and $r.err -eq 'OUTBOX_MSG_NOT_FOUND') 'Renew msg inexistente' $r.err

Write-Host "== T-outbox: archivo inexistente -> OUTBOX_NOT_FOUND / null =="
New-Fixture $base
$missing = Join-Path (Split-Path $script:OutboxFile) 'no_existe.md'
$e = Get-OutboxEntry -MsgId 'msg_m1' -Path $missing
Assert-True ($null -eq $e) 'GetOutboxEntry archivo inexistente -> null' ($null -ne $e)
$r = Update-OutboxLine -MsgId 'msg_m1' -NewContent 'x' -Path $missing
Assert-True (-not $r.ok -and $r.err -eq 'OUTBOX_NOT_FOUND') 'Update archivo inexistente' $r.err

Write-Host "== T-outbox: BUG B - Update-OutboxLine con delimitadores (msg_m1 no toca msg_m12) =="
$base2 = @"
# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_m1 | dest=ses_A | run_id=R1 | token=T1 | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=EN_VUELO
[2026-08-12T00:00:00Z] OUTBOX | msg_m12 | dest=ses_A | run_id=R2 | token=T2 | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=EN_VUELO
"@
New-Fixture $base2
$r = Set-OutboxEstado -MsgId 'msg_m1' -Estado 'CONFIRMADO' -Path $script:OutboxFile
$e = Get-OutboxEntry -MsgId 'msg_m1' -Path $script:OutboxFile
$e12 = Get-OutboxEntry -MsgId 'msg_m12' -Path $script:OutboxFile
Assert-True ($e.estado -eq 'CONFIRMADO') 'msg_m1 -> CONFIRMADO' $e.estado
Assert-True ($e12.estado -eq 'EN_VUELO') 'msg_m12 NO tocado (BUG B)' $e12.estado

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
