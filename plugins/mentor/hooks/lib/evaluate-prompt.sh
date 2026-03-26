#!/usr/bin/env bash
# evaluate-prompt.sh — Prompt evaluator using curl + jq (replaces evaluate-prompt.py)
#
# Input:  JSON via stdin {prompt, mode, philosophy, user_model, api_key}
# Output: JSON judgment  {intervene: bool, [type, message]}
# Always exits 0. On any error outputs {"intervene":false}.

set -uo pipefail

FALLBACK='{"intervene":false}'

# ─── Resolve jq ───────────────────────────────────────────────────────────────
JQ=$(command -v jq 2>/dev/null || echo "${HOME}/.claude/coaching/bin/jq")
if [[ ! -x "$JQ" ]]; then
    echo "$FALLBACK"
    exit 0
fi

# ─── Read and parse stdin ─────────────────────────────────────────────────────
INPUT=$(cat)

PROMPT=$(      echo "$INPUT" | "$JQ" -r '.prompt      // ""'      2>/dev/null || echo "")
MODE=$(         echo "$INPUT" | "$JQ" -r '.mode        // "chill"' 2>/dev/null || echo "chill")
PHILOSOPHY=$(   echo "$INPUT" | "$JQ" -r '.philosophy  // ""'      2>/dev/null || echo "")
USER_MODEL=$(   echo "$INPUT" | "$JQ" -c '.user_model  // {}'      2>/dev/null || echo "{}")
API_KEY=$(      echo "$INPUT" | "$JQ" -r '.api_key     // ""'      2>/dev/null || echo "")

[[ -z "$PROMPT" || -z "$API_KEY" ]] && { echo "$FALLBACK"; exit 0; }

# ─── Select model ─────────────────────────────────────────────────────────────
if [[ "$MODE" == "elite" ]]; then
    MODEL="claude-sonnet-4-6"
else
    MODEL="claude-haiku-4-5-20251001"
fi

# ─── Build user model section ─────────────────────────────────────────────────
HAS_MODEL=$(echo "$USER_MODEL" | "$JQ" -r '
    if ((.strengths | length) > 0)
       or ((.weaknesses | length) > 0)
       or (.current_focus | length > 0)
    then "true" else "false" end' 2>/dev/null || echo "false")

if [[ "$HAS_MODEL" == "true" ]]; then
    STRENGTHS=$(echo "$USER_MODEL" | "$JQ" -r '.strengths  | join(", ")' 2>/dev/null || echo "")
    WEAKNESSES=$(echo "$USER_MODEL" | "$JQ" -r '.weaknesses | join(", ")' 2>/dev/null || echo "")
    FOCUS=$(     echo "$USER_MODEL" | "$JQ" -r '.current_focus   // ""'   2>/dev/null || echo "")
    PROGRESS=$(  echo "$USER_MODEL" | "$JQ" -r '.recent_progress // ""'   2>/dev/null || echo "")
    MODEL_SECTION="## User Profile
Strengths: ${STRENGTHS}
Weaknesses: ${WEAKNESSES}
Current focus: ${FOCUS}
Recent progress: ${PROGRESS}"
else
    MODEL_SECTION="## User Profile
No profile yet — this is a new user. Be conservative with interventions."
fi

PHILO_TEXT="${PHILOSOPHY:-Clarity upfront is better than iteration later. Think in systems, not tasks.}"

# Truncate prompt to 500 chars
PROMPT_TRUNC="${PROMPT:0:500}"

SYSTEM_PROMPT="You are a coaching evaluator for a Claude Code operator. Your job is to decide whether to intervene on a user's prompt before it reaches Claude.

## Philosophy
${PHILO_TEXT}

${MODEL_SECTION}
## Intervention Types
- nudge: Light suggestion. Small improvement opportunity. Use when the prompt is okay but could be better.
- correction: Clear mistake worth addressing. Use when the prompt has a specific flaw that will lead to a worse outcome.
- challenge: Strong pushback. Use when the user's thinking is flawed or they are approaching the problem wrong.
- reinforcement: Positive feedback. Use when the prompt demonstrates growth in an area the user previously struggled with.

## Rules
1. Default to NOT intervening. Most prompts are fine. Only intervene when you have high confidence.
2. Never intervene on skill invocations (prompts starting with /).
3. Never intervene on short affirmative responses (yes, no, ok, proceed, sure, etc.).
4. Reinforcement should fire roughly 1 in 10 interventions.
5. Keep messages under 30 words. Be direct, not preachy. Do not moralize.
6. If the user profile has a current_focus, weight your evaluation toward that area.
7. Consider the user's strengths — do not coach on things they already do well.
8. Mode is \"${MODE}\". In \"chill\" mode, only intervene on high-confidence issues (vague prompts, missing diagnostics). In \"elite\" mode, also intervene on subtler issues (missing output format, scope underestimation).
9. When you challenge, explain WHY the thinking is flawed — not just what to fix.
10. Prefer one precise observation over multiple generic suggestions.

Respond with ONLY a JSON object, no markdown, no explanation:
{\"intervene\": false}
or
{\"intervene\": true, \"type\": \"nudge|correction|challenge|reinforcement\", \"message\": \"your coaching message here\"}"

USER_MESSAGE="Evaluate this prompt:
---
${PROMPT_TRUNC}
---"

# ─── Build API request (jq handles all escaping) ──────────────────────────────
REQUEST=$("$JQ" -n \
    --arg model   "$MODEL" \
    --arg system  "$SYSTEM_PROMPT" \
    --arg content "$USER_MESSAGE" \
    '{
        model:      $model,
        max_tokens: 150,
        system:     $system,
        messages:   [{role: "user", content: $content}]
    }' 2>/dev/null) || { echo "$FALLBACK"; exit 0; }

# ─── Detect HTTP client ───────────────────────────────────────────────────────
HTTP_CMD=""
command -v curl &>/dev/null && HTTP_CMD="curl"
[[ -z "$HTTP_CMD" ]] && command -v wget &>/dev/null && HTTP_CMD="wget"
[[ -z "$HTTP_CMD" ]] && { echo "$FALLBACK"; exit 0; }

# ─── Call API (write request to temp file to avoid shell quoting issues) ─────
TMPFILE=$(mktemp /tmp/mentor-eval-XXXXXX.json)
printf '%s' "$REQUEST" > "$TMPFILE"

RESPONSE=""
if [[ "$HTTP_CMD" == "curl" ]]; then
    RESPONSE=$(curl -s --max-time 5 \
        -X POST "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: ${API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data-binary "@${TMPFILE}" 2>/dev/null) || true
else
    RESPONSE=$(wget -qO- --timeout=5 \
        --header="x-api-key: ${API_KEY}" \
        --header="anthropic-version: 2023-06-01" \
        --header="content-type: application/json" \
        --post-file="$TMPFILE" \
        "https://api.anthropic.com/v1/messages" 2>/dev/null) || true
fi

rm -f "$TMPFILE"

[[ -z "$RESPONSE" ]] && { echo "$FALLBACK"; exit 0; }

# ─── Extract text from API response ──────────────────────────────────────────
TEXT=$(echo "$RESPONSE" | "$JQ" -r '.content[0].text // ""' 2>/dev/null) || { echo "$FALLBACK"; exit 0; }
[[ -z "$TEXT" || "$TEXT" == "null" ]] && { echo "$FALLBACK"; exit 0; }

# Strip markdown fences if present
if [[ "$TEXT" == '```'* ]]; then
    TEXT=$(printf '%s' "$TEXT" | sed '1d' | sed '/^```$/d')
fi

# ─── Parse and validate judgment ─────────────────────────────────────────────
JUDGMENT=$(printf '%s' "$TEXT" | "$JQ" -e '
    if type != "object" then error("not object")
    elif .intervene == false then {intervene: false}
    elif (.intervene == true
          and (.type | IN("nudge","correction","challenge","reinforcement"))
          and (.message | type == "string" and length > 0))
    then {intervene: true, type: .type, message: .message}
    else error("invalid")
    end' 2>/dev/null) || { echo "$FALLBACK"; exit 0; }

echo "$JUDGMENT"
exit 0
