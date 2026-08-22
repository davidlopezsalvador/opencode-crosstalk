# Contract parser fuzzing (v1.13): invariantes de robustez ante entradas
# imprevistas (mutaciones, tipos raros, unicode hostil, multiples envelopes,
# inputs grandes). Determinista: seed fija 20260820. Corpus base en
# Get-FuzzCorpus: para anadir entradas, extender la funcion (el resto es
# agnostico al corpus). Las mutaciones se derivan en orden fijo; el seed solo
# controla posiciones aleatorias dentro de cada mutacion.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-fuzz.ps1
$ErrorActionPreference = 'Stop'
$mod = Join-Path $PSScriptRoot '..\modules\cross-envelope.psm1'
Import-Module $mod -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

function Get-FuzzCorpus {
    $envMsg = New-CrossEnvelope -MsgId 'msg_lead_001' -RunId 'R1' -Token 'T1' -Text 'Simple task'
    $envOpt = New-CrossEnvelope -MsgId 'msg_002' -RunId 'R2' -Token 'T2' -RequiresAck $false -Lease 'ses_A@2026-08-21T15:00:00Z' -Successor 'ses_B' -Text 'Unicode jp rus ar | pipe = equals'
    $ack = New-CrossAckJson -Token 'MSG-abc123' -MsgId 'msg_lead_001' -Emitter 'ses_B' -Model 'model-b'
    $nack = New-CrossNackJson -Token 'MSG-abc123' -MsgId 'msg_lead_001' -Emitter 'ses_B' -Model 'model-b' -Reason 'TASK_TOO_COMPLEX' -Detail 'Cannot access external APIs'
    return @(
        $envMsg, $envOpt, $ack, $nack,
        ("Analiza el informe.`nENVELOPE-V2: $ack"),
        'ACK:PROPUESTA-R1:ses_BBB:model-b', 'ACK:TOKEN:ses_CCC',
        'NACK:PROPUESTA-R1:ses_BBB:model-b:CAPACITY',
        'NACK:TK:ses_A:model-b:CAPACITY:msg_123:RUN_456',
        'entendido ACK-PROTOCOLO:1.6.1 ok'
    )
}

function New-FuzzRng { return [System.Random]::new(20260820) }

