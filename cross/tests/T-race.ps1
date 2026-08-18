# T-race.ps1 - Concurrency test for the send_message.ps1 wrapper (Phase 5).
# 4 parallel jobs x 20 wrapper calls each = 80 concurrent sends.
# Verifies that outbox.md, delivery_log.jsonl and audit_log.md remain consistent
# (80 unique msg_ids, no corrupt lines, no lost OUTBOX_LOCKED).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-race.ps1
$ErrorActionPreference = 'Stop'
$wrapper = Join-Path $PSScriptRoot '..\send_message.ps1'

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

$script:WhiteDir = Join-Path $env:TEMP ('cross_trace_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:WhiteDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $script:WhiteDir 'outbox.md'), "# OUTBOX`n## Activo (formato v1.6)`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $script:WhiteDir 'audit_log.md'), "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $script:WhiteDir 'delivery_log.jsonl'), '', (New-Object System.Text.UTF8Encoding($false)))

$Jobs = 4
$PerJob = 20
$Expected = $Jobs * $PerJob
$outbox = Join-Path $script:WhiteDir 'outbox.md'
$deliveryLog = Join-Path $script:WhiteDir 'delivery_log.jsonl'
$auditLog = Join-Path $script:WhiteDir 'audit_log.md'

$jobResults = New-Object System.Collections.ArrayList
for ($j = 0; $j -lt $Jobs; $j++) {
    $jobN = $j
    $jobResults += Start-Job -ScriptBlock {
        param($Wrapper, $WhiteDir, $JobN, $PerJob)
        $env:CROSS_WHITEBOARD_DIR = $WhiteDir
        $localFail = 0
        for ($i = 0; $i -lt $PerJob; $i++) {
            $dest = "ses_zzz_no_existe_race_${JobN}_$i"
            $texto = "T-race job $JobN msg $i"
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Wrapper -Destino $dest -Texto $texto -NoReply 2>&1 | Out-String
            if ($out -match 'OUTBOX_LOCKED') { $localFail++ }
        }
        return $localFail
    } -ArgumentList $wrapper, $script:WhiteDir, $jobN, $PerJob
}

$timeout = (Get-Date).AddMinutes(10)
while (@($jobResults | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
    if ((Get-Date) -gt $timeout) { Write-Host 'TIMEOUT waiting for jobs'; $jobResults | Remove-Job -Force; exit 1 }
    Start-Sleep -Milliseconds 500
}

$outboxFail = 0
foreach ($jr in $jobResults) {
    $r = Receive-Job $jr -Keep
    $outboxFail += [int]$r
    Remove-Job $jr -Force
}
Write-Host "== T-race: 4 jobs x 20 wrapper send =="
Assert-True ($outboxFail -eq 0) "no OUTBOX_LOCKED in the $Expected sends" "outboxFail=$outboxFail"

$msgIds = @(Get-Content -LiteralPath $outbox | Where-Object { $_ -match '^\S.*OUTBOX \| msg_' })
Assert-True ($msgIds.Count -eq $Expected) "outbox with $Expected OUTBOX lines" "count=$($msgIds.Count)"
$uniq = @($msgIds | ForEach-Object { if ($_ -match 'OUTBOX \| (\S+) \|') { $Matches[1] } } | Sort-Object -Unique)
Assert-True ($uniq.Count -eq $Expected) "all msg_ids unique" "uniq=$($uniq.Count)"
$corrupt = @($msgIds | Where-Object { $_ -notmatch '^\S+\] OUTBOX \| msg_\S+ \| dest=ses_[^\s|]+ \| run_id=\S+ \| token=\S+ \| lease=[^\s|]+ \|' })
Assert-True ($corrupt.Count -eq 0) "no corrupt OUTBOX lines" "corrupt=$($corrupt.Count)"
$noEstado = @($msgIds | Where-Object { $_ -notmatch 'ESTADO=\S+' })
Assert-True ($noEstado.Count -eq 0) "all lines have ESTADO" "noEstado=$($noEstado.Count)"

$dlLines = @(Get-Content -LiteralPath $deliveryLog | Where-Object { $_.Trim() })
Assert-True ($dlLines.Count -eq $Expected) "delivery_log with $Expected lines" "count=$($dlLines.Count)"
$badJson = 0
$dlIds = New-Object System.Collections.ArrayList
foreach ($l in $dlLines) {
    try { $o = $l | ConvertFrom-Json; [void]$dlIds.Add([string]$o.msg_id) } catch { $badJson++ }
}
Assert-True ($badJson -eq 0) "delivery_log: all lines valid JSON" "badJson=$badJson"
Assert-True (@($dlIds | Sort-Object -Unique).Count -eq $Expected) "delivery_log: unique msg_ids" "uniq=$(@($dlIds | Sort-Object -Unique).Count)"

$auditCount = @(Get-Content -LiteralPath $auditLog | Where-Object { $_ -match 'ENV|RESTART|OUTBOX' }).Count
Assert-True ($auditCount -ge $Expected) "audit_log with at least $Expected ENV entries" "count=$auditCount"

Remove-Item -LiteralPath $script:WhiteDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
