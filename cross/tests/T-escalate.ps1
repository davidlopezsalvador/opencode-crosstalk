# Tests de cross escalate (Fase 4b): URGENTE en escalated.md + wake-on-write.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-escalate.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-diagnostic.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tescalate_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $script:EscalatedFile = Join-Path $dir 'escalated.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:EscalatedFile, "# ESCALADAS`n", (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }

Write-Host "== T-escalate: linea URGENTE canonica =="
New-Fixture
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'sin ACK tras reintentos' -RunId 'R1' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
Assert-True ($r.ok) 'escalate ok' $r.err
Assert-True ($r.written) 'escrito' $r.written
Assert-True ($r.line -match '^URGENTE \| para=ses_Y \| msg_id=msg_x \| run_id=R1') 'formato canonico URGENTE' $r.line
Assert-True ($r.line -match 'de=ses_LEADER') 'de= mi sesion' $r.line
Assert-True ($r.line -match 'expira=\d{4}-\d{2}-\d{2}T') 'expira UTC' $r.line
Assert-True ($r.line -match "'sin ACK tras reintentos'") 'razon entre comillas' $r.line
Assert-True ($r.notified -eq $false) 'sin --apply no notifica' $r.notified

Write-Host "== T-escalate: persiste en escalated.md =="
New-Fixture
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'razon' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
$content = Get-Content -LiteralPath $script:EscalatedFile -Raw
Assert-True ($content -match 'URGENTE \| para=ses_Y') 'URGENTE en archivo' $content

Write-Host "== T-escalate: --apply envia wake-on-write =="
New-Fixture
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'razon' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile -Apply -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.notified -eq $true) 'wake-on-write enviado' $r.notified
Assert-True ($script:Sent.dest -eq 'ses_Y') 'wake al destino' $script:Sent.dest
Assert-True ($script:Sent.text -match 'wake-on-write') 'texto wake-on-write' $script:Sent.text

Write-Host "== T-escalate: validaciones =="
New-Fixture
$r = Write-CrossEscalated -MsgId '' -To 'ses_Y' -Reason 'r' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --msg-id -> USAGE_ERROR' $r.err
$r = Write-CrossEscalated -MsgId 'msg_x' -To '' -Reason 'r' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --to -> USAGE_ERROR' $r.err
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason '' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'sin --reason -> USAGE_ERROR' $r.err

Write-Host "== T-escalate: Read-EscalatedLog parsea msg_id explicito (BUG BB) =="
New-Fixture
[void](Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'razon' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile)
$parsed = @(Read-EscalatedLog -Path $script:EscalatedFile)
Assert-True ($parsed.Count -eq 1) 'escalada leida' $parsed.Count
Assert-True ($parsed[0].msg_id -eq 'msg_x') 'msg_id parseado' $parsed[0].msg_id
Assert-True ($parsed[0].para -eq 'ses_Y' -and $parsed[0].kind -eq 'URGENTE') 'para/kind' "$($parsed[0].para)|$($parsed[0].kind)"

Write-Host "== T-escalate: audit ESCALADA =="
New-Fixture
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'r' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| ESCALADA \| ESCRITO \|') 'audit tipo ESCALADA / ESCRITO' $audit

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
