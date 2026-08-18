Set-StrictMode -Version 2.0

if (-not (Get-Command Get-CrossConfig -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-transport.psm1') -Force -DisableNameChecking
}

function Get-StateTimestamp {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-IdempotenciaPath {
    $cfg = Get-CrossConfig
    $dir = if ($cfg.whiteboard_dir) { [Environment]::ExpandEnvironmentVariables([string]$cfg.whiteboard_dir) } else { '' }
    return Join-Path $dir 'idempotencia-procesados.md'
}

function Get-OutboxPath {
    $cfg = Get-CrossConfig
    $dir = if ($cfg.whiteboard_dir) { [Environment]::ExpandEnvironmentVariables([string]$cfg.whiteboard_dir) } else { '' }
    return Join-Path $dir 'outbox.md'
}

function Get-OutboxMutex {
    param([Parameter(Mandatory=$true)][string]$Path)
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Path))).Replace('-', '').Substring(0, 24)
    return New-Object System.Threading.Mutex($false, "Global\CrossOutbox_$hash")
}

function Read-IdempotenciaLog {
    param([string]$Path = '')
    if (-not $Path) { $Path = Get-IdempotenciaPath }
    $records = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return @($records) }
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^#+') { $section = ($trimmed -replace '^#+\s*', ''); continue }
        $m = [regex]::Match($trimmed, '^(.+?) \| (.+?) \| ([^|]*) \| (.+?)$')
        if (-not $m.Success) { continue }
        $state = $m.Groups[4].Value
        if ($state -notmatch '^(CLAIMED_BY=|PROCESADO$|SUPERSEDED_BY=)') { continue }
        [void]$records.Add([ordered]@{
            msg_id    = $m.Groups[1].Value.Trim()
            timestamp = $m.Groups[2].Value.Trim()
            modelo    = $m.Groups[3].Value.Trim()
            state     = $state
            section   = $section
        })
    }
    return @($records)
}

function Get-MsgState {
    param([string]$MsgId, [string]$Path = '')
    if (-not $Path) { $Path = Get-IdempotenciaPath }
    $records = @(Read-IdempotenciaLog -Path $Path | Where-Object { $_.msg_id -eq $MsgId })
    if ($records.Count -eq 0) { return $null }
    return $records[$records.Count - 1]
}

function Add-IdempotenciaLine {
    param(
        [string]$MsgId,
        [string]$Timestamp,
        [string]$Modelo,
        [string]$State,
        [string]$Path = ''
    )
    if (-not $Path) { $Path = Get-IdempotenciaPath }
    $line = "$MsgId | $Timestamp | $Modelo | $State"
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.File]::WriteAllText($Path, '', (New-Object System.Text.UTF8Encoding($false)))
    }
    [System.IO.File]::AppendAllText($Path, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return $line
}

function New-CrossClaim {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$Modelo,
        [string]$Owner,
        [string]$Path = ''
    )
    if (-not $Path) { $Path = Get-IdempotenciaPath }
    if (-not $Owner) { return @{ ok = $false; err = 'NO_OWNER'; detail = '--owner o config.my_session_id requerido' } }
    $last = Get-MsgState -MsgId $MsgId -Path $Path
    if ($null -ne $last) {
        if ($last.state -match '^CLAIMED_BY=(.+)$') {
            $claimedBy = $Matches[1]
            if ($claimedBy -eq $Owner) { return @{ ok = $true; already = $true; detail = "ya reclamado por $Owner" } }
            return @{ ok = $false; err = 'ALREADY_CLAIMED_BY_OTHER'; detail = "msg_id $MsgId ya reclamado por $claimedBy" }
        }
        if ($last.state -eq 'PROCESADO') { return @{ ok = $true; already = $true; detail = 'ya procesado' } }
    }
    $ts = Get-StateTimestamp
    [void](Add-IdempotenciaLine -MsgId $MsgId -Timestamp $ts -Modelo $Modelo -State "CLAIMED_BY=$Owner" -Path $Path)
    return @{ ok = $true; already = $false }
}

