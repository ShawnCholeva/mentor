# stop-logger.ps1 — Stop hook for Windows (PowerShell)
# Part of mentor plugin (v3.0)
#
# Fires after every Claude response. Reads session state, counts turns,
# appends a JSONL interaction entry, and periodically updates the user model.
# Always exits 0.

$ErrorActionPreference = "SilentlyContinue"

$CoachingDir   = Join-Path $env:USERPROFILE ".claude\coaching"
$LogFile       = Join-Path $CoachingDir "interactions.jsonl"
$UserModelFile = Join-Path $CoachingDir "user-model.json"

New-Item -ItemType Directory -Force -Path $CoachingDir | Out-Null

# ─── Read stdin ───────────────────────────────────────────────────────────────
$rawInput = [Console]::In.ReadToEnd()
try { $payload = $rawInput | ConvertFrom-Json } catch { exit 0 }

$sessionId      = $payload.session_id
$transcriptPath = $payload.transcript_path
if (-not $sessionId) { exit 0 }

# ─── Read session state ───────────────────────────────────────────────────────
$stateFile        = Join-Path $CoachingDir "session-$sessionId.tmp"
$coachingTriggered = $false
$interventionType  = $null
$coachingMessage   = ""
$tags              = @()

if (Test-Path $stateFile) {
    try {
        $state             = Get-Content $stateFile -Raw | ConvertFrom-Json
        $coachingTriggered = [bool]$state.coaching_triggered
        $interventionType  = $state.type
        $coachingMessage   = $state.message
        $tags              = @($state.tags)
    } catch {}
    Remove-Item $stateFile -ErrorAction SilentlyContinue
}

# ─── Count user turns from transcript ────────────────────────────────────────
$turnCount = 1
if ($transcriptPath -and (Test-Path $transcriptPath)) {
    try {
        $matches = Select-String -Path $transcriptPath -Pattern '"role"\s*:\s*"user"' -AllMatches
        $c = $matches.Matches.Count
        if ($c -gt 0) { $turnCount = $c }
    } catch {}
}

# ─── Classify intent ─────────────────────────────────────────────────────────
$intent    = "unknown"
$skillUsed = $null

if ($transcriptPath -and (Test-Path $transcriptPath)) {
    try {
        $userLines = Select-String -Path $transcriptPath -Pattern '"role"\s*:\s*"user"'
        if ($userLines) {
            $lastLine = $userLines[-1].Line
            $lineObj  = $lastLine | ConvertFrom-Json
            $content  = if ($lineObj.message) { $lineObj.message.content } else { $lineObj.content }
            $lastPrompt = if ($content -is [array]) {
                ($content | ForEach-Object { $_.text } | Where-Object { $_ }) -join " "
            } else { [string]$content }
            $lastPrompt = if ($lastPrompt.Length -gt 500) { $lastPrompt.Substring(0,500) } else { $lastPrompt }

            if ($lastPrompt -match "^(/[a-z][a-z0-9:-]*)") {
                $skillUsed = $Matches[1]
                $intent    = "skill-invoked"
            }
            if ($intent -eq "unknown") {
                $wordCount = ($lastPrompt.Trim() -split '\s+').Count
                $intent = if ($wordCount -lt 6) { "vague" } else { "direct" }
            }
        }
    } catch {}
}

# ─── Generate entry ID ────────────────────────────────────────────────────────
$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$entryId   = [System.Guid]::NewGuid().ToString()

# ─── Build and append log entry ──────────────────────────────────────────────
$entry = [ordered]@{
    id                 = $entryId
    session_id         = $sessionId
    timestamp          = $timestamp
    intent             = $intent
    skill_used         = $skillUsed
    turn_count         = $turnCount
    coaching_triggered = $coachingTriggered
    intervention_type  = $interventionType
    tags               = $tags
}

$entryJson = $entry | ConvertTo-Json -Compress -Depth 5
Add-Content -Path $LogFile -Value $entryJson -ErrorAction SilentlyContinue

