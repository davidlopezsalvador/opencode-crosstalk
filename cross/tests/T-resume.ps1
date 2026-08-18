# Tests de cross resume (Fase 4b): continuacion sin nuevo msg_id ni incremento de attempt.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-resume.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tresume_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_tx | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=EN_VUELO | attempt=1
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }
$script:OutboxBefore = $null

Write-Host "== T-resume: envia instruccion de continuacion =="
New-Fixture
$script:OutboxBefore = Get-Content -LiteralPath $script:OutboxFile -Raw
$r = Send-CrossResume -To 'ses_X' -TaskId 'msg_tx' -From 'diario/15_charla.md:3' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'resume ok' $r.err
Assert-True ($r.new_msg_id -eq $false) 'NO crea nuevo msg_id' $r.new_msg_id
Assert-True ($r.prompt -match 'Continúa desde "diario/15_charla.md:3"') 'prompt continua desde checkpoint' $r.prompt
Assert-True ($r.prompt -match 'msg_tx') 'prompt menciona la tarea' $r.prompt
Assert-True ($script:Sent.dest -eq 'ses_X') 'destino de envio' $script:Sent.dest

Write-Host "== T-resume: NO toca el outbox (ni attempt) =="
New-Fixture
$script:OutboxBefore = Get-Content -LiteralPath $script:OutboxFile -Raw
$r = Send-CrossResume -To 'ses_X' -TaskId 'msg_tx' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$after = Get-Content -LiteralPath $script:OutboxFile -Raw
Assert-True ($after -eq $script:OutboxBefore) 'outbox sin cambios' $after
Assert-True ($after -match 'attempt=1') 'attempt no incrementado' $after

Write-Host "== T-resume: text propio prevalece =="
New-Fixture
$r = Send-CrossResume -To 'ses_X' -TaskId 'msg_tx' -Text 'Retoma el informe en la linea 3 y firmalo.' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.prompt -eq 'Retoma el informe en la linea 3 y firmalo.') 'text propio usado' $r.prompt

Write-Host "== T-resume: validaciones =="
New-Fixture
$r = Send-CrossResume -To '' -TaskId 'msg_tx' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --to -> USAGE_ERROR' $r.err
$r = Send-CrossResume -To 'ses_X' -TaskId '' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --task-id -> USAGE_ERROR' $r.err

Write-Host "== T-resume: audit RESUME =="
New-Fixture
$r = Send-CrossResume -To 'ses_X' -TaskId 'msg_tx' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| RESUME \| ENVIADO \|') 'audit tipo RESUME / ENVIADO' $audit
Assert-True ($audit -match 'msg=msg_tx') 'audit con task_id' $audit
Assert-True ($audit -match 'NO nuevo msg_id') 'audit nota no crea msg_id' $audit

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