function New-CrossRelease {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$Modelo,
        [string]$Owner,
        [switch]$Force,
        [string]$Path = ''
    )
    if (-not $Path) { $Path = Get-IdempotenciaPath }
    if (-not $Owner) { return @{ ok = $false; err = 'NO_OWNER'; detail = '--owner o config.my_session_id requerido' } }
    $last = Get-MsgState -MsgId $MsgId -Path $Path
    if ($null -eq $last) { return @{ ok = $false; err = 'NOT_CLAIMED'; detail = "no hay claim previo para $MsgId" } }
    if ($last.state -match '^SUPERSEDED_BY=') { return @{ ok = $true; already = $true; detail = 'ya liberado' } }
    if ($last.state -eq 'PROCESADO') { return @{ ok = $false; err = 'ALREADY_PROCESSED'; detail = "msg_id $MsgId ya esta PROCESADO, no se puede liberar" } }
    if ($last.state -match '^CLAIMED_BY=(.+)$') {
        $claimedBy = $Matches[1]
        if (-not $Force -and $claimedBy -ne $Owner) {
            return @{ ok = $false; err = 'NOT_OWNER'; detail = "reclamado por $claimedBy; usar --force para liberar" }
        }
    }
    $ts = Get-StateTimestamp
    [void](Add-IdempotenciaLine -MsgId $MsgId -Timestamp $ts -Modelo $Modelo -State "SUPERSEDED_BY=$Owner" -Path $Path)
    return @{ ok = $true; already = $false }
}

function New-CrossDone {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$Modelo,
        [string]$Owner,
        [string]$Path = ''
    )
    if (-not $Path) { $Path = Get-IdempotenciaPath }
    if (-not $Owner) { return @{ ok = $false; err = 'NO_OWNER'; detail = '--owner o config.my_session_id requerido' } }
    $last = Get-MsgState -MsgId $MsgId -Path $Path
    if ($null -eq $last) { return @{ ok = $false; err = 'NOT_CLAIMED'; detail = "no hay claim previo para $MsgId" } }
    if ($last.state -eq 'PROCESADO') { return @{ ok = $true; already = $true; detail = 'ya procesado' } }
    if ($last.state -match '^SUPERSEDED_BY=') {
        return @{ ok = $false; err = 'RELEASED_CANNOT_DONE'; detail = "msg_id $MsgId fue liberado (SUPERSEDED_BY), no puede marcarse PROCESADO" }
    }
    if ($last.state -match '^CLAIMED_BY=(.+)$') {
        $claimedBy = $Matches[1]
        if ($claimedBy -ne $Owner) { return @{ ok = $false; err = 'NOT_OWNER'; detail = "reclamado por $claimedBy, no por $Owner" } }
    }
    $ts = Get-StateTimestamp
    [void](Add-IdempotenciaLine -MsgId $MsgId -Timestamp $ts -Modelo $Modelo -State 'PROCESADO' -Path $Path)
    return @{ ok = $true; already = $false }
}

