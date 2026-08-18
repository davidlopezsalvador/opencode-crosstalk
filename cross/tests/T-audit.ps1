# Tests de la capa de auditoria e idempotencia (cross-state + cross-diagnostic).
# Cubre: Write-AuditEntry (BUG S: nota no duplicada), Add-CrossLogLine (append
# con retry), Find-AuditOutcome (BUG M: delimitadores msg=), Read-IdempotenciaLog
# (ultima linea gana, O1), Get-MsgState, Add-IdempotenciaLine.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-audit.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-diagnostic.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
$script:AuditFile = ''
$script:IdemFile = ''
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_taudit_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $script:IdemFile = Join-Path $dir 'idempotencia-procesados.md'
}

Write-Host "== T-audit: Write-AuditEntry crea el archivo y formato pipe =="
New-Fixture
$r = Write-AuditEntry -MsgId 'msg_a1' -Dest 'ses_A' -Token 'T1' -Tipo 'ENV' -Estado 'EN_VUELO' -AuditPath $script:AuditFile
Assert-True ($r.ok) 'Write-AuditEntry ok' ($r | ConvertTo-Json -Compress)
$content = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($content -match '\| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \| .*? \| ses_A \| T1 \| ENV \| EN_VUELO \| msg=msg_a1 \|') 'fila pipe completa' $content

Write-Host "== T-audit: BUG S - nota NO duplicada =="
$r = Write-AuditEntry -MsgId 'msg_a2' -Dest 'ses_A' -Token 'T2' -Tipo 'ACK' -Estado 'CONFIRMADO' -Nota 'ack real' -AuditPath $script:AuditFile
Assert-True ($r.ok) 'ok con nota' ($r | ConvertTo-Json -Compress)
$line = Get-Content -LiteralPath $script:AuditFile | Where-Object { $_ -match 'T2' }
Assert-True ($line -match 'msg=msg_a2; ack real') 'nota concatenada una vez' $line
Assert-True (([regex]::Matches($line, 'msg=msg_a2').Count) -eq 1) 'msg= aparece UNA vez (BUG S)' $line

Write-Host "== T-audit: Add-CrossLogLine append multiple + sin BOM =="
New-Fixture
$r1 = Add-CrossLogLine -Path $script:AuditFile -Line 'A'
$r2 = Add-CrossLogLine -Path $script:AuditFile -Line 'B'
$lines = Get-Content -LiteralPath $script:AuditFile
Assert-True ($r1.ok -and $r2.ok) 'append x2 ok' ($r1 | ConvertTo-Json -Compress)
Assert-True ($lines.Count -eq 2 -and $lines[0] -eq 'A' -and $lines[1] -eq 'B') 'append respeta orden' ($lines -join '; ')
$bytes = [System.IO.File]::ReadAllBytes($script:AuditFile)
Assert-True ($bytes.Length -lt 3 -or -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'sin BOM al inicio' $bytes[0]

Write-Host "== T-audit: Find-AuditOutcome ACK/NACK + BUG M (delimitadores) =="
New-Fixture
[System.IO.File]::WriteAllText($script:AuditFile, @"
| 2026-08-12T00:00:00Z | lider | ses_A | T1 | ACK | CONFIRMADO | msg=msg_a1 |
| 2026-08-12T00:01:00Z | lider | ses_A | T2 | NACK | NACKED | msg=msg_a2; rc=NACK_TIMEOUT |
| 2026-08-12T00:02:00Z | lider | ses_A | T3 | ENV | EN_VUELO | msg=msg_a12; no es msg_a1 |
"@, (New-Object System.Text.UTF8Encoding($false)))
$r = Find-AuditOutcome -MsgId 'msg_a1' -AuditPath $script:AuditFile
Assert-True ($r.ack -and $r.ack.estado -eq 'CONFIRMADO') 'ACK encontrado para msg_a1' ($r | ConvertTo-Json -Compress)
Assert-True ($null -eq $r.nack) 'sin NACK para msg_a1' ($r | ConvertTo-Json -Compress)
$r = Find-AuditOutcome -MsgId 'msg_a2' -AuditPath $script:AuditFile
Assert-True ($r.nack -and $r.nack.reason -eq 'NACK_TIMEOUT') 'NACK con reason' ($r | ConvertTo-Json -Compress)
$r = Find-AuditOutcome -MsgId 'msg_a12' -AuditPath $script:AuditFile
Assert-True ($null -eq $r.ack -and $null -eq $r.nack) 'msg_a12 no matchea la linea de msg_a1 (BUG M)' ($r | ConvertTo-Json -Compress)

Write-Host "== T-audit: Find-AuditOutcome audit inexistente =="
New-Fixture
$r = Find-AuditOutcome -MsgId 'msg_x' -AuditPath $script:AuditFile
Assert-True ($null -eq $r.ack -and $null -eq $r.nack) 'audit inexistente -> vacio' ($r | ConvertTo-Json -Compress)

Write-Host "== T-audit: Read-IdempotenciaLog + ultima linea gana =="
New-Fixture
[System.IO.File]::WriteAllText($script:IdemFile, @"
# IDEMPOTENCIA
## Activo
msg_io | 2026-08-12T00:00:00Z | M | CLAIMED_BY=ses_X
msg_io | 2026-08-12T00:05:00Z | M | PROCESADO
msg_io2 | 2026-08-12T00:00:00Z | M | CLAIMED_BY=ses_X
linea basura sin formato
"@, (New-Object System.Text.UTF8Encoding($false)))
$records = Read-IdempotenciaLog -Path $script:IdemFile
Assert-True ($records.Count -eq 3) '3 registros validos, basura ignorada' $records.Count
$st = Get-MsgState -MsgId 'msg_io' -Path $script:IdemFile
Assert-True ($st.state -eq 'PROCESADO') 'ultima linea gana: PROCESADO' $st.state
$st2 = Get-MsgState -MsgId 'msg_io2' -Path $script:IdemFile
Assert-True ($st2.state -eq 'CLAIMED_BY=ses_X') 'msg_io2 queda CLAIMED' $st2.state

Write-Host "== T-audit: Add-IdempotenciaLine crea dir y archivo si falta =="
New-Fixture
$r = Add-IdempotenciaLine -MsgId 'msg_new' -Timestamp '2026-08-12T00:00:00Z' -Modelo 'M' -State 'PROCESADO' -Path $script:IdemFile
Assert-True ($r -match 'msg_new \| 2026-08-12T00:00:00Z \| M \| PROCESADO') 'linea correcta' $r
Assert-True (Test-Path -LiteralPath $script:IdemFile) 'archivo creado' $script:IdemFile
$st = Get-MsgState -MsgId 'msg_new' -Path $script:IdemFile
Assert-True ($st.state -eq 'PROCESADO') 'lee lo escrito' $st.state

Write-Host "== T-audit: Get-MsgState sin coincidencia -> null =="
New-Fixture
$st = Get-MsgState -MsgId 'no_existe' -Path $script:IdemFile
Assert-True ($null -eq $st) 'sin msg -> null' ($null -ne $st)

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
