Set-StrictMode -Version 2.0

$script:Config = $null
$script:PortCache = Join-Path $env:TEMP 'cross-port.cache'
$script:EnvFile = Join-Path $env:USERPROFILE '.config\opencode\.env'

function Import-CrossConfig {
    param([string]$ConfigPath = '')
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'CURL_NOT_FOUND: curl.exe not found in PATH (required for the OpenCode API)'
    }
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot '..\cross.config.json' }
    $configPath = [System.IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-Path -LiteralPath $configPath)) { throw "CONFIG_NOT_FOUND: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $localPath = [System.IO.Path]::ChangeExtension($configPath, 'local.json')
    if (Test-Path -LiteralPath $localPath) {
        $local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
        foreach ($prop in $local.PSObject.Properties) {
            if ($null -ne $prop.Value -and "$($prop.Value)" -ne '') { $config.$($prop.Name) = $prop.Value }
        }
    }
    foreach ($key in @('my_session_id','my_model','my_role','whiteboard_dir','diario_dir','log_path','desktop_logs_dir')) {
        $envKey = "CROSS_MY_" + ($key.ToUpper())
        if ([Environment]::GetEnvironmentVariable($envKey)) {
            $config.$key = [Environment]::GetEnvironmentVariable($envKey)
        }
    }
    if ([Environment]::GetEnvironmentVariable('CROSS_WHITEBOARD_DIR')) { $config.whiteboard_dir = [Environment]::GetEnvironmentVariable('CROSS_WHITEBOARD_DIR') }
    if ([Environment]::GetEnvironmentVariable('CROSS_LOG_PATH')) { $config.log_path = [Environment]::GetEnvironmentVariable('CROSS_LOG_PATH') }
    $script:Config = $config
    return $config
}

function Get-CrossConfig {
    if (-not $script:Config) { $null = Import-CrossConfig }
    return $script:Config
}

function Expand-Path {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return $expanded
}

function Get-CrossPassword {
    $pw = [Environment]::GetEnvironmentVariable('OPENCODE_SERVER_PASSWORD')
    if ($pw) { return @{ value = $pw; source = 'env' } }
    $envFile = Expand-Path $script:EnvFile
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in (Get-Content -LiteralPath $envFile)) {
            if ($line -match '^\s*OPENCODE_SERVER_PASSWORD\s*=\s*(.+?)\s*$') {
                return @{ value = $Matches[1]; source = 'env_file' }
            }
        }
    }
    return $null
}