function Read-OutboxLog {
    param([string]$Path = '')
    if (-not $Path) { $Path = Get-OutboxPath }
    $entries = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return @($entries) }
    $section = ''
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match '^#+') { $section = ($trimmed -replace '^#+\s*', ''); continue }
        if ($section -notmatch 'Activo') { continue }
        if ($trimmed -match '^\|') { continue }
        $m = [regex]::Match($trimmed, '^\[([^\]]+)\]\s*OUTBOX\s*\|\s*([^\s|]+)(.*)$')
        if (-not $m.Success) {
            [void]$entries.Add([ordered]@{ msg_id = ''; lease = ''; estado = ''; raw = $trimmed; malformed = $true })
            continue
        }
        $estado = ''
        $estM = [regex]::Match($m.Groups[3].Value, 'ESTADO=(\S+)')
        if ($estM.Success) { $estado = $estM.Groups[1].Value }
        $lease = ''
        $leaseM = [regex]::Match($m.Groups[3].Value, 'lease=([^\s|]+)')
        if ($leaseM.Success) { $lease = $leaseM.Groups[1].Value }
        $dest = ''
        $destM = [regex]::Match($m.Groups[3].Value, 'dest=([^\s|]+)')
        if ($destM.Success) { $dest = $destM.Groups[1].Value }
        $runId = ''
        $runM = [regex]::Match($m.Groups[3].Value, 'run_id=([^\s|]+)')
        if ($runM.Success) { $runId = $runM.Groups[1].Value }
        $token = ''
        $tokM = [regex]::Match($m.Groups[3].Value, 'token=([^\s|]+)')
        if ($tokM.Success) { $token = $tokM.Groups[1].Value }
        $reqAck = ''
        $ackM = [regex]::Match($m.Groups[3].Value, 'requiere_ack=(\S+)')
        if ($ackM.Success) { $reqAck = $ackM.Groups[1].Value }
        $sucesor = ''
        $sucM = [regex]::Match($m.Groups[3].Value, 'sucesor=([^\s|]+)')
        if ($sucM.Success) { $sucesor = $sucM.Groups[1].Value }
        $attempt = 0
        $attM = [regex]::Match($m.Groups[3].Value, 'attempt=(\d+)')
        if ($attM.Success) { $attempt = [int]$attM.Groups[1].Value }
        [void]$entries.Add([ordered]@{
            msg_id        = $m.Groups[2].Value
            lease         = $lease
            estado        = $estado
            dest          = $dest
            run_id        = $runId
            token         = $token
            requiere_ack  = $reqAck
            sucesor       = $sucesor
            attempt       = $attempt
            raw           = $trimmed
            malformed     = $false
        })
    }
    return @($entries)
}

function Get-OutboxEntry {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$Path = ''
    )
    if (-not $Path) { $Path = Get-OutboxPath }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $mutex = Get-OutboxMutex -Path $Path
    $locked = $false
    try {
        $locked = $mutex.WaitOne(30000)
        if (-not $locked) { return $null }
        $entry = @(Read-OutboxLog -Path $Path) | Where-Object { $_.msg_id -eq $MsgId } | Select-Object -First 1
        return $entry
    } catch {
        return $null
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
    }
}

function Test-CrossConsistency {
    param([string]$StatePath = '', [string]$OutboxPath = '')
    if (-not $StatePath) { $StatePath = Get-IdempotenciaPath }
    if (-not $OutboxPath) { $OutboxPath = Get-OutboxPath }
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    if (Test-Path -LiteralPath $StatePath) {
        $section = ''
        foreach ($line in (Get-Content -LiteralPath $StatePath)) {
            $trimmed = $line.Trim()
            if (-not $trimmed) { continue }
            if ($trimmed -match '^#+') { $section = ($trimmed -replace '^#+\s*', ''); continue }
            if ($section -notmatch 'Activo') { continue }
        $m = [regex]::Match($trimmed, '^(.+?) \| (.+?) \| ([^|]*) \| (.+?)$')
            if (-not $m.Success) {
                [void]$warnings.Add("linea no v1.6.1 en seccion Activo: $trimmed")
            } else {
                $state = $m.Groups[4].Value
                if ($state -notmatch '^(CLAIMED_BY=|PROCESADO$|SUPERSEDED_BY=)') {
                    [void]$warnings.Add("estado no v1.6.1 en seccion Activo: $state")
                }
            }
        }
    }

    $outboxEntries = @(Read-OutboxLog -Path $OutboxPath)
    foreach ($e in $outboxEntries) {
        if ($e.malformed) { [void]$warnings.Add("linea outbox no v1.6 en Activo: $($e.raw)") }
        if ($e.lease -and $e.lease -notmatch '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}') {
            [void]$warnings.Add("lease sin deadline UTC en outbox (msg $($e.msg_id)): $($e.lease)")
        }
    }
    $seen = @{}
    foreach ($e in $outboxEntries) {
        if (-not $e.msg_id) { continue }
        if ($seen.ContainsKey($e.msg_id)) { $seen[$e.msg_id] = $seen[$e.msg_id] + 1 }
        else { $seen[$e.msg_id] = 1 }
    }
    foreach ($k in $seen.Keys) {
        if ($seen[$k] -gt 1) {
            [void]$warnings.Add("msg_id duplicado en outbox Activo: $k ($($seen[$k]) lineas)")
        }
    }

    $processed = @(Read-IdempotenciaLog -Path $StatePath | Where-Object { $_.state -eq 'PROCESADO' })
    foreach ($rec in $processed) {
        $entry = $outboxEntries | Where-Object { $_.msg_id -eq $rec.msg_id } | Select-Object -First 1
        if ($null -eq $entry) { continue }
        if ($entry.estado -ne 'CONFIRMADO') {
            [void]$errors.Add("PROCESADO sin CONFIRMADO en outbox: $($rec.msg_id) (outbox=$($entry.estado))")
        }
    }

    return @{
        ok       = ($errors.Count -eq 0)
        warnings = @($warnings)
        errors   = @($errors)
    }
}

function Set-OutboxEstado {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [Parameter(Mandatory=$true)][string]$Estado,
        [string]$Path = ''
    )
    if (-not $Path) { $Path = Get-OutboxPath }
    $entry = Get-OutboxEntry -MsgId $MsgId -Path $Path
    if (-not $entry) { return @{ ok = $false; err = 'OUTBOX_MSG_NOT_FOUND'; detail = $MsgId } }
    $new = [regex]::Replace($entry.raw, 'ESTADO=\S+', "ESTADO=$Estado")
    return Update-OutboxLine -MsgId $MsgId -NewContent $new -Path $Path
}

function Renew-CrossLease {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$Path = '',
        [int]$Minutes = 3
    )
    if (-not $Path) { $Path = Get-OutboxPath }
    $entry = Get-OutboxEntry -MsgId $MsgId -Path $Path
    if (-not $entry) { return @{ ok = $false; err = 'OUTBOX_MSG_NOT_FOUND'; detail = $MsgId } }
    $owner = ''
    if ($entry.lease -match '^([^@]+)@') { $owner = $Matches[1] }
    if (-not $owner) { $owner = 'lider' }
    $deadline = (Get-Date).ToUniversalTime().AddMinutes($Minutes).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $newLease = "$owner@$deadline"
    $new = [regex]::Replace($entry.raw, 'lease=[^\s|]+', "lease=$newLease")
    return Update-OutboxLine -MsgId $MsgId -NewContent $new -Path $Path
}

function Set-OutboxAttempt {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [Parameter(Mandatory=$true)][int]$Attempt,
        [string]$Path = ''
    )
    if (-not $Path) { $Path = Get-OutboxPath }
    $entry = Get-OutboxEntry -MsgId $MsgId -Path $Path
    if (-not $entry) { return @{ ok = $false; err = 'OUTBOX_MSG_NOT_FOUND'; detail = $MsgId } }
    $raw = $entry.raw
    if ($raw -match 'attempt=\d+') {
        $new = [regex]::Replace($raw, 'attempt=\d+', "attempt=$Attempt")
    } elseif ($raw -match '(\|\s*ESTADO=\S+)') {
        $new = [regex]::Replace($raw, '(\|\s*ESTADO=\S+)', "| attempt=$Attempt `$1")
    } else {
        $new = $raw + " | attempt=$Attempt"
    }
    return Update-OutboxLine -MsgId $MsgId -NewContent $new -Path $Path
}

