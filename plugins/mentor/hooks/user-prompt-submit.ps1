# user-prompt-submit.ps1 — UserPromptSubmit hook for Windows (PowerShell)
# Part of mentor plugin (v3.0)
#
# Evaluates the user's prompt with Claude Haiku before it reaches Claude.
# On a high-confidence match, injects a coaching note as additionalContext.
# Always exits 0 — never blocks a prompt.

$ErrorActionPreference = "SilentlyContinue"

$CoachingDir   = Join-Path $env:USERPROFILE ".claude\coaching"
$ConfigFile    = Join-Path $CoachingDir "config.json"
$PhilosophyFile = Join-Path $CoachingDir "philosophy.md"
$UserModelFile = Join-Path $CoachingDir "user-model.json"
$WarnedFlag    = Join-Path $CoachingDir ".jq-missing-warned"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$DefaultsDir = Join-Path (Split-Path -Parent $ScriptDir) "defaults"

New-Item -ItemType Directory -Force -Path $CoachingDir | Out-Null

# ─── Read stdin ───────────────────────────────────────────────────────────────
$rawInput = [Console]::In.ReadToEnd()
try { $payload = $rawInput | ConvertFrom-Json } catch { exit 0 }

$prompt    = $payload.prompt
$sessionId = $payload.session_id
if (-not $prompt) { exit 0 }

# ─── Load settings ────────────────────────────────────────────────────────────
$enabled      = $true
$mode         = "chill"
$bootstrapMin = 20

if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($null -ne $cfg.enabled)       { $enabled      = [bool]$cfg.enabled }
        if ($cfg.mode)                    { $mode         = $cfg.mode }
        if ($null -ne $cfg.bootstrap_min) { $bootstrapMin = [int]$cfg.bootstrap_min }
    } catch {}
}
if (-not $enabled) { exit 0 }

# ─── Guard: skill invocations ─────────────────────────────────────────────────
if ($prompt -match "^/[a-z]") { exit 0 }

# ─── Guard: conversational affirmations ──────────────────────────────────────
$trimmed = ($prompt.Trim().ToLower() -replace '[^\w\s]', '').Trim()
$affirmations = @("yes","no","ok","okay","sure","yep","nope","yup","nah","agreed",
                  "correct","exactly","right","proceed","continue","go ahead","do it",
                  "sounds good","looks good","make it so","that works","perfect",
                  "great","fine","done","got it")
if ($affirmations -contains $trimmed) { exit 0 }

# ─── Guard: per-session cooldown (30s) ────────────────────────────────────────
$stateFile = Join-Path $CoachingDir "session-$sessionId.tmp"
if ($sessionId -and (Test-Path $stateFile)) {
    try {
        $state   = Get-Content $stateFile -Raw | ConvertFrom-Json
        $lastTs  = [long]$state.timestamp
        $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($nowEpoch - $lastTs) -lt 30) { exit 0 }
    } catch {}
}

# ─── Guard: API key required ──────────────────────────────────────────────────
$apiKey = $env:MENTOR_API_KEY
if (-not $apiKey) { exit 0 }

# ─── Bootstrap: seed defaults if missing ──────────────────────────────────────
if (-not (Test-Path $PhilosophyFile)) {
    $src = Join-Path $DefaultsDir "philosophy.md"
    if (Test-Path $src) { Copy-Item $src $PhilosophyFile -ErrorAction SilentlyContinue }
}
if (-not (Test-Path $UserModelFile)) {
    '{"strengths":[],"weaknesses":[],"current_focus":"","recent_progress":"","intervention_history":[]}' |
        Set-Content $UserModelFile -ErrorAction SilentlyContinue
}

# ─── Load philosophy and user model ──────────────────────────────────────────
$philosophy = ""
if (Test-Path $PhilosophyFile) { $philosophy = Get-Content $PhilosophyFile -Raw -ErrorAction SilentlyContinue }

$userModel = [PSCustomObject]@{}
if (Test-Path $UserModelFile) {
    try { $userModel = Get-Content $UserModelFile -Raw | ConvertFrom-Json } catch {}
}

# ─── Build user model section ─────────────────────────────────────────────────
$hasModel = ($userModel.strengths.Count -gt 0) -or
            ($userModel.weaknesses.Count -gt 0) -or
            ($userModel.current_focus -and $userModel.current_focus.Length -gt 0)

