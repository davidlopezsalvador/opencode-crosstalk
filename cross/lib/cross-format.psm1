Set-StrictMode -Version 2.0

function ConvertTo-AsciiSafe {
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text)
    $normalized = $Text -replace '\r\n', "`n"
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $normalized.ToCharArray()) {
        $code = [int]$ch
        if ($code -ge 32 -and $code -le 126) {
            [void]$sb.Append($ch)
        } elseif ($code -eq 9 -or $code -eq 10 -or $code -eq 13) {
            [void]$sb.Append($ch)
        } else {
            [void]$sb.Append('?')
        }
    }
    return $sb.ToString()
}

function ConvertTo-Iso8601Utc {
    param([System.DateTime]$Date = (Get-Date))
    return $Date.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function ConvertTo-UtcDate {
    param([string]$IsoString)
    $dt = [System.DateTime]::Parse($IsoString)
    return $dt.ToUniversalTime()
}

function ConvertTo-PlainJson {
    param([Parameter(Mandatory=$true)]$Object)
    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    return (ConvertTo-AsciiSafe $json)
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Content
    )
    $ascii = ConvertTo-AsciiSafe $Content
    [System.IO.File]::WriteAllText($Path, $ascii, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-OutResult {
    param(
        [Parameter(Mandatory=$true)]$Result,
        [string]$Mode = 'json',
        [string]$Cmd = ''
    )
    if ($Mode -eq 'quiet') {
        if (-not $Result.ok) {
            $err = @{ ts = (ConvertTo-Iso8601Utc); cmd = $Cmd; err = $Result.err; detail = $Result.detail }
            [Console]::Error.WriteLine((ConvertTo-PlainJson $err))
        }
        return
    }
    if ($Mode -eq 'human') {
        $ts = $Result.ts
        $okText = if ($Result.ok) { 'OK' } else { 'FAIL' }
        $code = $Result.code
        $dur = $Result.duration_ms
        [Console]::WriteLine(("[{0}] cross {1} -> {2} ({3}) in {4}ms" -f $ts, $Cmd, $okText, $code, $dur))
        if ($Result.Contains('messages')) {
            [Console]::WriteLine(("  {0} mensaje(s) en {1}" -f $Result['messages'].Count, $Result['session']))
            foreach ($m in @($Result['messages'])) {
                $label = if ($m.role -eq 'user') { '> ' } else { '  ' }
                [Console]::WriteLine(("  {0}{1}: {2}" -f $label, $m.role, ($m.text -replace "\r?\n", ' | ')))
            }
        }
        if ($Result.Contains('sessions')) {
            [Console]::WriteLine(("  {0} sesion(es)" -f $Result['count']))
            foreach ($s in @($Result['sessions'])) {
                $t = $s.title; if (-not $t) { $t = '(sin titulo)' }
                [Console]::WriteLine(("  - {0}  [{1}]  {2}" -f $s.id, $s.model, $t))
            }
        }
        foreach ($key in @('msg_id','outbox_state','http_status','err','detail','hint','session_id','model','healthy','port','version')) {
            if ($Result.Contains($key) -and $null -ne $Result[$key]) {
                [Console]::WriteLine(("  {0}: {1}" -f $key, $Result[$key]))
            }
        }
        return
    }
    [Console]::WriteLine((ConvertTo-PlainJson $Result))
}

function New-Result {
    param(
        [bool]$Ok = $true,
        [int]$Code = 0,
        [hashtable]$Data = @{},
        [string]$Cmd = ''
    )
    $r = [ordered]@{ ts = (ConvertTo-Iso8601Utc); cmd = $Cmd; ok = $Ok; code = $Code; duration_ms = 0 }
    foreach ($k in $Data.Keys) { $r[$k] = $Data[$k] }
    return $r
}

function Get-DurationMs {
    param([System.Diagnostics.Stopwatch]$Watch)
    return [math]::Round($Watch.Elapsed.TotalMilliseconds)
}

Export-ModuleMember -Function ConvertTo-AsciiSafe, ConvertTo-Iso8601Utc, ConvertTo-UtcDate, ConvertTo-PlainJson, Write-Utf8NoBom, Write-OutResult, New-Result, Get-DurationMs