function Invoke-CrossAutoSweep {
    param(
        [string]$Path = '',
        [string]$AuditPath = '',
        [int]$LeaseMinutes = 0,
        [string]$ExcludeMsgId = '',
        [switch]$Apply,
        [switch]$DryRun
    )
    if (-not $Path) { $Path = Get-OutboxPath }
    $pending = @(Find-CrossOutboxPending -Path $Path)
    $vencidos = @($pending | Where-Object { $_.vencido })
    if ($LeaseMinutes -le 0) {
        $cfg = Get-CrossConfig
        $LeaseMinutes = if ($cfg.default_lease_minutes) { [int]$cfg.default_lease_minutes } else { 3 }
    }
    $swept = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.ArrayList
    foreach ($e in $vencidos) {
        if ($ExcludeMsgId -and $e.msg_id -eq $ExcludeMsgId) { continue }
        $set = Set-OutboxEstado -MsgId $e.msg_id -Estado 'EXPIRADO' -Path $Path
        if ($set.ok) {
            [void]$swept.Add($e.msg_id)
            if ($Apply -or -not $DryRun) {
                [void](Write-AuditEntry -MsgId $e.msg_id -Dest $e.dest -Token ([string]$e.token) -Tipo 'SCAN' -Estado 'EXPIRADO' -Nota "auto-sweep: lease vencida sin ACK; marcado EXPIRADO" -AuditPath $AuditPath)
            }
        } else {
            [void]$failed.Add([ordered]@{ msg_id = $e.msg_id; err = $set.err })
        }
    }
    return @{
        ok = $true
        vencidos = $vencidos.Count
        swept = @($swept)
        failed = @($failed)
        dry_run = ($DryRun -and -not $Apply)
    }
}

function Update-OutboxLine {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [Parameter(Mandatory=$true)][string]$NewContent,
        [string]$Path = '',
        [int]$MaxRetries = 3,
        [int[]]$BackoffMs = @(200, 400, 800)
    )
    if (-not $Path) { $Path = Get-OutboxPath }
    if (-not (Test-Path -LiteralPath $Path)) { return @{ ok = $false; err = 'OUTBOX_NOT_FOUND'; detail = $Path } }
    $mutex = Get-OutboxMutex -Path $Path
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        $locked = $false
        try {
            $locked = $mutex.WaitOne(30000)
            if (-not $locked) { break }
            $lines = @(Get-Content -LiteralPath $Path)
            $found = $false
            $linePattern = 'OUTBOX \| ' + [regex]::Escape($MsgId) + ' \|'
            for ($j = 0; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match $linePattern) {
                    $lines[$j] = $NewContent
                    $found = $true
                    break
                }
            }
            if (-not $found) { return @{ ok = $false; err = 'OUTBOX_MSG_NOT_FOUND'; detail = $MsgId } }
            [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($false)))
            $after = Get-Content -LiteralPath $Path -Raw
            if ($after -match [regex]::Escape($NewContent)) {
                return @{ ok = $true; msg_id = $MsgId }
            }
        } catch {
            # IOException (archivo en uso por otro proceso): reintentar con backoff
        } finally {
            if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        }
        if (($i + 1) -lt $MaxRetries) { Start-Sleep -Milliseconds $BackoffMs[$i] }
    }
    return @{ ok = $false; err = 'OUTBOX_LOCKED'; detail = 'no se pudo actualizar la linea tras reintentos (backoff 200/400/800ms)' }
}

function Add-OutboxEntry {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$Dest = '',
        [string]$RunId = '',
        [string]$Token = '',
        [string]$Lease = '',
        [string]$Sucesor = '',
        [string]$Estado = 'EN_VUELO',
        [string]$Path = '',
        [int]$MaxRetries = 5,
        [int[]]$BackoffMs = @(100, 200, 400, 800, 1200)
    )
    if (-not $Path) { $Path = Get-OutboxPath }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.File]::WriteAllText($Path, "# OUTBOX`n## Activo (formato v1.6)`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "[$ts] OUTBOX | $MsgId | dest=$Dest | run_id=$RunId | token=$Token | lease=$Lease"
    if ($Sucesor) { $line += "|sucesor=$Sucesor" }
    $line += " | ESTADO=$Estado"
    $needle = 'OUTBOX \| ' + [regex]::Escape($MsgId) + ' \|'
    $mutex = Get-OutboxMutex -Path $Path
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        $locked = $false
        try {
            $locked = $mutex.WaitOne(30000)
            if (-not $locked) { break }
            $content = [System.IO.File]::ReadAllLines($Path)
            $idx = -1
            for ($j = 0; $j -lt $content.Count; $j++) {
                if ($content[$j] -match '^##\s*Activo') { $idx = $j; break }
            }
            if ($idx -lt 0) {
                return @{ ok = $false; err = 'OUTBOX_SIN_ACTIVO'; detail = "sin seccion '## Activo' en $Path" }
            }
            if (@($content | Where-Object { $_ -match $needle }).Count -gt 0) {
                return @{ ok = $true; already = $true; msg_id = $MsgId }
            }
            $newContent = New-Object System.Collections.ArrayList
            for ($j = 0; $j -lt $content.Count; $j++) {
                [void]$newContent.Add($content[$j])
                if ($j -eq $idx) { [void]$newContent.Add($line) }
            }
            [System.IO.File]::WriteAllLines($Path, @($newContent), (New-Object System.Text.UTF8Encoding($false)))
            $after = Get-Content -LiteralPath $Path -Raw
            if ($after -match [regex]::Escape($line)) {
                return @{ ok = $true; msg_id = $MsgId; line = $line }
            }
        } catch [System.IO.IOException] {
            # archivo en uso por otro proceso: reintentar con backoff
        } catch [System.Threading.AbandonedMutexException] {
            # mutex abandonado por un proceso que murio: lo hemos adquirido
        } catch {
            return @{ ok = $false; err = 'OUTBOX_WRITE_ERROR'; detail = $_.Exception.Message }
        } finally {
            if ($locked) { try { $mutex.ReleaseMutex() } catch { } }
        }
        if (($i + 1) -lt $MaxRetries) { Start-Sleep -Milliseconds $BackoffMs[$i] }
    }
    return @{ ok = $false; err = 'OUTBOX_LOCKED'; detail = 'no se pudo insertar la linea tras reintentos (backoff 100..1200ms)' }
}

function Add-CrossLogLine {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Line,
        [int]$MaxRetries = 3,
        [int[]]$BackoffMs = @(200, 400, 800)
    )
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    for ($i = 0; $i -lt $MaxRetries; $i++) {
        try {
            [System.IO.File]::AppendAllText($Path, $Line + "`n", (New-Object System.Text.UTF8Encoding($false)))
            return @{ ok = $true; path = $Path }
        } catch [System.IO.IOException] {
            if (($i + 1) -lt $MaxRetries) { Start-Sleep -Milliseconds $BackoffMs[$i] }
        } catch {
            return @{ ok = $false; err = 'LOG_WRITE_ERROR'; detail = $_.Exception.Message }
        }
    }
    return @{ ok = $false; err = 'LOG_LOCKED'; detail = 'no se pudo anexar la linea tras reintentos (backoff 200/400/800ms)' }
}

function Write-AuditEntry {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$Dest = '',
        [string]$Token = '',
        [string]$Tipo = 'ENV',
        [string]$Estado = '',
        [string]$Nota = '',
        [string]$Origen = '',
        [string]$AuditPath = ''
    )
    $cfg = Get-CrossConfig
    if (-not $Origen) { $Origen = if ($cfg.my_session_id) { [string]$cfg.my_session_id } else { 'lider' } }
    $dir = if ($cfg.whiteboard_dir) { [Environment]::ExpandEnvironmentVariables([string]$cfg.whiteboard_dir) } else { Split-Path -Parent (Get-OutboxPath) }
    if (-not $AuditPath) { $AuditPath = Join-Path $dir 'audit_log.md' }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $notaLine = "msg=$MsgId"
    if ($Nota) { $notaLine += "; $Nota" }
    $row = "| $ts | $Origen | $Dest | $Token | $Tipo | $Estado | $notaLine |"
    return Add-CrossLogLine -Path $AuditPath -Line $row
}

Export-ModuleMember -Function Get-StateTimestamp, Get-IdempotenciaPath, Get-OutboxPath, Read-IdempotenciaLog, Get-MsgState, Add-IdempotenciaLine, New-CrossClaim, New-CrossRelease, New-CrossDone, Read-OutboxLog, Get-OutboxEntry, Test-CrossConsistency, Update-OutboxLine, Set-OutboxEstado, Renew-CrossLease, Set-OutboxAttempt, Add-OutboxEntry, Add-CrossLogLine, Write-AuditEntry, Invoke-CrossAutoSweep