if ($hasModel) {
    $strengths  = $userModel.strengths  -join ", "
    $weaknesses = $userModel.weaknesses -join ", "
    $focus      = $userModel.current_focus
    $progress   = $userModel.recent_progress
    $modelSection = "## User Profile`nStrengths: $strengths`nWeaknesses: $weaknesses`nCurrent focus: $focus`nRecent progress: $progress"
} else {
    $modelSection = "## User Profile`nNo profile yet — this is a new user. Be conservative with interventions."
}

$philoText = if ($philosophy) { $philosophy } else { "Clarity upfront is better than iteration later. Think in systems, not tasks." }
$promptTrunc = if ($prompt.Length -gt 500) { $prompt.Substring(0, 500) } else { $prompt }

# ─── Build system prompt ──────────────────────────────────────────────────────
$systemPrompt = @"
You are a coaching evaluator for a Claude Code operator. Your job is to decide whether to intervene on a user's prompt before it reaches Claude.

## Philosophy
$philoText

$modelSection
## Intervention Types
- nudge: Light suggestion. Small improvement opportunity.
- correction: Clear mistake worth addressing.
- challenge: Strong pushback. Use when the user's thinking is flawed.
- reinforcement: Positive feedback for demonstrated growth.

## Rules
1. Default to NOT intervening. Only intervene when you have high confidence.
2. Never intervene on skill invocations (prompts starting with /).
3. Never intervene on short affirmative responses.
4. Reinforcement should fire roughly 1 in 10 interventions.
5. Keep messages under 30 words. Be direct, not preachy.
6. Mode is "$mode". In "chill" mode, only high-confidence issues. In "elite" mode, also subtler issues.
7. Prefer one precise observation over multiple generic suggestions.

Respond with ONLY a JSON object:
{"intervene": false}
or
{"intervene": true, "type": "nudge|correction|challenge|reinforcement", "message": "coaching message"}
"@

$userMessage = "Evaluate this prompt:`n---`n$promptTrunc`n---"
$modelName   = if ($mode -eq "elite") { "claude-sonnet-4-6" } else { "claude-haiku-4-5-20251001" }

# ─── Call Claude API ──────────────────────────────────────────────────────────
$judgment = $null
try {
    $requestBody = @{
        model      = $modelName
        max_tokens = 150
        system     = $systemPrompt
        messages   = @(@{ role = "user"; content = $userMessage })
    }

    $response = Invoke-RestMethod `
        -Uri "https://api.anthropic.com/v1/messages" `
        -Method POST `
        -Headers @{ "x-api-key" = $apiKey; "anthropic-version" = "2023-06-01" } `
        -ContentType "application/json" `
        -Body ($requestBody | ConvertTo-Json -Depth 10) `
        -TimeoutSec 5

    $text = $response.content[0].text.Trim()

    # Strip markdown fences if present
    if ($text -match '^```') {
        $text = ($text -split "`n" | Select-Object -Skip 1 | Where-Object { $_ -ne '```' }) -join "`n"
    }

    $judgment = $text | ConvertFrom-Json
} catch {
    exit 0
}

if (-not $judgment -or -not $judgment.intervene) { exit 0 }

$interventionType = $judgment.type
$feedback         = $judgment.message
if (-not $feedback) { exit 0 }

$validTypes = @("nudge","correction","challenge","reinforcement")
if ($interventionType -notin $validTypes) { exit 0 }

# ─── Write session state (epoch timestamp) ───────────────────────────────────
$nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
@{
    coaching_triggered = $true
    type               = $interventionType
    tags               = @($interventionType)
    message            = $feedback
    timestamp          = $nowEpoch
} | ConvertTo-Json | Set-Content $stateFile -ErrorAction SilentlyContinue

# ─── Format coaching message ─────────────────────────────────────────────────
$prefix = switch ($interventionType) {
    "nudge"         { "💡 Mentor (nudge):" }
    "correction"    { "⚡ Mentor:" }
    "challenge"     { "🔥 Mentor (pushback):" }
    "reinforcement" { "✅ Mentor:" }
    default         { "💡 Mentor:" }
}

$fullMsg = "$prefix $feedback"
$context = "<prompt-coaching-note>`nBefore responding, output this exact line verbatim, then proceed with your answer:`n`n$fullMsg`n</prompt-coaching-note>"

# ─── Output hookSpecificOutput ────────────────────────────────────────────────
@{
    hookSpecificOutput = @{
        hookEventName   = "UserPromptSubmit"
        additionalContext = $context
    }
} | ConvertTo-Json -Depth 5

exit 0
