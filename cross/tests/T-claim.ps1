# Tests de cross claim (Fase 2, estado idempotencia).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-claim.ps1
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

$testDir = Join-Path $env:TEMP ('cross_tclaim_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$script:StateFile = Join-Path $testDir 'idempotencia-procesados.md'
Reset-State
$A = 'ses_tclaim_A'
$B = 'ses_tclaim_B'
$m1 = 'msg_tclaim_1'

Write-Host "== T-claim: claim nuevo msg_id =="
Reset-State
$r = Get-Json (Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $A))
Assert-True ($null -ne $r -and $r.ok) 'claim nuevo ok' $r.err
$content = Get-Content -LiteralPath $script:StateFile -Raw
Assert-True ($content -match [regex]::Escape("CLAIMED_BY=$A")) 'CLAIMED_BY escrito' ''
Assert-True ((Count-MsgLines $m1) -eq 1) 'una sola linea para el msg' (Count-MsgLines $m1)

Write-Host "== T-claim: re-claim por mismo = idempotente =="
$r = Get-Json (Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $A))
Assert-True ($r.ok -and $r.already) 're-claim mismo ok idempotente' $r.err
Assert-True ((Count-MsgLines $m1) -eq 1) 'no se duplica la linea' (Count-MsgLines $m1)

Write-Host "== T-claim: re-claim por otro = error 2 =="
$r = Get-Json (Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $B))
Assert-True (-not $r.ok -and $r.code -eq 2) 're-claim otro -> code 2' $r.code
Assert-True ($r.err -eq 'ALREADY_CLAIMED_BY_OTHER') 'err=ALREADY_CLAIMED_BY_OTHER' $r.err

Write-Host "== T-claim: claim tras PROCESADO = idempotente =="
$m2 = 'msg_tclaim_2'
Reset-State
[void](Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m2, '--owner', $A))
[void](Invoke-CrossCli @('done', '--state-file', $script:StateFile, '--msg', $m2, '--owner', $A))
$r = Get-Json (Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m2, '--owner', $A))
Assert-True ($r.ok -and $r.already) 'claim tras PROCESADO idempotente' $r.err

Write-Host "== T-claim: uso =="
$r = Get-Json (Invoke-CrossCli @('claim'))
Assert-True (-not $r.ok -and $r.code -eq 64) 'claim sin --msg -> 64' $r.err

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
