#Requires -Version 5.1
<#
.SYNOPSIS
    One-click launcher for the dsh-superagent research prototype on Windows.

.DESCRIPTION
    Starts the isolated `superagent` DeepSeek Harness profile, which runs the
    dsh-superagent bundle (official repo: deepseek-ai/dsh-superagent-prototype)
    plus the WorkBuddy model provider, then opens the panel.

    The launcher is idempotent: if the panel already answers on the port it only
    opens the browser. It refuses to start a second instance against the same
    stateDir (the plugin's own lock would fail anyway).

    Windows specifics handled here (see README-superagent.md for evidence):
      * stateDir must match ^/ in the plugin's schema, so the profile uses a
        root-relative POSIX path. Node resolves it against the *current drive*,
        therefore the service MUST be started with the working directory on E:.
      * DSH_HOME must stay the shared profile root (~/.dsh) so the WorkBuddy
        vault under <DSH_HOME>/workbuddy-vault/<region>/ is visible.
      * The official scripts/dsh-superagent manager needs tmux + fcntl and does
        not run on Windows; this script replaces it with a PID file and netstat.

.PARAMETER Stop
    Stop the running service (only a process this script started / this profile).

.PARAMETER Restart
    Stop then start.

.PARAMETER NoOpen
    Start but do not open the browser.

.PARAMETER Status
    Report whether the panel answers, without changing anything.

.EXAMPLE
    start-superagent.cmd
    start-superagent.cmd -Restart
    start-superagent.cmd -Stop
    start-superagent.cmd -Status
#>
[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$Restart,
    [switch]$NoOpen,
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Paths and constants
# --------------------------------------------------------------------------
$Root      = $PSScriptRoot
$DshExe    = Join-Path $Root 'dsh-cli\dsh.cmd'
$Repo      = Join-Path $Root 'repo'
$LogFile   = Join-Path $Root 'superagent.log'
$ErrFile   = Join-Path $Root 'superagent.err.log'
$PidFile   = Join-Path $Root 'superagent.pid'
$Profile   = 'superagent'
$Port      = 3082

# Root-relative POSIX paths in the profile resolve against the drive the service
# is started from; keep every path computation on the same drive as this script.
$Drive     = [System.IO.Path]::GetPathRoot($Root).TrimEnd('\', '/')

# The WorkBuddy vault lives under DSH_HOME; keep the shared root unless the
# caller deliberately overrides it.
$DshHome = if ($env:SUPERAGENT_DSH_HOME) { $env:SUPERAGENT_DSH_HOME }
           elseif ($env:DSH_HOME)        { $env:DSH_HOME }
           else                          { Join-Path $env:USERPROFILE '.dsh' }

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host "  $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }

function Get-PortOwner([int]$LocalPort) {
    # netstat is available to a non-elevated user and needs no admin rights,
    # unlike Get-NetTCPConnection under some policies.
    $lines = & netstat -ano 2>$null | Select-String -Pattern ":$LocalPort\s+.*LISTENING"
    foreach ($line in $lines) {
        $parts = ($line.ToString().Trim() -split '\s+')
        $owner = $parts[-1]
        if ($owner -match '^\d+$') { return [int]$owner }
    }
    return $null
}

function Get-ProcessCommandLine([int]$ProcId) {
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcId" -ErrorAction Stop
        return [string]$p.CommandLine
    } catch { return '' }
}

function Test-IsOurs([int]$ProcId) {
    $cmd = Get-ProcessCommandLine $ProcId
    if (-not $cmd) { return $false }
    return ($cmd -match [regex]::Escape("--profile $Profile")) -or
           ($cmd -match [regex]::Escape($Profile) -and $cmd -match 'dsh')
}

function Get-StoredPid {
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    try {
        $raw = (Get-Content -LiteralPath $PidFile -Raw).Trim()
        if ($raw -match '^\d+$') { return [int]$raw }
    } catch { }
    return $null
}

function Test-PanelAnswers([int]$LocalPort = $Port, [int]$TimeoutSec = 2) {
    try {
        $null = Invoke-WebRequest -Uri "http://127.0.0.1:$LocalPort/orchestrator/api/state" `
            -Headers @{ 'x-orchestrator-request' = '1' } -UseBasicParsing `
            -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Get-PanelToken {
    if (-not (Test-Path -LiteralPath $LogFile)) { return $null }
    $text = Get-Content -LiteralPath $LogFile -Raw -ErrorAction SilentlyContinue
    if (-not $text) { return $null }
    $m = [regex]::Match($text, "http://127\.0\.0\.1:$Port/\?token=([A-Za-z0-9_\-]+)")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Open-Panel {
    $token = Get-PanelToken
    $url = if ($token) { "http://127.0.0.1:$Port/?token=$token" }
           else        { "http://127.0.0.1:$Port/" }
    Write-Host ''
    Write-Host "  Panel: $url" -ForegroundColor White
    if (-not $NoOpen) { Start-Process $url | Out-Null }
    return $url
}

function Get-StateDir {
    # The profile declares stateDir; read it back so this script never assumes a
    # path that could drift from cordis.patch.yml.
    $patch = Join-Path $DshHome "profiles\$Profile\cordis.patch.yml"
    if (Test-Path -LiteralPath $patch) {
        $m = [regex]::Match((Get-Content -LiteralPath $patch -Raw),
                            'stateDir:\s*["'']?([^"''\r\n#]+)')
        if ($m.Success) {
            $raw = $m.Groups[1].Value.Trim()
            # Root-relative POSIX form: resolve against the drive holding this
            # script (see the WorkingDirectory note in the start block).
            if ($raw -match '^/(?!/)') {
                return [System.IO.Path]::GetFullPath($Drive + '\' + $raw.TrimStart('/').Replace('/', '\'))
            }
            if ($raw -match '^//\?/(.+)$') {
                return $Matches[1].Replace('/', '\')
            }
            if ($raw -match '^[A-Za-z]:') { return $raw.Replace('/', '\') }
            return [System.IO.Path]::GetFullPath((Join-Path $Root $raw))
        }
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root 'state'))
}

function Clear-StaleLock {
    <#
      proper-lockfile guards <stateDir> by creating "<stateDir>.lock". A forced
      kill (which is what -Stop does, since the runtime offers no graceful stop
      on Windows) leaves that directory behind, and every later start then fails
      with "Lock file is already being held".

      Only remove it when no listener holds the port and no process of this
      profile is alive: an actively running instance must keep its lock.
    #>
    if (Get-PortOwner $Port) { return $false }
    $stored = Get-StoredPid
    if ($stored -and (Get-Process -Id $stored -ErrorAction SilentlyContinue)) { return $false }

    $stateDir = Get-StateDir
    $lockPath = $stateDir + '.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) { return $false }

    # Keep a copy so an unexpected removal can be investigated, but only the
    # most recent few: every -Stop on a running service produces one.
    $backup = "$lockPath.stale-" + (Get-Date -Format 'yyyyMMddHHmmss')
    try {
        Move-Item -LiteralPath $lockPath -Destination $backup -Force -ErrorAction Stop
        Write-Step "cleared a stale lock left by an earlier forced stop:"
        Write-Host "         $([System.IO.Path]::GetFileName($backup))" -ForegroundColor DarkGray
        $stale = @(Get-ChildItem -LiteralPath (Split-Path -Parent $lockPath) -Filter `
                    "$([System.IO.Path]::GetFileName($lockPath)).stale-*" -Force `
                    -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($stale.Count -gt 3) {
            $stale | Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        Write-Warn2 "Could not move the stale lock at $lockPath : $($_.Exception.Message)"
        return $false
    }
}

function Stop-Service {
    $targets = @()
    $owner = Get-PortOwner $Port
    if ($owner) { $targets += $owner }
    $stored = Get-StoredPid
    if ($stored -and ($targets -notcontains $stored)) { $targets += $stored }

    if (-not $targets) {
        Write-Step "Nothing is listening on port $Port."
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Clear-StaleLock | Out-Null
        return $true
    }

    foreach ($procId in $targets) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        if (-not (Test-IsOurs $procId)) {
            Write-Err2 "Port $Port is held by pid $procId ($($proc.ProcessName)), which is not this profile; refusing to kill it."
            return $false
        }
        Write-Step "Stopping pid $procId ($($proc.ProcessName)) ..."
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Get-PortOwner $Port)) { break }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    if (Get-PortOwner $Port) { Write-Err2 "Port $Port still held."; return $false }

    # The force-kill leaves the lock directory behind; clear it now so the next
    # start (or -Restart) is not blocked.
    Clear-StaleLock | Out-Null
    Write-Ok "Stopped; port $Port released."
    return $true
}

function Wait-Ready([int]$TimeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PanelAnswers $Port 2) { return $true }
        # Abort early only when nothing at all is left: the cmd wrapper exits as
        # soon as the node child is up, so the port is the real liveness signal.
        $anyAlive = (Get-PortOwner $Port) -or
                    (($stored = Get-StoredPid) -and (Get-Process -Id $stored -ErrorAction SilentlyContinue))
        if (-not $anyAlive) {
            # Give node a moment to bind before concluding it died.
            Start-Sleep -Milliseconds 1500
            if (-not (Get-PortOwner $Port)) {
                $stored = Get-StoredPid
                if (-not $stored -or -not (Get-Process -Id $stored -ErrorAction SilentlyContinue)) {
                    return $false
                }
            }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host '  dsh-superagent  |  one-click launcher' -ForegroundColor White
Write-Host '  official research prototype (not a DeepSeek product)' -ForegroundColor DarkGray
Write-Host '============================================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Step "Root      : $Root"
Write-Step "DSH_HOME  : $DshHome"
Write-Step "Port      : $Port"
Write-Host ''

if (-not (Test-Path -LiteralPath $DshExe)) {
    Write-Err2 "dsh CLI not found: $DshExe"
    Write-Host '         Reinstall it with:' -ForegroundColor Gray
    Write-Host "         npm install -g --prefix `"$Root\dsh-cli`" @deepseek-ai/dsh@0.2.1-rc.5" -ForegroundColor Gray
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $Repo 'lib\index.js'))) {
    Write-Err2 "Bundle not built: $(Join-Path $Repo 'lib\index.js') is missing."
    Write-Host '         Build it with (needs pnpm 11.7.0 via corepack):' -ForegroundColor Gray
    Write-Host "         cd `"$Repo`"; pnpm install; pnpm build" -ForegroundColor Gray
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $DshHome "profiles\$Profile\cordis.patch.yml"))) {
    Write-Err2 "Profile '$Profile' not found under $DshHome\profiles."
    Write-Host "         Recreate it with: dsh $Profile --from-default-profile web --dump-config > nul" -ForegroundColor Gray
    exit 1
}

# --------------------------------------------------------------------------
# Status / Stop / Restart
# --------------------------------------------------------------------------
if ($Status) {
    $answers = Test-PanelAnswers $Port 3
    $owner = Get-PortOwner $Port
    if ($answers) {
        Write-Ok "Panel answers on port $Port (pid $owner)."
        Open-Panel | Out-Null
        exit 0
    }
    if ($owner) { Write-Warn2 "Port $Port is held by pid $owner but the API does not answer." }
    else        { Write-Warn2 'Service is not running.' }
    exit 1
}

if ($Stop) {
    if (Stop-Service) { exit 0 } else { exit 1 }
}

if ($Restart) {
    if (-not (Stop-Service)) { exit 1 }
    Write-Host ''
}

# --------------------------------------------------------------------------
# Already running?  Then just open the panel (idempotent).
# --------------------------------------------------------------------------
if (Test-PanelAnswers $Port 3) {
    $owner = Get-PortOwner $Port
    Write-Ok "Already running (pid $owner) - opening the panel."
    Open-Panel | Out-Null
    exit 0
}

$owner = Get-PortOwner $Port
if ($owner) {
    Write-Warn2 "Port $Port is held by pid $owner but the panel does not answer."
    if (Test-IsOurs $owner) {
        Write-Step "It is this profile's process; replacing it."
        Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    } else {
        Write-Err2 "It belongs to another program. Free port $Port and retry, or set a different port in"
        Write-Host "         $DshHome\profiles\$Profile\cordis.patch.yml" -ForegroundColor Gray
        exit 1
    }
}

# --------------------------------------------------------------------------
# Start
# --------------------------------------------------------------------------
foreach ($f in @($LogFile, $ErrFile)) {
    if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

# An earlier forced stop may have left "<stateDir>.lock" behind; clear it before
# the runtime tries to acquire the lock itself.
Clear-StaleLock | Out-Null

$env:DSH_HOME = $DshHome

Write-Step 'Starting dsh --profile superagent ...'

# dsh.cmd is a batch wrapper that spawns node; the node child inherits whatever
# stdout/stderr handles the caller gave the wrapper, so Start-Process with
# -RedirectStandardOutput keeps this script's own stdout pipe open for as long
# as the service runs (a double-click works, but piped invocations hang).
#
# Win32_Process.Create detaches completely: the child gets no inherited handles,
# and cmd.exe performs the redirection to the log files itself.
$quotedDsh  = '"' + $DshExe + '"'
$quotedLog  = '"' + $LogFile + '"'
$quotedErr  = '"' + $ErrFile + '"'
$commandLine = 'cmd.exe /d /s /c "' + $quotedDsh + ' --profile ' + $Profile + ' --no-open' +
               ' > ' + $quotedLog + ' 2> ' + $quotedErr + '"'

# The child needs DSH_HOME; CIM inherits the creating process environment.
$env:DSH_HOME = $DshHome

$spawn = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine      = $commandLine
    # WorkingDirectory MUST be on the E: drive: the profile's stateDir is the
    # root-relative POSIX path /workspace/superagent/state, which Node resolves
    # against the current drive.
    CurrentDirectory = $Repo
}
if ($spawn.ReturnValue -ne 0) {
    Write-Err2 "Failed to start: Win32_Process.Create returned $($spawn.ReturnValue)"
    exit 1
}
$wrapperPid = [int]$spawn.ProcessId

Set-Content -LiteralPath $PidFile -Value $wrapperPid -Encoding ASCII
Write-Step "wrapper pid $wrapperPid; waiting for the panel (up to 90 s) ..."

if (-not (Wait-Ready 90)) {
    Write-Err2 'The panel did not answer.'
    if (Test-Path -LiteralPath $ErrFile) {
        Write-Host ''
        Write-Host '  --- last stderr lines ---' -ForegroundColor DarkGray
        Get-Content -LiteralPath $ErrFile -Tail 25 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Warn2 "Try: start-superagent.cmd -Restart   (logs: $LogFile / $ErrFile)"
    exit 1
}

Write-Ok 'Panel is up.'

# dsh.cmd is a batch wrapper: Start-Process returns the wrapper's pid, while the
# process actually owning the port is the node child. Record the listener so
# -Stop and -Restart act on the right process even if the wrapper is gone.
$listener = Get-PortOwner $Port
if ($listener) {
    Set-Content -LiteralPath $PidFile -Value $listener -Encoding ASCII
    Write-Step "listening pid $listener (recorded in $([System.IO.Path]::GetFileName($PidFile)))"
}

# --------------------------------------------------------------------------
# Report setup state (the launcher never fills settings for you)
# --------------------------------------------------------------------------
try {
    $state = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/orchestrator/api/state" `
        -Headers @{ 'x-orchestrator-request' = '1' } -TimeoutSec 10
    $problem = $state.setup.problem
    if ($problem) {
        Write-Warn2 "Setup still needs: $($problem.detail)"
        Write-Host "         Open the panel and fill it in (Sources / Policy / Execution)." -ForegroundColor Gray
    } else {
        Write-Ok 'Setup resolved; the agent is ready for requests.'
    }
} catch {
    Write-Warn2 'Could not read setup state (the API may still be warming up).'
}

$url = Open-Panel
Write-Host ''
Write-Host '  Next:' -ForegroundColor White
Write-Host '    * Sidebar -> Superagent  (panel)' -ForegroundColor Gray
Write-Host '    * Stop:    start-superagent.cmd -Stop' -ForegroundColor Gray
Write-Host '    * Restart: start-superagent.cmd -Restart' -ForegroundColor Gray
Write-Host '    * Status:  start-superagent.cmd -Status' -ForegroundColor Gray
Write-Host ''
exit 0
