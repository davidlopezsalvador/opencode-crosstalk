# Tests de cross done (Fase 2, estado idempotencia).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-done.ps1
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

$testDir = Join-Path $env:TEMP ('cross_tdone_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
$script:StateFile = Join-Path $testDir 'idempotencia-procesados.md'
Reset-State
$A = 'ses_tdone_A'
$B = 'ses_tdone_B'

Write-Host "== T-done: claim -> done por owner =="
$m1 = 'msg_tdone_1'
Reset-State
[void](Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $A))
$r = Get-Json (Invoke-CrossCli @('done', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $A))
Assert-True ($r.ok) 'done por owner ok' $r.err
$content = Get-Content -LiteralPath $script:StateFile -Raw
Assert-True ($content -match ' \| PROCESADO$') 'PROCESADO escrito' ''
Assert-True ((Count-MsgLines $m1) -eq 2) '2 lineas (claim + done)' (Count-MsgLines $m1)
$r = Get-Json (Invoke-CrossCli @('done', '--state-file', $script:StateFile, '--msg', $m1, '--owner', $A))
Assert-True ($r.ok -and $r.already) 'done repetido idempotente' $r.err

Write-Host "== T-done: done sin claim previo =="
$m2 = 'msg_tdone_2'
Reset-State
$r = Get-Json (Invoke-CrossCli @('done', '--state-file', $script:StateFile, '--msg', $m2, '--owner', $A))
Assert-True (-not $r.ok -and $r.code -eq 2) 'done sin claim -> code 2' $r.code
Assert-True ($r.err -eq 'NOT_CLAIMED') 'err=NOT_CLAIMED' $r.err

Write-Host "== T-done: done de msg SUPERSEDED =="
$m3 = 'msg_tdone_3'
Reset-State
[void](Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m3, '--owner', $A))
[void](Invoke-CrossCli @('release', '--state-file', $script:StateFile, '--msg', $m3, '--owner', $A))
$r = Get-Json (Invoke-CrossCli @('done', '--state-file', $script:StateFile, '--msg', $m3, '--owner', $A))
Assert-True (-not $r.ok -and $r.err -eq 'RELEASED_CANNOT_DONE') 'done de SUPERSEDED -> RELEASED_CANNOT_DONE' $r.err

Write-Host "== T-done: done por no-owner =="
$m4 = 'msg_tdone_4'
Reset-State
[void](Invoke-CrossCli @('claim', '--state-file', $script:StateFile, '--msg', $m4, '--owner', $A))
$r = Get-Json (Invoke-CrossCli @('done', '--state-file', $script:StateFile, '--msg', $m4, '--owner', $B))
Assert-True (-not $r.ok -and $r.err -eq 'NOT_OWNER') 'done no-owner -> NOT_OWNER' $r.err

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
