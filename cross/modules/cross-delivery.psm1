Set-StrictMode -Version 2.0

if (-not (Get-Command ConvertTo-AsciiSafe -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\lib\cross-format.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Get-CrossConfig -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-transport.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Read-OutboxLog -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-state.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Parse-CrossEnvelope -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-envelope.psm1') -Force -DisableNameChecking
}

function Format-CrossEnvelope {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$RunId = '',
        [string]$Token = '',
        [bool]$RequiereAck = $true,
        [string]$Lease = '',
        [string]$Sucesor = '',
        [string]$Timestamp = ''
    )
    if (-not $Timestamp) { $Timestamp = ConvertTo-Iso8601Utc }
    $parts = @("msg_id=$MsgId")
    if ($RunId) { $parts += "run_id=$RunId" }
    if ($Token) { $parts += "token=$Token" }
    $parts += "requiere_ack=$($RequiereAck.ToString().ToLower())"
    if ($Lease) { $parts += "lease=$Lease" }
    if ($Sucesor) { $parts += "sucesor=$Sucesor" }
    $parts += "timestamp=$Timestamp"
    return "[$($parts -join ' | ')]"
}

function Parse-CrossAckText {
    param([AllowEmptyString()][string]$Text = '')
    $result = @{ ack = $false; nack = $false; protocolo = $false; token = ''; emisor = ''; modelo = ''; razon = ''; msg_id = ''; run_id = ''; raw = $Text }
    if (-not $Text) { return $result }
    # v2 primero (sobre JSON estructurado, Fase 1 v1.9): si el texto trae un
    # envelope v2 valido (ENVELOPE-V2: {json} o JSON puro), prevalece sobre v1.
    $v2 = Parse-CrossEnvelope -Text $Text
    if ($v2.valid) {
        if ($v2.type -eq 'ack') {
            $result.ack = $true
            $result.token = $v2.token
            $result.emisor = $v2.emitter
            $result.modelo = $v2.model
            $result.msg_id = $v2.msg_id
            $result.run_id = $v2.run_id
        } elseif ($v2.type -eq 'nack') {
            $result.nack = $true
            $result.token = $v2.token
            $result.emisor = $v2.emitter
            $result.modelo = $v2.model
            $result.razon = $v2.reason
            $result.msg_id = $v2.msg_id
            $result.run_id = $v2.run_id
        }
        return $result
    }
    $m = [regex]::Match($Text, '(?<!\S)NACK-PROTOCOLO:([^\s]+)')
    if ($m.Success) {
        $result.protocolo = $true
        $result.razon = 'NACK-PROTOCOLO'
        $result.token = $m.Groups[1].Value
        return $result
    }
    $m = [regex]::Match($Text, '(?<!\S)ACK-PROTOCOLO:([0-9A-Za-z\.\-]+)')
    if ($m.Success) {
        $result.protocolo = $true
        $result.token = $m.Groups[1].Value
        return $result
    }
    $m = [regex]::Match($Text, '(?<!\S)NACK:([^\s]+)')
    if ($m.Success) {
        $result.nack = $true
        $segs = @($m.Groups[1].Value -split ':')
        if ($segs.Count -eq 6) {
            # Formato enriquecido v0.2 (Hallazgo #4): NACK:<token>:<id>:<modelo>:<razon>:<msg_id>:<run_id>
            $result.token = $segs[0]
            $result.emisor = $segs[1]
            $result.modelo = $segs[2]
            $result.razon = $segs[3]
            $result.msg_id = $segs[4]
            $result.run_id = $segs[5]
        } elseif ($segs.Count -ge 4) {
            $result.razon = $segs[$segs.Count - 1]
            $result.modelo = $segs[$segs.Count - 2]
            $result.emisor = $segs[$segs.Count - 3]
            $result.token = ($segs[0..($segs.Count - 4)] -join ':')
        } elseif ($segs.Count -eq 3) {
            $result.razon = $segs[2]
            $result.emisor = $segs[1]
            $result.token = $segs[0]
        } elseif ($segs.Count -eq 2) {
            $result.emisor = $segs[1]
            $result.token = $segs[0]
        } else {
            $result.token = $segs[0]
        }
        return $result
    }
    $m = [regex]::Match($Text, '(?<!\S)ACK:([^\s]+)')
    if ($m.Success) {
        $result.ack = $true
        $segs = @($m.Groups[1].Value -split ':')
        if ($segs.Count -ge 3) {
            $result.modelo = $segs[$segs.Count - 1]
            $result.emisor = $segs[$segs.Count - 2]
            $result.token = ($segs[0..($segs.Count - 3)] -join ':')
        } elseif ($segs.Count -eq 2) {
            $result.emisor = $segs[1]
            $result.token = $segs[0]
        } else {
            $result.token = $segs[0]
        }
    } elseif ([regex]::Match($Text, '(?<=:|\s)ACK:([^\s]+)').Success) {
        # E1 (2026-08-13): ACK precedido de ':' (p.ej. 'TAREA-E2E:ACK:ses_X:m') se cuenta como ACK.
        $result.ack = $true
        $m = [regex]::Match($Text, '(?<=:|\s)ACK:([^\s]+)')
        $segs = @($m.Groups[1].Value -split ':')
        if ($segs.Count -ge 3) {
            $result.modelo = $segs[$segs.Count - 1]
            $result.emisor = $segs[$segs.Count - 2]
            $result.token = ($segs[0..($segs.Count - 3)] -join ':')
        } elseif ($segs.Count -eq 2) {
            $result.emisor = $segs[1]
            $result.token = $segs[0]
        } else {
            $result.token = $segs[0]
        }
    }
    # E1 (2026-08-13): si el texto declara un MSG-token explicito (TOKEN:MSG-...,
    # 'token MSG-...' o desnudo) prevalece el MSG-token; si no habia ACK explicito,
    # la declaracion TOKEN:MSG-... cuenta como ACK (variante E2E real).
    $tokM = [regex]::Match($Text, '(?:TOKEN|Token|token)\s*[:=]\s*(MSG-[0-9A-Za-z\.\-]+)')
    if (-not $tokM.Success) { $tokM = [regex]::Match($Text, '(?:token|TOKEN)\s+(MSG-[0-9A-Za-z\.\-]+)') }
    if (-not $tokM.Success) { $tokM = [regex]::Match($Text, '(?<!\S)(MSG-[0-9A-Za-z\.\-]{6,})(?=\s|$|[,;:)])') }
    if ($tokM.Success) {
        $tok = $tokM.Groups[1].Value
        if (-not $result.ack -and -not $result.nack) { $result.ack = $true }
        if ($result.ack) {
            $rest = $Text.Substring($tokM.Groups[1].Index + $tok.Length)
            $m2 = [regex]::Match($rest, '^\s*:\s*([^\s:]+)\s*(?::\s*([^\s:]+))?')
            if ($m2.Success) {
                if (-not $result.emisor) { $result.emisor = $m2.Groups[1].Value }
                if (-not $result.modelo) { $result.modelo = $m2.Groups[2].Value }
            }
            if ($result.token -notlike 'MSG-*') { $result.token = $tok }
        }
    }
    return $result
}

