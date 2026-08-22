# T-idempotencia-race.ps1 - Concurrency test for idempotencia CLAIM/RELEASE/DONE (F1 TOCTOU fix)
# Expected: exactly 1 winner per msg_id, the rest ALREADY_CLAIMED_BY_OTHER (F1 TOCTOU fix v1.16).
# Uses Start-Job (separate PowerShell processes) so Global\CrossOutbox_* mutex is exercised cross-process.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'modules\cross-state.psm1'
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-race-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$stateFile = Join-Path $tmpDir 'idempotencia-procesados.md'

$results = New-Object System.Collections.ArrayList
$failures = New-Object System.Collections.ArrayList

function Assert-True {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) {
        [void]$script:results.Add("PASS  $Name")
    } else {
        [void]$script:failures.Add("FAIL  $Name  $Detail")
    }
}

function Get-JProp {
    param($Obj, [string]$Name)
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

try {
    Import-Module $modulePath -Force -DisableNameChecking

    # ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Test 1: N claims concurrentes (procesos distintos) del mismo msg_id ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
    $n = 5
    $msgId = "msg_race_1"
    $jobs = @()
    for ($i = 0; $i -lt $n; $i++) {
        $jobs += Start-Job -ScriptBlock {
            param($mp, $sf, $owner)
            Import-Module $mp -Force -DisableNameChecking
            return (New-CrossClaim -MsgId 'msg_race_1' -Owner $owner -Path $sf) | ConvertTo-Json -Compress
        } -ArgumentList $modulePath, $stateFile, "ses_job_$i"
    }
    $claims = @()
    foreach ($j in $jobs) {
        $out = Receive-Job -Job $j -Wait | Select-Object -Last 1
        Remove-Job -Job $j -Force
        try { $claims += ($out | ConvertFrom-Json) } catch { [void]$failures.Add("FAIL  job output not JSON: '$out'") }
    }
    $winners  = @($claims | Where-Object { (Get-JProp $_ 'ok') -eq $true  -and (Get-JProp $_ 'already') -eq $false })
    $rejected = @($claims | Where-Object { (Get-JProp $_ 'err') -eq 'ALREADY_CLAIMED_BY_OTHER' })
    Assert-True (($winners.Count)   -eq 1) "race: exactly 1 winner"      "got $($winners.Count)"
    Assert-True (($rejected.Count)  -eq ($n - 1)) "race: $($n - 1) ALREADY_CLAIMED_BY_OTHER" "got $($rejected.Count)"

    # ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Test 2: re-claim del mismo owner es idempotente ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
    # D4-fix (Linux): winner may be ANY job; derive it from the state file.
    $winnerOwner = $null
    foreach ($ln in (Get-Content -LiteralPath $stateFile)) {
        if ($ln -match 'CLAIMED_BY=(\S+)') { $winnerOwner = $Matches[1]; break }
    }
    Assert-True ($null -ne $winnerOwner) "winner owner detectable from state file" "$winnerOwner"
    $again = New-CrossClaim -MsgId $msgId -Owner $winnerOwner -Path $stateFile
    Assert-True ($again.ok -eq $true -and $again.already -eq $true) "re-claim same owner idempotent"

    # ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Test 3: release por no-owner falla sin --force ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
    $r1 = New-CrossRelease -MsgId $msgId -Owner 'ses_intruder' -Path $stateFile
    $again = New-CrossClaim -MsgId $msgId -Owner $winnerOwner -Path $stateFile

    # ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Test 4: release concurrente con --force: exactamente 1 efectivo ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
    $jobs2 = @()
    for ($i = 0; $i -lt 3; $i++) {
        $jobs2 += Start-Job -ScriptBlock {
            param($mp, $sf)
            Import-Module $mp -Force -DisableNameChecking
            return (New-CrossRelease -MsgId 'msg_race_1' -Owner 'ses_force' -Force -Path $sf) | ConvertTo-Json -Compress
        } -ArgumentList $modulePath, $stateFile
    }
    $rel = @()
    foreach ($j in $jobs2) {
        $out = Receive-Job -Job $j -Wait | Select-Object -Last 1
        Remove-Job -Job $j -Force
        try { $rel += ($out | ConvertFrom-Json) } catch { [void]$failures.Add("FAIL  job output not JSON: '$out'") }
    }
    $relOk     = @($rel | Where-Object { (Get-JProp $_ 'ok') -eq $true -and (Get-JProp $_ 'already') -eq $false })
    $relAlread = @($rel | Where-Object { (Get-JProp $_ 'ok') -eq $true -and (Get-JProp $_ 'already') -eq $true })
    Assert-True (($relOk.Count + $relAlread.Count) -eq $rel.Count -and $relOk.Count -ge 1) `
        "force-release: no torn state" "ok=$($relOk.Count) already=$($relAlread.Count) total=$($rel.Count)"

    # ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Test 5: done tras release debe fallar; done tras claim por owner funciona ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
    $d1 = New-CrossDone -MsgId $msgId -Owner 'ses_job_0' -Path $stateFile
    Assert-True ($d1.ok -eq $false -and $d1.err -eq 'RELEASED_CANNOT_DONE') "done after release rejected"

    $msg2 = 'msg_race_2'
    [void](New-CrossClaim -MsgId $msg2 -Owner 'ses_a' -Path $stateFile)
    $doneJobs = @()
    for ($i = 0; $i -lt 3; $i++) {
        $doneJobs += Start-Job -ScriptBlock {
            param($mp, $sf)
            Import-Module $mp -Force -DisableNameChecking
            return (New-CrossDone -MsgId 'msg_race_2' -Owner 'ses_a' -Path $sf) | ConvertTo-Json -Compress
        } -ArgumentList $modulePath, $stateFile
    }
    $dones = @()
    foreach ($j in $doneJobs) {
        $out = Receive-Job -Job $j -Wait | Select-Object -Last 1
        Remove-Job -Job $j -Force
        try { $dones += ($out | ConvertFrom-Json) } catch { [void]$failures.Add("FAIL  job output not JSON: '$out'") }
    }
    $freshDone = @($dones | Where-Object { (Get-JProp $_ 'ok') -eq $true -and (Get-JProp $_ 'already') -eq $false })
    $idemDone  = @($dones | Where-Object { (Get-JProp $_ 'ok') -eq $true -and (Get-JProp $_ 'already') -eq $true })
    Assert-True (($freshDone.Count -eq 1) -and (($freshDone.Count + $idemDone.Count) -eq $dones.Count)) `
        "concurrent done: exactly 1 fresh, rest idempotent" "fresh=$($freshDone.Count) idem=$($idemDone.Count)"

    # ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ Test 6: el archivo de estado quedÃƒÆ’Ã‚Â³ consistente (1 CLAIMED_BY, 1 SUPERSEDED_BY, 1 PROCESADO) ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬ÃƒÂ¢Ã¢â‚¬ÂÃ¢â€šÂ¬
    $content = Get-Content -LiteralPath $stateFile -Raw
    $cClaim = ([regex]::Matches($content, 'CLAIMED_BY=')).Count
    $cSup   = ([regex]::Matches($content, 'SUPERSEDED_BY=')).Count
    $cProc  = ([regex]::Matches($content, '\| PROCESADO')).Count
    Assert-True ($cClaim -eq 2 -and $cSup -eq 1 -and $cProc -eq 1) `
        "state file consistent" "claims=$cClaim supers=$cSup procesado=$cProc"
}
finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
$results  | ForEach-Object { Write-Host $_ }
$failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
Write-Host ""
# v1.16: CI-compatible summary line (workflow parses 'RESULT: X pass, Y fail')
Write-Host ("RESULT: {0} pass, {1} fail" -f $results.Count, $failures.Count)
if ($failures.Count -eq 0) {
    Write-Host "T-idempotencia-race: ALL PASS ($($results.Count) checks)" -ForegroundColor Green
    exit 0
} else {
    Write-Host "T-idempotencia-race: $($failures.Count) FAILURES / $($results.Count) passed" -ForegroundColor Red
    exit 1
}
