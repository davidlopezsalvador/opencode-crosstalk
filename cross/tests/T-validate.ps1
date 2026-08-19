# Cross validate tests (Phase 2, lint for outbox vs idempotency consistency).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-validate.ps1
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '..\cross.ps1'

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
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
function New-Fixture {
    param([string]$IdemContent, [string]$OutboxContent)
    $dir = Join-Path $env:TEMP ('cross_tvalidate_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:StateFile = Join-Path $dir 'idempotencia-procesados.md'
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    [System.IO.File]::WriteAllText($script:StateFile, $IdemContent, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:OutboxFile, $OutboxContent, (New-Object System.Text.UTF8Encoding($false)))
}
function Run-Validate {
    return Get-Json (Invoke-CrossCli @('validate', '--state-file', $script:StateFile, '--outbox-file', $script:OutboxFile))
}

$goodIdem = "# IDEMPOTENCIA
## Activo
msg_tval_ok | 2026-08-12 00:00:00 | M | PROCESADO
"
$goodOutbox = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_tval_ok | dest=ses_X | run_id=R | token=T | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=CONFIRMADO
"

Write-Host "== T-validate: consistent =="
New-Fixture $goodIdem $goodOutbox
$r = Run-Validate
Assert-True ($r.ok -and $r.code -eq 0) 'validate ok on good fixture' $r.err
Assert-True ($r.error_count -eq 0 -and $r.warning_count -eq 0) 'no errors or warnings' "$($r.warnings -join '; ')"

Write-Host "== T-validate: PROCESADO without CONFIRMADO = error =="
$badOutbox = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_tval_ok | dest=ses_X | run_id=R | token=T | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=EN_VUELO
"
New-Fixture $goodIdem $badOutbox
$r = Run-Validate
Assert-True (-not $r.ok -and $r.code -eq 2) 'error -> code 2' $r.code
Assert-True ($r.error_count -ge 1) 'error_count>=1' $r.error_count
Assert-True ($r.errors -match 'PROCESADO sin CONFIRMADO') 'error msg PROCESADO without CONFIRMADO' ($r.errors -join '; ')

Write-Host "== T-validate: lease without UTC + duplicate msg = warnings =="
$warnOutbox = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_tval_ok | dest=ses_X | run_id=R | token=T | lease=ses_A@UTC+3min | ESTADO=CONFIRMADO
[2026-08-12T00:01:00Z] OUTBOX | msg_tval_ok | dest=ses_X | run_id=R | token=T | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=CONFIRMADO
"
New-Fixture $goodIdem $warnOutbox
$r = Run-Validate
Assert-True ($r.ok -and $r.error_count -eq 0) 'warnings do not break ok' $r.err
Assert-True ($r.warnings -match 'lease sin deadline UTC') 'warn lease without UTC' ($r.warnings -join '; ')
Assert-True ($r.warnings -match 'msg_id duplicado') 'warn duplicate msg_id' ($r.warnings -join '; ')

Write-Host "== T-validate: v1.6 line in Activo = warning =="
$badIdem = "# IDEMPOTENCIA
## Activo
msg_tval_v16 | 2026-08-11 20:00:00
msg_tval_ok | 2026-08-12 00:00:00 | M | PROCESADO
"
New-Fixture $badIdem $goodOutbox
$r = Run-Validate
Assert-True ($r.ok -and $r.error_count -eq 0) 'ok with warning' $r.err
Assert-True ($r.warnings -match 'line not v1.6.1') 'warn non-v1.6.1 line' ($r.warnings -join '; ')

Write-Host "== T-validate (F7): historical mixed format outside Activo generates no errors =="
$f7Idem = "# IDEMPOTENCIA
## Activo
msg_tval_ok | 2026-08-12 00:00:00 | M | PROCESADO
"
$f7Outbox = "# OUTBOX
## Activo (formato v1.6)
[2026-08-12T00:00:00Z] OUTBOX | msg_tval_ok | dest=ses_X | run_id=R | token=T | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=CONFIRMADO

## Historico (formato anterior a v1.6; conservado intacto, no parsear como v1.6)
[2026-08-11T19:00:00Z] OUTBOX | msg_reco_T9-20260811-200000-reco09 | dest=ses_X | run_id=TEST-RECUPERACION-T9 | token=RECO-T9-a1b2c3d4 | lease=ses_A@2026-08-11T20:05:00Z EXPIRADO|sucesor=ses_B | ESTADO=CONFIRMADO
[2026-08-11T16:11:22Z] OUTBOX | msg_lease_TESTD-20260811-181622-3a55bd | dest=ses_C | run_id=TEST-ANTISUENO-TD | token=TD-af897f04 | lease=ses_C@UTC+3min EXPIRADO|sucesor=ses_D | ESTADO=TRANSFERIDO
| msg_wake_WUP-6d563f8a | MODEL-C | CONFIRMADO | stress | 2026-08-11 |
"
New-Fixture $f7Idem $f7Outbox
$r = Run-Validate
Assert-True ($r.ok -and $r.code -eq 0) 'ok with historicals in Historico' $r.err
Assert-True ($r.error_count -eq 0 -and $r.warning_count -eq 0) 'no errors or warnings (historicals ignored)' "$($r.errors -join '; ') | $($r.warnings -join '; ')"

Write-Host "== T-validate: malformed outbox line = warning =="
$malOutbox = "# OUTBOX
## Activo
line without pipe not v1.6
[2026-08-12T00:00:00Z] OUTBOX | msg_tval_ok | dest=ses_X | run_id=R | token=T | lease=ses_A@2026-08-12T00:03:00Z | ESTADO=CONFIRMADO
"
New-Fixture $goodIdem $malOutbox
$r = Run-Validate
Assert-True ($r.ok -and $r.error_count -eq 0) 'ok with malformed outbox' $r.err
Assert-True ($r.warnings -match 'outbox line not v1.6') 'warn malformed outbox' ($r.warnings -join '; ')

Write-Host "== T-validate: non-v1.6.1 state in idempotencia Activo = warning =="
$badStateIdem = "# IDEMPOTENCIA
## Activo
msg_tval_x | 2026-08-12 00:00:00 | M | ENVIADO
msg_tval_ok | 2026-08-12 00:00:00 | M | PROCESADO
"
New-Fixture $badStateIdem $goodOutbox
$r = Run-Validate
Assert-True ($r.ok -and $r.error_count -eq 0) 'ok with non-v1.6.1 state' $r.err
Assert-True ($r.warnings -match 'state not v1.6.1') 'warn non-v1.6.1 state' ($r.warnings -join '; ')

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
