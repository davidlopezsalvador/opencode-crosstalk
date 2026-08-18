# T-whoami.ps1 - Tests del subcomando whoami (fix F3: identidad real por config/override).
# Verifica que whoami reporte la identidad correcta: config compartida (shared_config),
# overrides explicitos (--session-id/--model/--role) y error NO_IDENTITY sin config.
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '..\cross.ps1'

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

function Invoke-CrossCli {
    param([string[]]$Args2)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli @Args2 2>$null | Out-String
}

function Get-TmpConfig {
    param([string]$Dir, [string]$Sid, [string]$Lider, [string]$Model, [string]$Role)
    $cfg = [ordered]@{
        my_session_id = $Sid
        lider_session_id = $Lider
        my_model = $Model
        my_role = $Role
        whiteboard_dir = (Join-Path $Dir 'whiteboard')
        diario_dir = (Join-Path $Dir 'diario')
        log_path = "$env:TEMP\opencode\opencode.log"
        desktop_logs_dir = "$env:APPDATA\ai.opencode.desktop\logs"
        default_ack_timeout_s = 120
        default_lease_minutes = 3
        max_retries = 2
        protocol_version = '1.6.1'
    }
    $p = Join-Path $Dir 'config.json'
    [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

$tmp = Join-Path $env:TEMP ('cross_twhoami_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

Write-Host "== T-whoami: config compartida (my_session_id == lider) =="
$cfgShared = Get-TmpConfig $tmp 'ses_lider_abc' 'ses_lider_abc' 'leader-model' 'lider'
$raw = Invoke-CrossCli @('whoami', "--config=$cfgShared")
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok) 'whoami con config -> ok' $raw
Assert-True ($null -ne $j -and $j.session_id -eq 'ses_lider_abc') 'session_id de config' "$($j.session_id)"
Assert-True ($null -ne $j -and $j.model -eq 'leader-model') 'model de config' "$($j.model)"
Assert-True ($null -ne $j -and $j.role -eq 'lider') 'role de config' "$($j.role)"
Assert-True ($null -ne $j -and $j.identity_source -eq 'config') 'identity_source=config' "$($j.identity_source)"
Assert-True ($null -ne $j -and $j.shared_config) 'shared_config=true cuando my_session_id==lider' ''

Write-Host "== T-whoami: override completo (identidad del asesor) =="
$raw = Invoke-CrossCli @('whoami', "--config=$cfgShared", '--session-id=ses_asesor_xyz', '--model=model-a', '--role=asesor')
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok) 'whoami con override -> ok' $raw
Assert-True ($null -ne $j -and $j.session_id -eq 'ses_asesor_xyz') 'override session_id' "$($j.session_id)"
Assert-True ($null -ne $j -and $j.model -eq 'model-a') 'override model' "$($j.model)"
Assert-True ($null -ne $j -and $j.role -eq 'asesor') 'override role' "$($j.role)"
Assert-True ($null -ne $j -and $j.identity_source -eq 'override') 'identity_source=override' "$($j.identity_source)"
Assert-True ($null -ne $j -and -not $j.shared_config) 'override -> shared_config=false' ''

Write-Host "== T-whoami: override parcial (solo session-id hereda model/role) =="
$raw = Invoke-CrossCli @('whoami', "--config=$cfgShared", '--session-id=ses_asesor_xyz')
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok -and $j.session_id -eq 'ses_asesor_xyz' -and $j.identity_source -eq 'override') 'override parcial -> session_id del override' "$($j.session_id)|$($j.identity_source)"
Assert-True ($null -ne $j -and $j.model -eq 'leader-model' -and $j.role -eq 'lider') 'override parcial -> hereda model/role de config' "$($j.model)|$($j.role)"

Write-Host "== T-whoami: config propia (my_session_id != lider) no es shared =="
$cfgPropia = Get-TmpConfig $tmp 'ses_asesor_xyz' 'ses_lider_abc' 'model-b' 'asesor'
$raw = Invoke-CrossCli @('whoami', "--config=$cfgPropia")
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok -and $j.session_id -eq 'ses_asesor_xyz' -and $j.identity_source -eq 'config') 'whoami config propia -> ok' $raw
Assert-True ($null -ne $j -and -not $j.shared_config) 'config propia -> shared_config=false' ''

Write-Host "== T-whoami: NO_IDENTITY sin config =="
$cfgVacia = Get-TmpConfig $tmp '' '' '' ''
$raw = Invoke-CrossCli @('whoami', "--config=$cfgVacia")
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and -not $j.ok -and $j.err -eq 'NO_IDENTITY') 'sin identidad -> NO_IDENTITY' $raw

Write-Host ""
Write-Host ("RESULTADO: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }