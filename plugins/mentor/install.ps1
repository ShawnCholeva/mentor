# install.ps1 — Mentor plugin setup for Windows (PowerShell)
#
# What this does:
#   1. Creates $env:USERPROFILE\.claude\coaching\ directory structure
#   2. Seeds default config files if missing
#   3. Copies hooks-windows.json over hooks.json so Claude Code uses PS hooks
#   4. Verifies PowerShell version is adequate (5.1+)
#
# Usage (from the plugin root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#
# Or if already in an unrestricted PS session:
#   .\install.ps1

$ErrorActionPreference = "Stop"

function Write-Info  { param($msg) Write-Host "[mentor] $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "[mentor] $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "[mentor] $msg" -ForegroundColor Red }

# ─── Step 1: PowerShell version check ────────────────────────────────────────
$psVersion = $PSVersionTable.PSVersion.Major
if ($psVersion -lt 5) {
    Write-Err "PowerShell 5.1 or later is required (found $psVersion)."
    Write-Err "Download from: https://github.com/PowerShell/PowerShell/releases"
    exit 1
}
Write-Info "PowerShell $($PSVersionTable.PSVersion) — OK"

# ─── Step 2: Create directory structure ──────────────────────────────────────
$CoachingDir = Join-Path $env:USERPROFILE ".claude\coaching"
Write-Info "Creating $CoachingDir ..."
New-Item -ItemType Directory -Force -Path $CoachingDir | Out-Null

# ─── Step 3: Seed default files if missing ────────────────────────────────────
$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$DefaultsDir    = Join-Path $ScriptDir "defaults"
$PhilosophyFile = Join-Path $CoachingDir "philosophy.md"
$UserModelFile  = Join-Path $CoachingDir "user-model.json"
$ConfigFile     = Join-Path $CoachingDir "config.json"

if (-not (Test-Path $PhilosophyFile)) {
    $srcPhilosophy = Join-Path $DefaultsDir "philosophy.md"
    if (Test-Path $srcPhilosophy) {
        Copy-Item $srcPhilosophy $PhilosophyFile
        Write-Info "Seeded philosophy.md from defaults"
    }
}

if (-not (Test-Path $UserModelFile)) {
    '{"strengths":[],"weaknesses":[],"current_focus":"","recent_progress":"","intervention_history":[]}' |
        Set-Content $UserModelFile
    Write-Info "Created empty user-model.json"
}

if (-not (Test-Path $ConfigFile)) {
    '{"enabled":true,"mode":"chill","bootstrap_min":20}' | Set-Content $ConfigFile
    Write-Info "Created default config.json"
}

# ─── Step 4: Install Windows hooks.json ──────────────────────────────────────
$HooksDir        = Join-Path $ScriptDir "hooks"
$WindowsHooks    = Join-Path $HooksDir "hooks-windows.json"
$ActiveHooks     = Join-Path $HooksDir "hooks.json"

if (Test-Path $WindowsHooks) {
    Copy-Item $WindowsHooks $ActiveHooks -Force
    Write-Info "Installed hooks-windows.json as hooks.json"
} else {
    Write-Warn "hooks-windows.json not found — hooks.json unchanged"
}

# ─── Step 5: Verify Invoke-RestMethod is available ────────────────────────────
try {
    $null = Get-Command Invoke-RestMethod -ErrorAction Stop
    Write-Info "Invoke-RestMethod available — API calls will work"
} catch {
    Write-Warn "Invoke-RestMethod not found. HTTP API calls may fail."
}

# ─── Done ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Mentor plugin installed successfully (Windows)."
Write-Info ""
Write-Info "Next steps:"
Write-Info "  1. Set your API key:"
Write-Info "       `$env:MENTOR_API_KEY = 'sk-ant-...'"
Write-Info "     To persist across sessions, add to your PowerShell profile:"
Write-Info "       Add-Content `$PROFILE '`$env:MENTOR_API_KEY = `"sk-ant-...`"'"
Write-Info "  2. Reload Claude Code plugins: /reload-plugins"
Write-Info "  3. Check status: /mentor status"
