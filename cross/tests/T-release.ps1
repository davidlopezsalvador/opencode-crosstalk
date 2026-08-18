# Tests de cross release (Fase 2, estado idempotencia).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-release.ps1
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
function Reset-State {
    [System.IO.File]::WriteAllText($script:StateFile, "# IDEMPOTENCIA
## Activo
", (New-Object System.Text.UTF8Encoding($false)))
}
function Count-MsgLines([string]$MsgId) {
    return @(Get-Content -LiteralPath $script:StateFile | Where-Object { $_ -match [regex]::Escape($MsgId) }).Count
}

$testDir = Join-Path $env:TEMP ('cross_trelease_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$script:StateFile = Join-Path $testDir 'idempotencia-procesados.md'
Reset-State
$A = 'ses_trelease_A'
$B = 'ses_trelease_B'

Write-Host "== T-release: claim -> release por owner =="
$m1 = 'msg_trelease_1'
Reset-State
[void](Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $A))
$r = Get-Json (Invoke-CrossCli @('release', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $A))
Assert-True ($r.ok) 'release por owner ok' $r.err
$content = Get-Content -LiteralPath $script:StateFile -Raw
Assert-True ($content -match [regex]::Escape("SUPERSEDED_BY=$A")) 'SUPERSEDED_BY escrito' ''
Assert-True ((Count-MsgLines $m1) -eq 2) '2 lineas (claim + release)' (Count-MsgLines $m1)
$r = Get-Json (Invoke-CrossCli @('release', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $A))
Assert-True ($r.ok -and $r.already) 'release repetido idempotente' $r.err

Write-Host "== T-release: release de msg no claimed =="
$m2 = 'msg_trelease_2'
Reset-State
$r = Get-Json (Invoke-CrossCli @('release', '--state-file', $script:StateFile, '--msg', $m2, '--owner', $A))
Assert-True (-not $r.ok -and $r.code -eq 2) 'release sin claim -> code 2' $r.code
Assert-True ($r.err -eq 'NOT_CLAIMED') 'err=NOT_CLAIMED' $r.err

Write-Host "== T-release: no-owner requiere --force =="
$m3 = 'msg_trelease_3'
Reset-State
[void](Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m3, '--owner', $A))
$r = Get-Json (Invoke-CrossCli @('release', '--state-file', $script:StateFile, '--msg', $m3, '--owner', $B))
Assert-True (-not $r.ok -and $r.err -eq 'NOT_OWNER') 'release no-owner -> NOT_OWNER' $r.err
$r = Get-Json (Invoke-CrossCli @('release', '--state-file', $script:StateFile, '--msg', $m3, '--owner', $B, '--force'))
Assert-True ($r.ok) 'release no-owner --force ok' $r.err
$content = Get-Content -LiteralPath $script:StateFile -Raw
Assert-True ($content -match [regex]::Escape("SUPERSEDED_BY=$B")) 'SUPERSEDED_BY=actor escrito' ''

Write-Host "== T-release: release de PROCESADO = error =="
$m4 = 'msg_trelease_4'
Reset-State
[void](Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m4, '--owner', $A))
[void](Invoke-CrossCli @('done', '--state-file', $script:StateFile, '--msg', $m4, '--owner', $A))
$r = Get-Json (Invoke-CrossCli @('release', '--state-file', $script:StateFile, '--msg', $m4, '--owner', $A))
Assert-True (-not $r.ok -and $r.err -eq 'ALREADY_PROCESSED') 'release de PROCESADO -> ALREADY_PROCESSED' $r.err

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
