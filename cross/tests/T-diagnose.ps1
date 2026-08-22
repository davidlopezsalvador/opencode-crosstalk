# T-diagnose.ps1 - D2 (v1.17): structured API-first failure diagnosis.
# REWRITTEN: the legacy free-text grep of opencode.log is GONE. Classification
# now uses local validation + /global/health + GET /session/:id, fully mockable.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-diagnose.ps1
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
    param([string]$Dest = 'ses_X', [string]$Token = 'T1', [string]$MsgId = 'msg_diag')
    $dir = Join-Path $env:TEMP ('cross_tdiag_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | $MsgId | dest=$Dest | run_id=R1 | token=$Token | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=EN_VUELO | attempt=1
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
}

$recentIso = (Get-Date).ToUniversalTime().AddSeconds(-10).ToString('yyyy-MM-ddTHH:mm:ssZ')
$oldIso    = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')

# ── static guard: no third-party log scraping in the implementation ──
Write-Host "== T-diagnose: static guard (no third-party logs) =="
$srcFile = Join-Path $PSScriptRoot '..\modules\cross-action.psm1'
$src = Get-Content -LiteralPath $srcFile -Raw
$fnStart = $src.IndexOf('function Get-CrossDiagnose')
$fnEnd = $src.IndexOf('Export-ModuleMember', $fnStart)
$fnSrc = $src.Substring($fnStart, $fnEnd - $fnStart)
Assert-True ($fnSrc -notmatch 'opencode\.log') 'no opencode.log reference' ''
Assert-True ($fnSrc -notmatch 'main\.log') 'no main.log reference' ''
Assert-True ($fnSrc -notmatch 'Get-Content -LiteralPath \$LogPath') 'no third-party log reads' ''

# ── dest/token taken from outbox entry ──
Write-Host "== T-diagnose: outbox-driven context =="
New-Fixture
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile `
        -HealthFn { $true } -SessionFn { param($id) @{ ok = $true; status = 'busy'; last_activity_at = ''; model = ''; checkable = $true } }
Assert-True ($r.ok) 'diagnose ok' $r.err
Assert-True ($r.dest -eq 'ses_X') 'dest from outbox' $r.dest
Assert-True ($r.source -ne 'none') 'structured source used' "$($r.source)"

# ── 1) CONFIG_ERROR: invalid destination session-id ──
Write-Host "== T-diagnose: CONFIG_ERROR (bad session-id) =="
New-Fixture -Dest 'not-a-session'
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile
Assert-True ($r.classification -eq 'CONFIG_ERROR') 'CONFIG_ERROR for bad ses id' "$($r.classification)"
Assert-True ($r.source -eq 'local-validation') 'source=local-validation' "$($r.source)"

# ── 1b) CONFIG_ERROR: missing token in outbox entry ──
New-Fixture -Token ''
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile `
        -HealthFn { $true } -SessionFn { param($id) @{ ok = $true; status = 'busy'; last_activity_at = ''; checkable = $true } }
Assert-True ($r.classification -eq 'CONFIG_ERROR') 'CONFIG_ERROR for missing token' "$($r.classification)"

# ── 2) PROVIDER_DOWN: health unhealthy ──
Write-Host "== T-diagnose: PROVIDER_DOWN =="
New-Fixture
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile `
        -HealthFn { $false } -SessionFn { param($id) @{ ok = $true; status = 'busy'; last_activity_at = ''; checkable = $true } }
Assert-True ($r.classification -eq 'PROVIDER_DOWN') 'PROVIDER_DOWN via health' "$($r.classification)"
Assert-True ($r.source -eq 'api-health') 'source=api-health' "$($r.source)"

# ── 3) AGENT_SLEEPING: status idle ──
Write-Host "== T-diagnose: AGENT_SLEEPING =="
New-Fixture
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile `
        -HealthFn { $true } -SessionFn { param($id) @{ ok = $true; status = 'idle'; last_activity_at = ''; checkable = $true } }
Assert-True ($r.classification -eq 'AGENT_SLEEPING') 'AGENT_SLEEPING via status=idle' "$($r.classification)"
Assert-True ($r.source -eq 'api-session-state') 'source=api-session-state' "$($r.source)"

# ── 3b) AGENT_SLEEPING: stale lastActivityAt beyond threshold ──
New-Fixture
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile -SleepThresholdSec 300 `
        -HealthFn { $true } -SessionFn { param($id) @{ ok = $true; status = 'busy'; last_activity_at = $oldIso; checkable = $true } }
Assert-True ($r.classification -eq 'AGENT_SLEEPING') 'AGENT_SLEEPING via stale lastActivityAt' "$($r.classification)|$($r.idle_seconds)"

# ── 4) NO_ERROR fallback: healthy + active destination, no signal ──
Write-Host "== T-diagnose: NO_ERROR fallback =="
New-Fixture
$r = Get-CrossDiagnose -Msg 'msg_diag' -OutboxPath $script:OutboxFile `
        -HealthFn { $true } -SessionFn { param($id) @{ ok = $true; status = 'busy'; last_activity_at = $recentIso; checkable = $true } }
Assert-True ($r.classification -eq 'NO_ERROR') 'NO_ERROR when healthy+active' "$($r.classification)"

# ── 5) usage error ──
New-Fixture
$r = Get-CrossDiagnose -Msg '' -OutboxPath $script:OutboxFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'missing --msg rejected' "$($r.err)"

# ── 6) Get-CrossSessionState contract (mocked HTTP layer) ──
Write-Host "== T-diagnose: Get-CrossSessionState =="
$st = Get-CrossSessionState -Id 'ses_ZZZ' -SessionFn { param($id) @{ ok = $true; status = 'busy'; last_activity_at = $recentIso; model = 'm'; checkable = $true } }
Assert-True ($st.ok -and $st.status -eq 'busy' -and $st.model -eq 'm') 'state mock passthrough' "$($st.ok)|$($st.status)"
$st2 = Get-CrossSessionState -Id 'ses_ZZZ' -SessionFn { param($id) @{ ok = $false; status_code = 404; status = ''; last_activity_at = ''; checkable = $false } }
Assert-True (-not $st2.ok -and -not $st2.checkable) 'state 404 -> not checkable' "$($st2.ok)"

# -- 7) deprecation warning present on Get-CrossPortFromLog (stderr diag stream) --
Write-Host "== T-diagnose: port-from-log deprecated =="
# stderr bajo EAP=Stop no debe matar el test; y el hijo necesita ruta absoluta
$modPath = Join-Path $PSScriptRoot '..\modules\cross-transport.psm1'
$prevEap = $ErrorActionPreference
$prevDiag = $env:CROSS_DIAG
$env:CROSS_DIAG = 'info'
$ErrorActionPreference = 'Continue'
$child = powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '$modPath' -Force -DisableNameChecking; `$null = Get-CrossPortFromLog" 2>&1 | Out-String
$ErrorActionPreference = $prevEap
if ($null -ne $prevDiag) { $env:CROSS_DIAG = $prevDiag } else { Remove-Item Env:\CROSS_DIAG -ErrorAction SilentlyContinue }
$warned = $child -match 'DEPRECATED: Get-CrossPortFromLog scrapes main\.log and will be removed in v1\.18'
Assert-True $warned 'port-from-log emits v1.18 deprecation warning' ''

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }