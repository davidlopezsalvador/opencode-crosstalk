# Cross nack tests (Phase 4b): sending NACK with closed reason and traceability.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-nack.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tnack_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }

$config = Get-Content (Join-Path $PSScriptRoot '..\cross.config.json') -Raw | ConvertFrom-Json
$mySession = [string]$config.my_session_id
$myModel = [string]$config.my_model

Write-Host "== T-nack: NACK 5 segments (model auto-derived from config, no ids) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'nack ok' $r.err
Assert-True ($r.segments -eq 5) '5 segments (NACK:token:id:model:reason auto-derived)' $r.segments
Assert-True ($r.nack_text -eq "NACK:T1:${mySession}:${myModel}:CAPACITY") 'basic NACK text with config model' $r.nack_text

Write-Host "== T-nack: NACK 5 segments (with model) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.segments -eq 5) '5 segments (NACK:token:id:model:reason)' $r.segments
$p = Parse-CrossAckText $r.nack_text
Assert-True ($p.nack -and $p.razon -eq 'CAPACITY') 'parser recovers reason' "$($p.razon)"
Assert-True ($p.emisor -eq $mySession) 'parser recovers sender' $p.emisor

Write-Host "== T-nack: msg_id without run_id does NOT enrich frame (5 segments) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'TOOL_MISSING' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.segments -eq 5) '5 segments (msg_id alone does not enrich)' $r.segments
$p = Parse-CrossAckText $r.nack_text
Assert-True ($p.razon -eq 'TOOL_MISSING') 'reason in 5 segments' $p.razon

Write-Host "== T-nack: nack_msg_id/nack_run_id propagation (7 segments, enriched) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_orig' -ForRunId 'run_orig' -Reason 'PROVIDER_DOWN' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.segments -eq 7) '7 segments (with msg_id and run_id)' $r.segments
$p = Parse-CrossAckText $r.nack_text
Assert-True ($p.msg_id -eq 'msg_orig' -and $p.run_id -eq 'run_orig') 'parser extracts msg_id/run_id' "$($p.msg_id)|$($p.run_id)"
Assert-True ($p.razon -eq 'PROVIDER_DOWN') 'reason propagated' $p.razon

Write-Host "== T-nack: BUG Y - enriched WITHOUT --model auto-derives from config (7 segments) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -ForRunId 'R1' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'enriched nack ok' $r.err
Assert-True ($r.segments -eq 7) '7 segments (never ambiguous 6-segment frame)' $r.segments
Assert-True ($r.nack_text -eq "NACK:T1:${mySession}:${myModel}:CAPACITY:msg_x:R1") 'model auto-derived in position 3' $r.nack_text
$p = Parse-CrossAckText $r.nack_text
Assert-True ($p.razon -eq 'CAPACITY' -and $p.msg_id -eq 'msg_x' -and $p.run_id -eq 'R1' -and $p.modelo -eq $myModel) 'parser unambiguous (reason/model/ids correct)' "$($p.razon)|$($p.modelo)|$($p.msg_id)|$($p.run_id)"

Write-Host "== T-nack: closed reasons =="
foreach ($razon in @('CAPACITY', 'TOOL_MISSING', 'AMBIGUOUS_TASK', 'PROVIDER_DOWN', 'OTHER')) {
    New-Fixture
    $r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason $razon -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
    Assert-True ($r.ok -and $r.reason -eq $razon) "valid reason $razon" $r.err
}

Write-Host "== T-nack: non-closed reason -> NACK_REASON_INVALID =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'PORQUE_NO' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'NACK_REASON_INVALID') 'free reason rejected' $r.err

Write-Host "== T-nack: empty token -> USAGE_ERROR =="
New-Fixture
$r = Send-CrossNack -Token '' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'empty token rejected' $r.err

Write-Host "== T-nack: audit recorded with reason =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -Note 'context exhausted' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| NACK \| ENVIADO \|') 'audit type NACK / SENT' $audit
Assert-True ($audit -match 'nack razon=CAPACITY') 'audit with reason' $audit
Assert-True ($audit -match 'msg=msg_x') 'audit with msg_id' $audit

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
