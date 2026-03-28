#!/usr/bin/env bash
# update-user-model.sh — Updates the persistent user model using claude -p
#
# Input:  JSON via stdin {user_model, recent_interactions, session_coaching}
# Output: none (atomically writes ~/.claude/coaching/user-model.json)
# Always exits 0. On any error, leaves existing file unchanged.

set -uo pipefail

COACHING_DIR="${HOME}/.claude/coaching"
USER_MODEL_FILE="${COACHING_DIR}/user-model.json"

# ─── Resolve jq ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bootstrap-jq.sh" 2>/dev/null || exit 0

# ─── Read and parse stdin ─────────────────────────────────────────────────────
INPUT=$(cat)

USER_MODEL=$(         echo "$INPUT" | "$JQ" -c '.user_model          // {}' 2>/dev/null || echo "{}")
RECENT_INTERACTIONS=$(echo "$INPUT" | "$JQ" -c '.recent_interactions // []' 2>/dev/null || echo "[]")
SESSION_COACHING=$(   echo "$INPUT" | "$JQ" -c '.session_coaching     // {}' 2>/dev/null || echo "{}")

# Skip if no interactions
INTERACTION_COUNT=$(echo "$RECENT_INTERACTIONS" | "$JQ" 'length' 2>/dev/null || echo "0")
[[ "$INTERACTION_COUNT" -eq 0 ]] && exit 0

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

# ─── Call Claude via CLI ─────────────────────────────────────────────────────
TEXT=$(printf '%s' "$USER_MESSAGE" | MENTOR_INTERNAL=1 timeout 10 claude -p \
    --model "claude-haiku-4-5-20251001" \
    --system-prompt "$SYSTEM_PROMPT" \
    --no-session-persistence 2>/dev/null) || true

[[ -z "$TEXT" ]] && exit 0

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
