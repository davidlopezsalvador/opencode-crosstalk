# CROSS-TALK setup helper
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
# Detects your OpenCode Desktop session, writes cross/cross.config.local.json
# (git-ignored, never committed), and verifies connectivity with `cross health`.
$ErrorActionPreference = 'Stop'

$root = Split-Path $MyInvocation.MyCommand.Path -Parent
$cli = Join-Path $root 'cross\cross.ps1'
$localPath = Join-Path $root 'cross\cross.config.local.json'

Write-Host "== CROSS-TALK setup =="

if (-not (Test-Path -LiteralPath $cli)) {
    Write-Host "ERROR: cross\cross.ps1 not found. Run this script from the repository root."
    exit 1
}

Write-Host "Detecting OpenCode Desktop server..."
$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
if (-not (Test-Path $logDir) -or -not (Get-ChildItem $logDir -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: no OpenCode Desktop logs found at $logDir."
    Write-Host "Start OpenCode Desktop with at least 2 sessions open, then re-run."
    exit 1
}

$password = $env:OPENCODE_SERVER_PASSWORD
if (-not $password) {
    $envFile = Join-Path $root '.env'
    if (Test-Path -LiteralPath $envFile) {
        $password = (Get-Content $envFile -Raw) -replace '^OPENCODE_SERVER_PASSWORD=(.*)$', '$1'
        $password = $password.Trim()
    }
}
if (-not $password) {
    Write-Host "ERROR: OPENCODE_SERVER_PASSWORD not found (env var or .env)."
    Write-Host "Set it and re-run, or add it to a .env file in the repo root."
    exit 1
}

$latestLog = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$content = Get-Content "$($latestLog.FullName)\main.log" -Raw
$port = ([regex]::Match($content, "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
if (-not $port) {
    Write-Host "ERROR: could not detect the server port from the logs."
    exit 1
}
Write-Host "Server detected: http://127.0.0.1:$port"

Write-Host ""
Write-Host "== Detecting your session =="
$sessions = curl.exe -s -u "opencode:$password" "http://127.0.0.1:$port/session" | ConvertFrom-Json
if (-not $sessions -or @($sessions).Count -eq 0) {
    Write-Host "ERROR: no sessions found. Open at least 2 sessions in the same project."
    exit 1
}

$mySession = ''
foreach ($s in @($sessions)) {
    if ($s.title -match 'leader|lead|lider') { $mySession = $s.id; break }
}
if (-not $mySession) { $mySession = @($sessions)[0].id }

$local = @{
    my_session_id = $mySession
    leader_session_id = $mySession
    my_role = 'leader'
}
$json = $local | ConvertTo-Json
[System.IO.File]::WriteAllText($localPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Local config written: cross\cross.config.local.json (git-ignored)"
Write-Host "  my_session_id = $mySession"

Write-Host ""
Write-Host "== Verifying connectivity =="
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli health 2>&1 | Out-String
Write-Host $out.Trim()
if ($out -match '"ok":\s*true|ok.:.true') {
    Write-Host ""
    Write-Host "Setup complete. You can now use:"
    Write-Host "  cd cross"
    Write-Host "  .\cross.ps1 sessions"
    Write-Host "  .\cross.ps1 send --msg test-1 --dest ses_OTHER --text `"Hello`""
    Write-Host ""
    Write-Host "NOTE: cross.config.local.json is git-ignored. Your identity stays local."
} else {
    Write-Host "Setup finished but health check did not confirm. Check the output above."
}