function Mutate-Truncate { param([string]$s, $rng)
    if ($s.Length -le 1) { return '' }
    return $s.Substring(0, $rng.Next(0, $s.Length))
}
function Mutate-InsertChars { param([string]$s, $rng)
    if ($s.Length -eq 0) { return $s }
    $pool = [char[]]'abZ09{}[]":,ENVELOPE-V2 ACK NACK|\+-*?!'
    $pos = $rng.Next(0, $s.Length + 1)
    $n = $rng.Next(1, 8)
    $ins = ''
    for ($i = 0; $i -lt $n; $i++) { $ins += $pool[$rng.Next(0, $pool.Length)] }
    return $s.Insert($pos, $ins)
}
function Mutate-Fields { param([string]$s, $rng)
    $m = [regex]::Match($s, '("[A-Za-z_]+":"[^"]*")')
    if (-not $m.Success) { return $s }
    $pair = $m.Groups[1].Value
    if ($rng.Next(0, 2) -eq 0) { return $s.Replace($pair, $pair + ',' + $pair) }
    return $s.Replace($pair, '')
}
function Mutate-WeirdTypes { param([string]$s, $rng)
    $vals = @('null', 'true', 'false', '123', '-1', '0.5', '[]', '{}', '""', '"abc"', 'NaN', 'Infinity')
    $m = [regex]::Match($s, '("(?:msg_id|run_id|token|type|v|requires_ack|timestamp|emitter|model|reason|detail|text)":)([^,}]+)')
    if (-not $m.Success) { return $s }
    return $s.Replace($m.Groups[0].Value, $m.Groups[1].Value + $vals[$rng.Next(0, $vals.Length)])
}
function Mutate-BrokenJson { param([string]$s, $rng)
    $ops = @(
        { param($t) $t + '}{"x":1}' },
        { param($t) $t.Replace('{', '[{').Replace('}', '}]') },
        { param($t) $t.TrimEnd('}') },
        { param($t) 'ENVELOPE-V2: ' + $t.Replace('{', '{ ') + ' garbage' },
        { param($t) 'prefix ' + $t },
        { param($t) $t.Replace('"msg_id"', 'msg_id') }
    )
    return (& $ops[$rng.Next(0, $ops.Length)] $s)
}
function Mutate-Unicode { param([string]$s, $rng)
    $hostile = @("`u{FEFF}", "`u{200E}", "`u{0000}", "`u{0007}", "`u{001B}", "`u{2028}", "`u{2029}", ([char]0xD83D + [char]0xDE00), ([char]0x05D0), ([char]0x4E2D), ([char]0xE9))
    $pos = $rng.Next(0, $s.Length + 1)
    $chunk = ''
    for ($i = 0; $i -lt 3; $i++) { $chunk += $hostile[$rng.Next(0, $hostile.Length)] }
    return $s.Insert($pos, $chunk)
}
function Mutate-MultiEnvelope { param([string]$s, $rng)
    $ack = New-CrossAckJson -Token 'MSG-other' -MsgId 'msg_second' -Emitter 'ses_X' -Model 'm-x'
    if ($rng.Next(0, 2) -eq 0) { return $s + "`nENVELOPE-V2: $ack" }
    return ("ENVELOPE-V2: $ack`n" + $s)
}
function Mutate-NoJson { param([string]$s, $rng)
    $tails = @('ENVELOPE-V2: ', 'ENVELOPE-V2:', 'ENVELOPE-V2: {}', 'ENVELOPE-V2: []', 'ENVELOPE-V2: null', 'ENVELOPE-V2: {"v":2,"type":"message"}', 'ENVELOPE-V2: {"v":2}')
    if ($rng.Next(0, 2) -eq 0) { return $s + ' ' + $tails[$rng.Next(0, $tails.Length)] }
    return $tails[$rng.Next(0, $tails.Length)] + ' ' + $s
}
function Mutate-Huge { param([string]$s)
    $pad = 'x' * (10 * 1024 * 1024)
    return $s + $pad
}
function Test-EnvInv { param([string]$input, [string]$mut, [int]$ci, [int]$mi)
    $err = ''; $p = $null
    try { $p = Parse-CrossEnvelope -Text $input } catch { $err = $_.Exception.Message }
    if ($err) { Assert-True $false "env-no-exc [$mut c$ci m$mi]" ("EXC: $err len=$($input.Length) head=" + $input.Substring(0, [Math]::Min(120, $input.Length))); return }
    if ($null -eq $p) { Assert-True $false "env-result [$mut c$ci m$mi]" 'null'; return }
    Assert-True ($p.valid -is [bool]) "env-valid-bool [$mut c$ci m$mi]" "valid=$($p.valid)"
    if ($p.valid) {
        Assert-True ($p.format -eq 'v2-json') "env-format [$mut c$ci m$mi]" "fmt=$($p.format)"
        Assert-True ($p.type -in @('message','ack','nack')) "env-type [$mut c$ci m$mi]" "type=$($p.type)"
        Assert-True ($p.msg_id -is [string] -and $p.msg_id.Length -gt 0) "env-msgid [$mut c$ci m$mi]" "msg_id=[$($p.msg_id)]"
        Assert-True ($p.timestamp -is [string] -and $p.timestamp.Length -gt 0) "env-ts [$mut c$ci m$mi]" "ts=[$($p.timestamp)]"
        Assert-True ($p.requires_ack -is [bool]) "env-reqack [$mut c$ci m$mi]" "ra=[$($p.requires_ack)]"
    }
}
function Test-AckInv { param([string]$input, [string]$mut, [int]$ci, [int]$mi)
    # D1 (v1.17): fuzz targets the v2-only parser
    $err = ''; $r = $null
    try { $r = Parse-CrossEnvelope -Text $input } catch { $err = $_.Exception.Message }
    if ($err) { Assert-True $false "ack-no-exc [$mut c$ci m$mi]" ("EXC: $err len=$($input.Length) head=" + $input.Substring(0, [Math]::Min(120, $input.Length))); return }
    if ($null -eq $r) { Assert-True $false "ack-result [$mut c$ci m$mi]" 'null'; return }
    foreach ($k in @('valid')) { Assert-True ($r.$k -is [bool]) "ack-$k-bool [$mut c$ci m$mi]" "$k=[$($r.$k)]" }
    if ($r.valid) {
        Assert-True ($r.requires_ack -is [bool]) "requires_ack-bool [$mut c$ci m$mi]" "requires_ack=[$($r.requires_ack)]"
        Assert-True ($r.type -in @('message','ack','nack')) "type-closed [$mut c$ci m$mi]" "type=[$($r.type)]"
        if ($r.type -eq 'ack') {
            Assert-True ($r.token -is [string] -and $r.token.Length -gt 0) "ack-token [$mut c$ci m$mi]" "token=[$($r.token)]"
            Assert-True ($r.emitter -is [string]) "ack-emitter [$mut c$ci m$mi]" "emitter=[$($r.emitter)]"
        }
        if ($r.type -eq 'nack') {
            Assert-True ($r.reason -is [string]) "nack-reason [$mut c$ci m$mi]" "reason=[$($r.reason)]"
            Assert-True ($r.msg_id -is [string] -and $r.msg_id.Length -gt 0) "nack-msgid [$mut c$ci m$mi]" "msg_id=[$($r.msg_id)]"
        }
    }
}