function Test-SessionGrowing {
    param(
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$Password,
        [int]$WaitMs = 15000,
        [int]$Limit = 5,
        [scriptblock]$SleepFn
    )
    function Read-SessionFingerprint([string]$sid, [int]$p, [string]$pw) {
        $api = Invoke-CrossApi -Method 'GET' -Path "/session/$sid/message?limit=$Limit" -Port $p -Password $pw -TimeoutSec 8
        if ($api.status -ne 200) { return $null }
        $msgs = $api.body | ConvertFrom-Json
        $parts = @()
        foreach ($m in $msgs) {
            foreach ($t in ($m.parts | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })) {
                $parts += $m.info.id + ':' + $t
            }
        }
        return ($parts -join '|')
    }
    $a1 = Read-SessionFingerprint $SessionId $Port $Password
    if ($SleepFn) { & $SleepFn $WaitMs } else { Start-Sleep -Milliseconds $WaitMs }
    $a2 = Read-SessionFingerprint $SessionId $Port $Password
    if ($null -eq $a1 -or $null -eq $a2) { return @{ growing = $false; checkable = $false } }
    return @{ growing = ($a1 -ne $a2); checkable = $true }
}

function Find-CrossOutboxPending {
    param([string]$Path = '')
    if (-not $Path) { $Path = Get-OutboxPath }
    $now = (Get-Date).ToUniversalTime()
    $list = New-Object System.Collections.ArrayList
    foreach ($e in @(Read-OutboxLog -Path $Path)) {
        if ($e.estado -ne 'EN_VUELO') { continue }
        $deadline = $null
        $vencido = $false
        if ($e.lease -match '@(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)') {
            try {
                $deadline = [System.DateTime]::Parse($Matches[1]).ToUniversalTime()
                $vencido = $deadline -lt $now
            } catch { $vencido = $true }
        }
        [void]$list.Add([ordered]@{
            msg_id  = $e.msg_id
            dest    = $e.dest
            run_id  = $e.run_id
            token   = $e.token
            lease   = $e.lease
            attempt = $e.attempt
            estado  = $e.estado
            deadline = $(if ($deadline) { $deadline.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' })
            vencido = $vencido
        })
    }
    return @($list)
}

function New-CrossDelivery {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [Parameter(Mandatory=$true)][string]$Dest,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
        [string]$RunId = '',
        [string]$Token = '',
        [string]$Lease = '',
        [string]$Sucesor = '',
        [bool]$RequiereAck = $true,
        [string]$OutboxPath = '',
        [int]$AckTimeoutSec = 120,
        [int]$MaxAttempts = 2,
        [int]$InitialAttempt = 0,
        [int]$BackoffSec = 2,
        [int]$Port = 0,
        [string]$Password = '',
        [switch]$NoCache,
        [switch]$HealthSkip,
        [switch]$NoWait,
        [string]$MySessionId = '',
        [scriptblock]$SendFn,
        [scriptblock]$ReadFn,
        [scriptblock]$GrowingFn,
        [scriptblock]$SleepFn
    )
    if (-not $OutboxPath) { $OutboxPath = Get-OutboxPath }
    $cfg = Get-CrossConfig
    if (-not $MySessionId) { $MySessionId = [string]$cfg.my_session_id }
    if ($AckTimeoutSec -le 0) { $AckTimeoutSec = 120 }

    $port = $Port
    $password = $Password
    if (-not $SendFn -and -not $ReadFn -and -not $GrowingFn) {
        $ep = Resolve-CrossEndpoint -Port $Port -Password $Password -NoCache:$NoCache -HealthSkip:$HealthSkip
        if (-not $ep.ok) {
            return @{ ok = $false; err = $ep.err; detail = $ep.detail; state = 'ERROR'; http_status = 0; attempt = $InitialAttempt }
        }
        $port = $ep.port
        $password = $ep.password
    }

    function Do-Send([string]$sessionId, [string]$body) {
        if ($SendFn) { return @(& $SendFn $sessionId $body) }
        $payload = @{ parts = @(@{ type = 'text'; text = $body }) } | ConvertTo-Json -Depth 4
        $api = Invoke-CrossApi -Method 'POST' -Path "/session/$sessionId/prompt_async" -BodyJson $payload -Port $port -Password $password
        return @{ status = $api.status; body = $api.body }
    }
    function Read-NewMessages {
        if ($ReadFn) { return @(& $ReadFn $MySessionId) }
        $api = Invoke-CrossApi -Method 'GET' -Path "/session/$MySessionId/message?limit=30" -Port $port -Password $password -TimeoutSec 8
        if ($api.status -ne 200) { return @() }
        $msgs = $api.body | ConvertFrom-Json
        $out = @()
        foreach ($m in $msgs) {
            if ($m.info.role -ne 'user') { continue }
            foreach ($t in ($m.parts | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })) {
                $out += @{ role = 'user'; text = $t; id = $m.info.id }
            }
        }
        return @($out)
    }
    function Sleep-Ms([int]$ms) {
        if ($SleepFn) { & $SleepFn $ms } else { Start-Sleep -Milliseconds $ms }
    }
    function Find-AckInList($list, [string]$tok) {
        foreach ($item in @($list)) {
            if ($null -eq $item) { continue }
            $p = Parse-CrossAckText ([string]$item.text)
            if ($p.ack -and ($p.token -eq $tok -or $p.token -like "$tok*")) { return @{ type = 'ack'; ack_id = $p.emisor; ack_model = $p.modelo } }
            if ($p.nack -and ($p.token -eq $tok -or $p.token -like "$tok*")) { return @{ type = 'nack'; reason = $p.razon; msg_id = $p.msg_id; run_id = $p.run_id } }
        }
        return $null
    }
    function Get-DestGrowing {
        if ($GrowingFn) { return [bool](& $GrowingFn) }
        $growMs = 15000
        if ($cfg.session_growing_check_ms) { $growMs = [int]$cfg.session_growing_check_ms }
        $g = Test-SessionGrowing -SessionId $Dest -Port $port -Password $password -WaitMs $growMs -SleepFn $SleepFn
        return [bool]$g.growing
    }

    $envelope = Format-CrossEnvelope -MsgId $MsgId -RunId $RunId -Token $Token -RequiereAck $RequiereAck -Lease $Lease -Sucesor $Sucesor
    $body = ConvertTo-AsciiSafe $envelope
    $v2line = Format-CrossEnvelopeV2 -MsgId $MsgId -RunId $RunId -Token $Token -RequiresAck $RequiereAck -Lease $Lease -Successor $Sucesor -Text $Text
    $body += "`n" + $v2line
    if ($Text) { $body += "`n" + (ConvertTo-AsciiSafe $Text) }

    function Test-RetryableStatus([int]$st) {
        return ($st -eq 0 -or $st -eq 408 -or $st -eq 429 -or $st -ge 500)
    }
    function Reason-Code([int]$st) {
        if ($st -eq 429) { return 'NACK_RATE_LIMITED' }
        if ($st -eq 0 -or $st -eq 408) { return 'NACK_TIMEOUT' }
        if ($st -eq 404) { return 'NACK_DEST_NOT_FOUND' }
        if ($st -ge 500) { return 'NACK_SERVER_ERROR' }
        if ($st -ge 400) { return 'NACK_HTTP_4XX' }
        return 'NACK_NETWORK'
    }

    $attempt = [int]$InitialAttempt
    $sentAt = Get-Date
    $ack = $null
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        $renewed = $false
        [void](Set-OutboxAttempt -MsgId $MsgId -Attempt $attempt -Path $OutboxPath)
        $send = Do-Send $Dest $body
        $st = [int]$send.status

        if ($st -eq 404) {
            [void](Set-OutboxEstado -MsgId $MsgId -Estado 'EXPIRADO' -Path $OutboxPath)
            return @{ ok = $false; err = 'DEST_NOT_FOUND'; reason_code = 'NACK_DEST_NOT_FOUND'; detail = "dest $Dest devolvio HTTP 404"; state = 'EXPIRADO'; http_status = $st; attempt = $attempt }
        }
        if ($st -eq 401 -or $st -eq 403) {
            [void](Set-OutboxEstado -MsgId $MsgId -Estado 'EXPIRADO' -Path $OutboxPath)
            return @{ ok = $false; err = 'AUTH_FAILED'; reason_code = 'NACK_CONFIG_ERROR'; detail = "HTTP $st autenticando ante el servidor"; state = 'EXPIRADO'; http_status = $st; attempt = $attempt }
        }
        if ($st -lt 200 -or $st -ge 300) {
            if ((Test-RetryableStatus $st) -and $attempt -lt $MaxAttempts) {
                $backoffMs = [int]($BackoffSec * 1000 * $attempt)
                Sleep-Ms $backoffMs
                continue
            }
            [void](Set-OutboxEstado -MsgId $MsgId -Estado 'EXPIRADO' -Path $OutboxPath)
            $err = if ($st -le 0) { 'NETWORK' } else { "HTTP_$st" }
            return @{ ok = $false; err = $err; reason_code = (Reason-Code $st); detail = "prompt_async -> HTTP $st"; state = 'EXPIRADO'; http_status = $st; attempt = $attempt }
        }

        if (-not $RequiereAck) {
            [void](Set-OutboxEstado -MsgId $MsgId -Estado 'CONFIRMADO' -Path $OutboxPath)
            return @{ ok = $true; state = 'CONFIRMADO'; delivered = $true; ack = $false; attempt = $attempt; http_status = $st; ack_latency_ms = 0 }
        }
        if ($NoWait) {
            return @{ ok = $true; state = 'PENDING'; delivered = $true; ack = $false; no_wait = $true; detail = 'entregado sin esperar ACK (--no-wait)'; attempt = $attempt; http_status = $st; ack_latency_ms = 0 }
        }

        while ($true) {
            $deadline = (Get-Date).AddSeconds($AckTimeoutSec)
            while ((Get-Date) -lt $deadline) {
                $newMsgs = Read-NewMessages
                $ack = Find-AckInList $newMsgs $Token
                if ($ack) { break }
                Sleep-Ms 3000
            }
            if ($ack -and $ack.type -eq 'ack') {
                [void](Set-OutboxEstado -MsgId $MsgId -Estado 'CONFIRMADO' -Path $OutboxPath)
                $latency = [math]::Round(((Get-Date) - $sentAt).TotalMilliseconds)
                return @{ ok = $true; state = 'CONFIRMADO'; delivered = $true; ack = $true; ack_id = $ack.ack_id; ack_model = $ack.ack_model; attempt = $attempt; ack_latency_ms = $latency }
            }
            if ($ack -and $ack.type -eq 'nack') {
                [void](Set-OutboxEstado -MsgId $MsgId -Estado 'NACKED' -Path $OutboxPath)
                return @{ ok = $false; err = 'NACK'; reason = $ack.reason; reason_code = $ack.reason; detail = "destination responded NACK ($($ack.reason))"; state = 'NACKED'; attempt = $attempt; nack_msg_id = $ack.msg_id; nack_run_id = $ack.run_id }
            }
            $growing = Get-DestGrowing
            if ($growing -and -not $renewed) {
                $renewed = $true
                [void](Renew-CrossLease -MsgId $MsgId -Path $OutboxPath -Minutes $cfg.default_lease_minutes)
                continue
            }
            break
        }

        if ($attempt -lt $MaxAttempts) { continue }
        [void](Set-OutboxEstado -MsgId $MsgId -Estado 'EXPIRADO' -Path $OutboxPath)
        $growText = if ($growing) { 'creciendo' } else { 'quieto' }
        return @{ ok = $false; err = 'ACK_TIMEOUT'; reason_code = 'NACK_TIMEOUT'; detail = "no ACK after $($AckTimeoutSec)s (attempt $attempt/$MaxAttempts, destination $growText)"; state = 'EXPIRADO'; attempt = $attempt; session_growing = $growing }
    }
    return @{ ok = $false; err = 'DELIVERY_ABORTED'; state = 'EN_VUELO' }
}