# ─── Trigger user model update every 5th interaction ─────────────────────────
$apiKey = $env:MENTOR_API_KEY
if ($apiKey) {
    $lineCount = (Get-Content $LogFile -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
    if ($lineCount -gt 0 -and ($lineCount % 5) -eq 0) {

        $userModel = [PSCustomObject]@{}
        if (Test-Path $UserModelFile) {
            try { $userModel = Get-Content $UserModelFile -Raw | ConvertFrom-Json } catch {}
        }

        # Read last 20 interaction lines as objects
        $recentLines = Get-Content $LogFile -ErrorAction SilentlyContinue | Select-Object -Last 20
        $recentInteractions = $recentLines | ForEach-Object {
            try { $_ | ConvertFrom-Json } catch { $null }
        } | Where-Object { $_ }

        $sessionCoaching = if ($coachingTriggered -and $interventionType) {
            @{ type = $interventionType; message = $coachingMessage }
        } else { @{} }

        # Build update prompt
        $currentModelStr  = $userModel | ConvertTo-Json -Depth 10
        $interactionsStr  = $recentInteractions | ConvertTo-Json -Depth 10
        $coachingStr      = $sessionCoaching | ConvertTo-Json -Depth 5

        $systemPrompt = @'
You maintain a user profile for a Claude Code coaching system. Given the recent interaction history and current profile, produce an updated profile.

Rules:
1. strengths/weaknesses: require 3+ instances before adding. Be specific.
2. current_focus: single most impactful improvement area.
3. recent_progress: what genuinely improved in last 10 interactions. Empty string if none.
4. intervention_history: append latest coaching summary (max 10 words). Keep last 20 only.
5. Be conservative. Incremental updates only.
6. Use empty string or empty array instead of "none"/"n/a".

Respond with ONLY the updated JSON object. No markdown, no explanation.
'@

        $userMessage = "Current profile:`n$currentModelStr`n`nRecent interactions (last 20):`n$interactionsStr`n`nLatest session coaching:`n$coachingStr`n`nProduce the updated profile JSON."

        # Fire-and-forget in a background job
        $jobScript = {
            param($apiKey, $systemPrompt, $userMessage, $userModelFile, $coachingDir)
            try {
                $requestBody = @{
                    model      = "claude-haiku-4-5-20251001"
                    max_tokens = 600
                    system     = $systemPrompt
                    messages   = @(@{ role = "user"; content = $userMessage })
                } | ConvertTo-Json -Depth 10

                $response = Invoke-RestMethod `
                    -Uri "https://api.anthropic.com/v1/messages" `
                    -Method POST `
                    -Headers @{ "x-api-key" = $apiKey; "anthropic-version" = "2023-06-01" } `
                    -ContentType "application/json" `
                    -Body $requestBody `
                    -TimeoutSec 10

                $text = $response.content[0].text.Trim()
                if ($text -match '^```') {
                    $text = ($text -split "`n" | Select-Object -Skip 1 | Where-Object { $_ -ne '```' }) -join "`n"
                }

                $updated = $text | ConvertFrom-Json
                $requiredKeys = @("strengths","weaknesses","current_focus","recent_progress","intervention_history")
                foreach ($k in $requiredKeys) {
                    if ($null -eq $updated.$k) { $updated | Add-Member -NotePropertyName $k -NotePropertyValue $(if($k -match "history|strengths|weaknesses"){@()}else{""}) }
                }
                # Cap intervention_history
                if ($updated.intervention_history.Count -gt 20) {
                    $updated.intervention_history = $updated.intervention_history | Select-Object -Last 20
                }

                # Atomic write via temp file
                $tmpFile = Join-Path $coachingDir ([System.IO.Path]::GetRandomFileName() + ".tmp")
                $updated | ConvertTo-Json -Depth 10 | Set-Content $tmpFile
                Move-Item $tmpFile $userModelFile -Force
            } catch {}
        }

        Start-Job -ScriptBlock $jobScript `
            -ArgumentList $apiKey, $systemPrompt, $userMessage, $UserModelFile, $CoachingDir | Out-Null
    }
}

exit 0
