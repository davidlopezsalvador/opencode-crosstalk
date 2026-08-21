# T-v1-deprecation.ps1 - F4 (v1.16): warning once-per-proceso + contador de uso v1 + metricas.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$deliveryPath = Join-Path $repoRoot 'modules\cross-delivery.psm1'
$diagPath = Join-Path $repoRoot 'modules\cross-diagnostic.psm1'

$results = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList
function Assert-True {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { [void]$script:results.Add("PASS  $Name") }
    else { [void]$script:failures.Add("FAIL  $Name  $Detail") }
}

# Ã¢â€â‚¬Ã¢â€â‚¬ Proceso hijo aislado: flag once-per-proceso y contador parten de cero Ã¢â€â‚¬Ã¢â€â‚¬
$inner = @'
Set-StrictMode -Version 2.0
Import-Module '__DELIVERY__' -Force -DisableNameChecking
$r1 = Parse-CrossAckText -Text 'ACK-PROTOCOLO:1.8' 3>&1
$w1 = @($r1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count
$r2 = Parse-CrossAckText -Text 'sin protocolo' 3>&1
$w2 = @($r2 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count
$c1 = (Get-CrossV1Usage).count
$null = Parse-CrossAckText -Text 'ACK-PROTOCOLO:1.8' 3>&1
$c2 = (Get-CrossV1Usage).count
Write-Output "W_FIRST=$w1"
Write-Output "W_SECOND=$w2"
Write-Output "COUNT_2PARSE=$c1"
Write-Output "COUNT_3PARSE=$c2"
'@
$inner = $inner.Replace('__DELIVERY__', $deliveryPath)
$tmpScript = Join-Path $env:TEMP ("T-v1-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
[System.IO.File]::WriteAllText($tmpScript, $inner, (New-Object System.Text.UTF8Encoding($false)))
try {
    $raw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmpScript 2>&1 | Out-String
} finally {
    Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue
}
$map = @{}
foreach ($l in (@($raw -split "`r?`n") | Where-Object { $_ -match '^(W_FIRST|W_SECOND|COUNT_2PARSE|COUNT_3PARSE)=' })) {
    $kv = $l.Trim() -split '=', 2
    $map[$kv[0]] = $kv[1]
}

Assert-True ([int]$map['W_FIRST'] -ge 1) 'warning DEPRECATED en primer uso v1' "$($map['W_FIRST'])"
Assert-True ([int]$map['W_SECOND'] -eq 0) 'warning solo una vez por proceso' "$($map['W_SECOND'])"
Assert-True ([int]$map['COUNT_2PARSE'] -eq 2) 'contador tras 2 parseos' "$($map['COUNT_2PARSE'])"
Assert-True ([int]$map['COUNT_3PARSE'] -eq 3) 'contador incrementa por parseo' "$($map['COUNT_3PARSE'])"

# Ã¢â€â‚¬Ã¢â€â‚¬ Get-CrossMetrics expone v1_ack_parse_count Ã¢â€â‚¬Ã¢â€â‚¬
$inner2 = @'
Set-StrictMode -Version 2.0
Import-Module '__DELIVERY__' -Force -DisableNameChecking
Import-Module '__DIAG__' -Force -DisableNameChecking
$null = Parse-CrossAckText -Text 'ACK-PROTOCOLO:1.8' 3>&1
$logTmp = Join-Path $env:TEMP ('met_' + [guid]::NewGuid().ToString('N') + '.jsonl')
'[{"ts":"2026-08-21T00:00:00Z","msg_id":"m1","dest":"ses_A","state":"CONFIRMADO"}]' | Set-Content -LiteralPath $logTmp
$m = Get-CrossMetrics -LogPath $logTmp
Remove-Item -LiteralPath $logTmp -Force
if ($m -and $m -is [hashtable] -and $m.Contains('v1_ack_parse_count')) {
    if ($null -ne $m['v1_ack_parse_count']) { Write-Output ("FIELD=" + $m['v1_ack_parse_count']) } else { Write-Output 'FIELD=NULL' }
} elseif ($m -and $m.PSObject.Properties['v1_ack_parse_count']) {
    if ($null -ne $m.v1_ack_parse_count) { Write-Output ("FIELD=" + $m.v1_ack_parse_count) } else { Write-Output 'FIELD=NULL' }
} else { Write-Output 'FIELD=MISSING' }
'@
$inner2 = $inner2.Replace('__DELIVERY__', $deliveryPath).Replace('__DIAG__', $diagPath)
$tmpScript2 = Join-Path $env:TEMP ("T-v1b-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
[System.IO.File]::WriteAllText($tmpScript2, $inner2, (New-Object System.Text.UTF8Encoding($false)))
try {
    $raw2 = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmpScript2 2>&1 | Out-String
} finally {
    Remove-Item -LiteralPath $tmpScript2 -Force -ErrorAction SilentlyContinue
}
$fieldLine = @($raw2 -split "`r?`n") | Where-Object { $_ -match '^FIELD=' } | Select-Object -First 1
$fieldVal = if ($fieldLine) { ($fieldLine.Trim() -split '=', 2)[1] } else { 'MISSING' }
Assert-True ($fieldVal -notin @('MISSING', '', 'NULL')) 'metrics expone v1_ack_parse_count' $fieldVal

Write-Host ""
$results  | ForEach-Object { Write-Host $_ }
$failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
Write-Host ""
# v1.16: CI-compatible summary line (workflow parses 'RESULT: X pass, Y fail')
Write-Host ("RESULT: {0} pass, {1} fail" -f $results.Count, $failures.Count)
if ($failures.Count -eq 0) {
    Write-Host "T-v1-deprecation: ALL PASS ($($results.Count) checks)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "T-v1-deprecation: $($failures.Count) FAILURES / $($results.Count) passed" -ForegroundColor Red
    exit 1
}