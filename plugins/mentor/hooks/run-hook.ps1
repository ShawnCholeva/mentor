# run-hook.ps1 — Windows hook dispatcher for mentor plugin
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File run-hook.ps1 <hook-name>

param(
    [Parameter(Mandatory=$true)]
    [string]$HookName
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookScript = Join-Path $ScriptDir "$HookName.ps1"

if (Test-Path $HookScript) {
    & $HookScript
    exit $LASTEXITCODE
} else {
    Write-Error "Hook not found: $HookName"
    exit 1
}