function Write-CrossDeliveryLog {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$Dest = '',
        [string]$Token = '',
        [hashtable]$Result = @{},
        [string]$Cmd = 'send',
        [string]$Detail = '',
        [string]$LogPath = '',
        [string]$AuditPath = ''
    )
    $cfg = Get-CrossConfig
    $dir = if ($cfg.whiteboard_dir) { [Environment]::ExpandEnvironmentVariables([string]$cfg.whiteboard_dir) } else { Split-Path -Parent (Get-OutboxPath) }
    if (-not $LogPath) { $LogPath = Join-Path $dir 'delivery_log.jsonl' }
    if (-not $AuditPath) { $AuditPath = Join-Path $dir 'audit_log.md' }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($null -eq $Result) { $Result = @{} }
    $isDict = $Result -is [System.Collections.IDictionary]
    function Get-ResultVal($h, [string]$k) {
        if ($isDict) {
            if ($h.Contains($k)) { return $h[$k] }
            return $null
        }
        $p = $h.PSObject.Properties[$k]
        if ($null -ne $p) { return $p.Value }
        return $null
    }
    $line = [ordered]@{
        ts = $ts; cmd = $Cmd; msg_id = $MsgId; dest = $Dest; token = $Token
        state = Get-ResultVal $Result 'state'
        err = Get-ResultVal $Result 'err'
        reason_code = Get-ResultVal $Result 'reason_code'
        attempt = Get-ResultVal $Result 'attempt'
        http_status = Get-ResultVal $Result 'http_status'
        ack = Get-ResultVal $Result 'ack'
        ack_id = Get-ResultVal $Result 'ack_id'
        ack_model = Get-ResultVal $Result 'ack_model'
        reason = Get-ResultVal $Result 'reason'
        ack_latency_ms = Get-ResultVal $Result 'ack_latency_ms'
        session_growing = Get-ResultVal $Result 'session_growing'
    }
    $logParent = Split-Path -Parent $LogPath
    if ($logParent -and -not (Test-Path -LiteralPath $logParent)) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
    [System.IO.File]::AppendAllText($LogPath, (ConvertTo-Json $line -Compress) + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $resState = Get-ResultVal $Result 'state'
    $resOk = Get-ResultVal $Result 'ok'
    $resRc = Get-ResultVal $Result 'reason_code'
    $resLatency = Get-ResultVal $Result 'ack_latency_ms'
    $estado = if ($resState) { [string]$resState } elseif ($resOk) { 'ENTREGADO' } else { 'FALLIDO' }
    $notaParts = New-Object System.Collections.ArrayList
    if ($Detail) { [void]$notaParts.Add($Detail) }
    if ($resRc) { [void]$notaParts.Add("rc=$resRc") }
    if ($resLatency) { [void]$notaParts.Add("ack_ms=$resLatency") }
    $nota = @($notaParts) -join '; '
    [void](Write-AuditEntry -MsgId $MsgId -Dest $Dest -Token $Token -Tipo 'ENV' -Estado $estado -Nota $nota -AuditPath $AuditPath)
    return $line
}

Export-ModuleMember -Function Format-CrossEnvelope, Parse-CrossAckText, Test-SessionGrowing, Find-CrossOutboxPending, New-CrossDelivery, Write-CrossDeliveryLog
