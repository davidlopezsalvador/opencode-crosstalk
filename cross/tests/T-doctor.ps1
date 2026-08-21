# Doctor & integrity tests (v1.12): checksum v1.7, Repair-CrossIdempotencia, Get-CrossDoctorReport, cross doctor CLI.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-doctor.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-diagnostic.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

$tmpDir = Join-Path $env:TEMP ('cross_tdoc_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$idemFile = Join-Path $tmpDir 'idempotencia-procesados.md'
[System.IO.File]::WriteAllText($idemFile, "# IDEMPOTENCIA`n## Activo (formato v1.7)`n", (New-Object System.Text.UTF8Encoding($false)))

Write-Host "== T-doctor: checksum round-trip (v1.7) =="
$line = Add-IdempotenciaLine -MsgId 'msg_w1' -Timestamp '2026-08-20 12:00:00' -Modelo 'm1' -State 'CLAIMED_BY=ses_AAA' -Path $idemFile
Assert-True ($line -match '\| sha256:[0-9a-f]{64}$') 'linea v1.7 con sha256 completo (64 hex, N1)' $line
$recs = Read-IdempotenciaLog -Path $idemFile
$r1 = $recs | Where-Object { $_.msg_id -eq 'msg_w1' } | Select-Object -First 1
Assert-True ($null -ne $r1) 'registro parseado tras checksum' ($null -ne $r1)
if ($r1) {
    Assert-True ($r1.state -eq 'CLAIMED_BY=ses_AAA') 'state correcto' $r1.state
    Assert-True (-not $r1.corrupt) 'corrupt=false' $r1.corrupt
}

Write-Host "== T-doctor: linea legacy sin checksum (compatibilidad v1.6.1) =="
[System.IO.File]::AppendAllText($idemFile, "msg_legacy | 2026-08-19 10:00:00 | m0 | PROCESADO`n", (New-Object System.Text.UTF8Encoding($false)))
$recsLegacy = Read-IdempotenciaLog -Path $idemFile
Assert-True (@($recsLegacy | Where-Object { $_.msg_id -eq 'msg_legacy' }).Count -eq 1) 'legacy sin checksum parseado' (@($recsLegacy | Where-Object { $_.msg_id -eq 'msg_legacy' }).Count)

Write-Host "== T-doctor: corrupcion detectada y saltada =="
$corruptLine = $line -replace 'ses_AAA', 'ses_BBB'
[System.IO.File]::AppendAllText($idemFile, $corruptLine + "`n", (New-Object System.Text.UTF8Encoding($false)))
$ex = Read-IdempotenciaLogEx -Path $idemFile
Assert-True ($ex.corrupt_count -ge 1) 'corrupt_count >= 1' $ex.corrupt_count
$recsAfter = Read-IdempotenciaLog -Path $idemFile
Assert-True (@($recsAfter | Where-Object { $_.msg_id -eq 'msg_w1' }).Count -eq 1) 'linea corrupta no aparece en resultados' (@($recsAfter | Where-Object { $_.msg_id -eq 'msg_w1' }).Count)

Write-Host "== T-doctor: Get-MsgState tolerante (N2) =="
$st = Get-MsgState -MsgId 'msg_w1' -Path $idemFile
Assert-True ($null -ne $st) 'Get-MsgState devuelve registro valido' ($null -ne $st)
if ($st) { Assert-True ($st.state -eq 'CLAIMED_BY=ses_AAA') 'usa el anterior valido' $st.state }

$idemCorrupt = Join-Path $tmpDir 'idem-corrupt-only.md'
[System.IO.File]::WriteAllText($idemCorrupt, "# IDEMPOTENCIA`n## Activo (formato v1.7)`n" + $corruptLine + "`n", (New-Object System.Text.UTF8Encoding($false)))
$st2 = Get-MsgState -MsgId 'msg_w1' -Path $idemCorrupt
Assert-True ($null -ne $st2 -and $st2.state -eq 'CORRUPTED_ALL') 'todas corruptas -> CORRUPTED_ALL' $(if ($st2) { $st2.state } else { 'null' })
$st3 = Get-MsgState -MsgId 'no_existe' -Path $idemFile
Assert-True ($null -eq $st3) 'sin entradas -> null (distinguido de CORRUPTED_ALL)' $null

Write-Host "== T-doctor: Repair-CrossIdempotencia (N4) =="
$rep = Repair-CrossIdempotencia -Path $idemFile
Assert-True (-not $rep.rewritten) 'sin -Rewrite no reescribe' $rep.rewritten
Assert-True ($rep.corrupt_lines.Count -ge 1) 'diagnostica lineas corruptas' $rep.corrupt_lines.Count
$repDry = Repair-CrossIdempotencia -Path $idemFile -DryRun
Assert-True (-not $repDry.rewritten) '-DryRun no reescribe' $repDry.rewritten
$before = (Get-Content -LiteralPath $idemFile).Count
$repRw = Repair-CrossIdempotencia -Path $idemFile -Rewrite
Assert-True ($repRw.rewritten) '-Rewrite reescribe' $repRw.rewritten
Assert-True (Test-Path -LiteralPath "$idemFile.bak") 'backup .bak creado' "$idemFile.bak"
$after = (Get-Content -LiteralPath $idemFile).Count
Assert-True ($after -eq $before - 1) 'linea corrupta eliminada (1 menos)' "$before -> $after"
$rep2 = Repair-CrossIdempotencia -Path $idemFile
Assert-True ($rep2.ok -and $rep2.corrupt_lines.Count -eq 0) 'sin corruptas despues del rewrite' $rep2.detail

Write-Host "== T-doctor: Test-CrossConsistency warning corruptas =="
[System.IO.File]::AppendAllText($idemFile, $corruptLine + "`n", (New-Object System.Text.UTF8Encoding($false)))
$cons = Test-CrossConsistency -StatePath $idemFile
Assert-True (@($cons.warnings | Where-Object { $_ -match 'checksum corrupto' }).Count -ge 1) 'warning checksum corrupto en consistency' ($cons.warnings -join '; ')

Write-Host "== T-doctor: Get-CrossDoctorReport schema =="
$d = Get-CrossDoctorReport
Assert-True ($null -ne $d) 'report devuelve objeto' ($null -ne $d)
Assert-True ($d.ok -is [bool]) 'ok es bool' $d.ok
Assert-True (@($d.checks).Count -eq 7) '7 checks (v1.16: + v1_deprecation)' @($d.checks).Count
Assert-True ($d.summary.fail -eq $d.error_count) 'summary.fail == error_count' "$($d.summary.fail) vs $($d.error_count)"
$names = @($d.checks | ForEach-Object { $_.name })
Assert-True (($names -join ',') -eq 'config,v1_deprecation,paths,integrity,password,server,consistencia') 'check names (v1.16)' ($names -join ',')

Write-Host "== T-doctor: cross doctor CLI con config rota =="
$badCfg = Join-Path $tmpDir 'cross.config.json'
[System.IO.File]::WriteAllText($badCfg, '{ config invalido', (New-Object System.Text.UTF8Encoding($false)))
$cli = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\cross.ps1') doctor --config $badCfg 2>&1
$cliOut = ($cli | Out-String)
Assert-True ($cliOut -match '"ok":false') 'doctor con config rota -> ok=false' ($cliOut -match '"ok":false')
Assert-True ($cliOut -match 'config') 'error de config presente' ($cliOut -match 'config')
$cliOk = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\cross.ps1') doctor 2>&1
$cliOkOut = ($cliOk | Out-String)
Assert-True ($cliOkOut -match '"cmd":"doctor"') 'doctor CLI responde cmd=doctor' ($cliOkOut -match 'cmd')

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }