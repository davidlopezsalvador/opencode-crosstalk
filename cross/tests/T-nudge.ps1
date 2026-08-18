# Tests de cross nudge (Fase 4b): prompt firme anti-'Continue'.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-nudge.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tnudge_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }

Write-Host "== T-nudge: prompt firme con token =="
New-Fixture
$r = Send-CrossNudge -To 'ses_X' -Task 'entrega el informe msg_1' -Token 'T1' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'nudge ok' $r.err
Assert-True ($r.prompt -match 'IGNORA|ignora') 'prompt firme' $r.prompt
Assert-True ($r.prompt -match "Continue") 'menciona Continue' $r.prompt
Assert-True ($r.prompt -match 'entrega el informe msg_1') 'tarea presente' $r.prompt
Assert-True ($r.prompt -match 'token: T1') 'token presente' $r.prompt
Assert-True ($script:Sent.dest -eq 'ses_X') 'destino de envio' $script:Sent.dest

Write-Host "== T-nudge: sin token no incluye token =="
New-Fixture
$r = Send-CrossNudge -To 'ses_X' -Task 'tarea' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.prompt -notmatch 'token:') 'sin token omitido' $r.prompt

Write-Host "== T-nudge: validaciones =="
New-Fixture
$r = Send-CrossNudge -To '' -Task 'tarea' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --to -> USAGE_ERROR' $r.err
$r = Send-CrossNudge -To 'ses_X' -Task '' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --task -> USAGE_ERROR' $r.err

Write-Host "== T-nudge: audit NUDGE =="
New-Fixture
$r = Send-CrossNudge -To 'ses_X' -Task 'tarea' -Token 'T1' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| NUDGE \| ENVIADO \|') 'audit tipo NUDGE / ENVIADO' $audit

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