function Get-PasswordHash {
    param([string]$Password)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-CrossHealthRaw {
    param([int]$Port, [string]$Password)
    try {
        $url = "http://127.0.0.1:$Port/global/health"
        $tmp = Join-Path $env:TEMP ("cross_health_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
        $auth = "opencode:$Password"
        $code = & curl.exe -s -o $tmp -w "%{http_code}" --max-time 5 -u $auth $url 2>$null
        $body = if (Test-Path -LiteralPath $tmp) { Get-Content -LiteralPath $tmp -Raw } else { '' }
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        if ($code -eq '401') { return @{ status = 401; healthy = $false } }
        if ($code -eq '200') {
            try { $json = $body | ConvertFrom-Json; $ok = ($json.healthy -eq $true) } catch { $ok = $false }
            if ($ok) { return @{ status = 200; healthy = $true; version = $json.version } }
            return @{ status = 200; healthy = $false }
        }
        return @{ status = [int]$code; healthy = $false }
    } catch {
        return @{ status = 0; healthy = $false }
    }
}

function Get-CrossPortFromCache {
    param([int]$TtlSeconds = 60, [string]$PasswordHash = '')
    if (-not (Test-Path -LiteralPath $script:PortCache)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $script:PortCache -Raw | ConvertFrom-Json
        $age = ((Get-Date).ToUniversalTime() - [System.DateTime]::Parse($cache.ts).ToUniversalTime()).TotalSeconds
        if ($age -gt $TtlSeconds) { return $null }
        if ($PasswordHash -and $cache.password_hash -ne $PasswordHash) { return $null }
        return [int]$cache.port
    } catch {
        return $null
    }
}

function Write-CrossPortCache {
    param([int]$Port, [string]$PasswordHash)
    $payload = @{ port = $Port; password_hash = $PasswordHash; ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $json = $payload | ConvertTo-Json -Compress
    try {
        [System.IO.File]::WriteAllText($script:PortCache, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # cache es best-effort
    }
}

function Get-CrossPortFromLog {
    $logsDir = Expand-Path ([Environment]::GetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR'))
    if (-not $logsDir) {
        $config = Get-CrossConfig
        if ($config.desktop_logs_dir) { $logsDir = Expand-Path $config.desktop_logs_dir }
    }
    if (-not $logsDir -or -not (Test-Path -LiteralPath $logsDir)) { return $null }
    $latest = Get-ChildItem -LiteralPath $logsDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }
    $mainLog = Join-Path $latest.FullName 'main.log'
    if (-not (Test-Path -LiteralPath $mainLog)) { return $null }
    try {
        $content = Get-Content -LiteralPath $mainLog -Raw
        $m = [regex]::Match($content, "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")
        if ($m.Success) { return [int]$m.Groups[1].Value }
    } catch {}
    return $null
}

function Get-CrossPortByScan {
    param([int[]]$ScanRange = @(30000, 40000))
    $lo = $ScanRange[0]; $hi = $ScanRange[1]
    $candidates = New-Object System.Collections.ArrayList
    for ($p = $lo; $p -le $hi; $p++) {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync('127.0.0.1', $p)
        if ($task.Wait(120)) {
            if ($tcp.Connected) { [void]$candidates.Add($p) }
        }
        $tcp.Close()
        if ($candidates.Count -ge 20) { break }
    }
    $pw = Get-CrossPassword
    foreach ($p in $candidates) {
        if ($pw) {
            $h = Test-CrossHealthRaw -Port $p -Password $pw.value
            if ($h.healthy) { return $p }
        } else {
            return $p
        }
    }
    return $null
}

function Resolve-CrossEndpoint {
    param(
        [int]$Port = 0,
        [string]$Password = '',
        [switch]$NoCache,
        [switch]$HealthSkip
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $config = Get-CrossConfig
    $detectionMethod = 'cache'

    if (-not $Password) {
        $pwObj = Get-CrossPassword
        if (-not $pwObj) {
            return @{ ok = $false; code = 3; err = 'AUTH_FAILED'; detail = 'OPENCODE_SERVER_PASSWORD not defined (neither env nor .env)'; hint = 'set the env var or add it to .env' }
        }
        $Password = $pwObj.value
        $passwordSource = $pwObj.source
    } else {
        $passwordSource = 'override'
    }
    $pwHash = Get-PasswordHash $Password

    if ($Port -gt 0) {
        $detectionMethod = 'override'
        if (-not $HealthSkip) {
            $h = Test-CrossHealthRaw -Port $Port -Password $Password
            if (-not $h.healthy) {
                return @{ ok = $false; code = 3; err = 'UNHEALTHY'; detail = "puerto $Port responde pero healthy=false o codigo $($h.status)"; hint = 'usar --no-cache para forzar redeteccion' }
            }
        }
        $watch.Stop()
        return @{ ok = $true; code = 0; port = $Port; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
    }

    if (-not $NoCache) {
        $cached = Get-CrossPortFromCache -TtlSeconds $config.port_cache_ttl_s -PasswordHash $pwHash
        if ($cached) {
            if ($HealthSkip) {
                $watch.Stop()
                return @{ ok = $true; code = 0; port = $cached; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
            }
            $h = Test-CrossHealthRaw -Port $cached -Password $Password
            if ($h.healthy) {
                $watch.Stop()
                return @{ ok = $true; code = 0; port = $cached; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
            }
        }
    }

    $fromLog = Get-CrossPortFromLog
    if ($fromLog) {
        $detectionMethod = 'regex'
        if ($HealthSkip) {
            Write-CrossPortCache -Port $fromLog -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $fromLog; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
        $h = Test-CrossHealthRaw -Port $fromLog -Password $Password
        if ($h.healthy) {
            Write-CrossPortCache -Port $fromLog -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $fromLog; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
    }

    $scanned = Get-CrossPortByScan -ScanRange $config.port_scan_range
    if ($scanned) {
        $detectionMethod = 'scan'
        if ($HealthSkip) {
            Write-CrossPortCache -Port $scanned -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $scanned; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
        $h = Test-CrossHealthRaw -Port $scanned -Password $Password
        if ($h.healthy) {
            Write-CrossPortCache -Port $scanned -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $scanned; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
    }

    $watch.Stop()
    return @{ ok = $false; code = 3; err = 'SERVER_NOT_FOUND'; detail = 'ningun puerto respondio /global/health healthy'; hint = 'comprobar que OpenCode Desktop esta abierto y autodeteccion habilitada' }
}

function Invoke-CrossApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$BodyJson = '',
        [int]$Port,
        [string]$Password,
        [int]$TimeoutSec = 10
    )
    $url = "http://127.0.0.1:$Port$Path"
    $args = @('-s', '--max-time', "$TimeoutSec", '-u', "opencode:$Password", '-X', $Method)
    $tmpBody = $null
    $tmpOut = Join-Path $env:TEMP ("cross_api_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
    $args += @('-o', $tmpOut, '-w', '%{http_code}')
    if ($BodyJson) {
        $tmpBody = Join-Path $env:TEMP ("cross_body_" + [System.Guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmpBody, (ConvertTo-AsciiSafe $BodyJson), (New-Object System.Text.UTF8Encoding($false)))
        $args += @('-H', 'Content-Type: application/json', '--data-binary', "@$tmpBody")
    }
    $args += $url
    $code = & curl.exe @args 2>$null
    $body = if (Test-Path -LiteralPath $tmpOut) { Get-Content -LiteralPath $tmpOut -Raw } else { '' }
    Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
    if ($tmpBody) { Remove-Item -LiteralPath $tmpBody -ErrorAction SilentlyContinue }
    return @{ status = [int]$code; body = $body }
}

Export-ModuleMember -Function Import-CrossConfig, Get-CrossConfig, Get-CrossPassword, Get-PasswordHash, Test-CrossHealthRaw, Resolve-CrossEndpoint, Invoke-CrossApi, Get-CrossPortFromCache, Write-CrossPortCache, Get-CrossPortFromLog, Get-CrossPortByScan
