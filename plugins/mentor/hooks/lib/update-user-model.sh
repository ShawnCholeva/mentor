#!/usr/bin/env bash
# update-user-model.sh — Updates the persistent user model using curl + jq
#                        (replaces update-user-model.py)
#
# Input:  JSON via stdin {user_model, recent_interactions, session_coaching, api_key}
# Output: none (atomically writes ~/.claude/coaching/user-model.json)
# Always exits 0. On any error, leaves existing file unchanged.

set -uo pipefail

COACHING_DIR="${HOME}/.claude/coaching"
USER_MODEL_FILE="${COACHING_DIR}/user-model.json"

# ─── Resolve jq ───────────────────────────────────────────────────────────────
JQ=$(command -v jq 2>/dev/null || echo "${COACHING_DIR}/bin/jq")
[[ ! -x "$JQ" ]] && exit 0

# ─── Read and parse stdin ─────────────────────────────────────────────────────
INPUT=$(cat)

USER_MODEL=$(         echo "$INPUT" | "$JQ" -c '.user_model          // {}' 2>/dev/null || echo "{}")
RECENT_INTERACTIONS=$(echo "$INPUT" | "$JQ" -c '.recent_interactions // []' 2>/dev/null || echo "[]")
SESSION_COACHING=$(   echo "$INPUT" | "$JQ" -c '.session_coaching     // {}' 2>/dev/null || echo "{}")
API_KEY=$(            echo "$INPUT" | "$JQ" -r '.api_key              // ""' 2>/dev/null || echo "")

# Skip if no interactions or no key
INTERACTION_COUNT=$(echo "$RECENT_INTERACTIONS" | "$JQ" 'length' 2>/dev/null || echo "0")
[[ "$INTERACTION_COUNT" -eq 0 || -z "$API_KEY" ]] && exit 0

# ─── Build prompt content ─────────────────────────────────────────────────────
CURRENT_MODEL_STR=$(echo "$USER_MODEL"          | "$JQ" '.' 2>/dev/null || echo "{}")
INTERACTIONS_STR=$( echo "$RECENT_INTERACTIONS" | "$JQ" '.' 2>/dev/null || echo "[]")
COACHING_STR=$(     echo "$SESSION_COACHING"    | "$JQ" '.' 2>/dev/null || echo "{}")

SYSTEM_PROMPT='You maintain a user profile for a Claude Code coaching system. Given the recent interaction history and current profile, produce an updated profile.

Rules:
1. strengths: patterns the user consistently does well. Add only when you see 3+ clear instances. Remove if contradicted by recent behavior.
2. weaknesses: patterns the user consistently struggles with. Same 3+ instance threshold. Be specific (e.g., "skips design phase on complex tasks" not "vague prompts").
3. current_focus: the single most impactful area for improvement right now. Update when the previous focus shows consistent improvement or a more pressing issue has emerged.
4. recent_progress: what has genuinely improved in the last 10 interactions. Be specific. Empty string if no clear progress.
5. intervention_history: append a brief summary of the latest coaching (type + topic, max 10 words). Keep only the last 20 entries total.
6. Be conservative. Small, incremental updates. Do not rewrite the whole profile based on a few interactions.
7. If the profile is empty, only populate based on clear evidence. Do not guess or extrapolate.
8. Do not add placeholder text like "none" or "n/a" — use empty string or empty array instead.

Respond with ONLY the updated JSON object. No markdown fences, no explanation, no trailing text.'

USER_MESSAGE="Current profile:
${CURRENT_MODEL_STR}

Recent interactions (last 20):
${INTERACTIONS_STR}

Latest session coaching:
${COACHING_STR}

Produce the updated profile JSON."

# ─── Build API request ────────────────────────────────────────────────────────
REQUEST=$("$JQ" -n \
    --arg system  "$SYSTEM_PROMPT" \
    --arg content "$USER_MESSAGE" \
    '{
        model:      "claude-haiku-4-5-20251001",
        max_tokens: 600,
        system:     $system,
        messages:   [{role: "user", content: $content}]
    }' 2>/dev/null) || exit 0

# ─── Detect HTTP client ───────────────────────────────────────────────────────
HTTP_CMD=""
command -v curl &>/dev/null && HTTP_CMD="curl"
[[ -z "$HTTP_CMD" ]] && command -v wget &>/dev/null && HTTP_CMD="wget"
[[ -z "$HTTP_CMD" ]] && exit 0

# ─── Call API ────────────────────────────────────────────────────────────────
TMPFILE=$(mktemp /tmp/mentor-update-XXXXXX.json)
printf '%s' "$REQUEST" > "$TMPFILE"

RESPONSE=""
if [[ "$HTTP_CMD" == "curl" ]]; then
    RESPONSE=$(curl -s --max-time 10 \
        -X POST "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: ${API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        --data-binary "@${TMPFILE}" 2>/dev/null) || true
else
    RESPONSE=$(wget -qO- --timeout=10 \
        --header="x-api-key: ${API_KEY}" \
        --header="anthropic-version: 2023-06-01" \
        --header="content-type: application/json" \
        --post-file="$TMPFILE" \
        "https://api.anthropic.com/v1/messages" 2>/dev/null) || true
fi

rm -f "$TMPFILE"
[[ -z "$RESPONSE" ]] && exit 0

# ─── Extract and parse response ───────────────────────────────────────────────
TEXT=$(echo "$RESPONSE" | "$JQ" -r '.content[0].text // ""' 2>/dev/null) || exit 0
[[ -z "$TEXT" || "$TEXT" == "null" ]] && exit 0

# Strip markdown fences if present
if [[ "$TEXT" == '```'* ]]; then
    TEXT=$(printf '%s' "$TEXT" | sed '1d' | sed '/^```$/d')
fi

# ─── Validate structure ────────────────────────────────────────────────────────
UPDATED=$(printf '%s' "$TEXT" | "$JQ" -e '
    select(type == "object")
    | {
        strengths:            (.strengths            // []),
        weaknesses:           (.weaknesses           // []),
        current_focus:        (.current_focus        // ""),
        recent_progress:      (.recent_progress      // ""),
        intervention_history: ((.intervention_history // [])[-20:])
      }' 2>/dev/null) || exit 0

# ─── Atomic write ────────────────────────────────────────────────────────────
mkdir -p "$COACHING_DIR"
TMPOUT=$(mktemp "${COACHING_DIR}/user-model-XXXXXX.tmp")
printf '%s\n' "$UPDATED" > "$TMPOUT" && mv "$TMPOUT" "$USER_MODEL_FILE" || rm -f "$TMPOUT"

exit 0