Write-Host "== T-fuzz: invariantes parser contrato (seed 20260820) =="
$corpus = Get-FuzzCorpus
Assert-True ($corpus.Count -eq 10) 'corpus-10' "count=$($corpus.Count)"
$rng = New-FuzzRng
$mutators = @(
    @{ n = 'truncate'; f = { param($s, $r) Mutate-Truncate $s $r } },
    @{ n = 'insert'; f = { param($s, $r) Mutate-InsertChars $s $r } },
    @{ n = 'fields'; f = { param($s, $r) Mutate-Fields $s $r } },
    @{ n = 'weird'; f = { param($s, $r) Mutate-WeirdTypes $s $r } },
    @{ n = 'broken'; f = { param($s, $r) Mutate-BrokenJson $s $r } },
    @{ n = 'unicode'; f = { param($s, $r) Mutate-Unicode $s $r } },
    @{ n = 'multi'; f = { param($s, $r) Mutate-MultiEnvelope $s $r } },
    @{ n = 'nojson'; f = { param($s, $r) Mutate-NoJson $s $r } }
)
$total = 0
for ($ci = 0; $ci -lt $corpus.Count; $ci++) {
    $base = [string]$corpus[$ci]
    foreach ($mut in $mutators) {
        for ($mi = 0; $mi -lt 20; $mi++) {
            $mutated = & $mut.f $base $rng
            $total++
            Test-EnvInv $mutated $mut.n $ci $mi
            Test-AckInv $mutated $mut.n $ci $mi
        }
    }
    $huge = Mutate-Huge $base
    $total++
    Test-EnvInv $huge 'huge10mb' $ci 0
    Test-AckInv $huge 'huge10mb' $ci 0
}
Assert-True ($total -eq 1610) 'total-evaluaciones' "total=$total (10 corpus x (8 mut x 20 + 1 huge))"

Write-Host "== T-fuzz: casos fijos (regresion) =="
$w1 = Parse-CrossEnvelope -Text 'ENVELOPE-V2: {"v":2,"type":"message","msg_id":"m","timestamp":"2026-08-21T00:00:00Z"}'
Assert-True ($w1.valid) 'minimal-valid-envelope' 'v=2 type=message msg_id ts ok'
$w2 = Parse-CrossEnvelope -Text 'ENVELOPE-V2: {"v":2,"type":"message","msg_id":"","timestamp":"2026-08-21T00:00:00Z"}'
Assert-True (-not $w2.valid) 'msg_id-vacio-rechazado' "valid=$($w2.valid)"
$w3 = Parse-CrossEnvelope -Text 'ENVELOPE-V2: {"v":2,"type":"message","msg_id":"m"}'
Assert-True (-not $w3.valid) 'timestamp-faltante-rechazado' "valid=$($w3.valid)"
$w4 = Parse-CrossEnvelope -Text 'ENVELOPE-V2: {"v":"2x","type":"message","msg_id":"m","timestamp":"2026-08-21T00:00:00Z"}'
Assert-True (-not $w4.valid) 'v-non-int-rechazado' "valid=$($w4.valid)"
$w5 = Parse-CrossEnvelope -Text 'ENVELOPE-V2: {"v":2,"type":"message","msg_id":"m","timestamp":"2026-08-21T00:00:00Z","x":"1","x":"2"}'
Assert-True ($w5.valid) 'campos-duplicados-json-tolerado' "valid=$($w5.valid)"
$w6 = Parse-CrossEnvelope -Text 'ENVELOPE-V2: {"v":2,"type":"message","msg_id":"m","timestamp":"2026-08-21T00:00:00Z"} ENVELOPE-V2: {"v":2,"type":"ack","msg_id":"m2","token":"T9","timestamp":"2026-08-21T00:00:00Z"}'
Assert-True ($w6.valid -and $w6.type -eq 'message') 'multi-envelope-primero-gana' "type=$($w6.type)"
$w7 = Parse-CrossEnvelope 'ENVELOPE-V2: {"v":2,"type":"message","msg_id":"m","timestamp":"2026-08-21T00:00:00Z"}'
Assert-True ($w7.valid -and $w7.type -eq 'message') 'multi-env-message-no-ack' "type=$($w7.type)"
$w8 = Parse-CrossEnvelope -Text ("ENVELOPE-V2: " + [char]0xFEFF + ' {"v":2,"type":"message","msg_id":"m","timestamp":"2026-08-21T00:00:00Z"}')
Assert-True ($w8.valid) 'bom-antes-json-tolerado' "valid=$($w8.valid)"

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }

