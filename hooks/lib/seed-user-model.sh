#!/usr/bin/env bash
# seed-user-model.sh — Seed the user model from insights facet data
#
# Input:  none (reads facets from ~/.claude/usage-data/facets/)
# Output: none (writes ~/.claude/coaching/user-model.json)
# Always exits 0. On any error, leaves existing file unchanged.
#
# Uses claude -p with Haiku to map insights friction/outcome data
# to user model fields (strengths, weaknesses, current_focus).

set -uo pipefail

COACHING_DIR="${HOME}/.claude/coaching"
USER_MODEL_FILE="${COACHING_DIR}/user-model.json"
FACETS_DIR="${HOME}/.claude/usage-data/facets"

# ─── Resolve jq ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bootstrap-jq.sh" 2>/dev/null || exit 0

# ─── Resolve claude CLI (hooks don't inherit full login shell PATH) ───────────
if ! command -v claude &>/dev/null; then
    for _try in \
        "$HOME/.local/bin/claude" \
        "$HOME/.claude/local/claude" \
        "/usr/local/bin/claude" \
        "/opt/homebrew/bin/claude"
    do
        if [[ -x "$_try" ]]; then
            export PATH="$(dirname "$_try"):${PATH}"
            break
        fi
    done
fi
command -v claude &>/dev/null || exit 0

# ─── Check facets exist ─────────────────────────────────────────────────────
[[ ! -d "$FACETS_DIR" ]] && exit 0
FACET_COUNT=$(find "$FACETS_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$FACET_COUNT" -eq 0 ]] && exit 0

# ─── Aggregate facets with Python ────────────────────────────────────────────
FACET_SUMMARY=$(python3 -c "
import json, glob, os
facets_dir = '${FACETS_DIR}'
files = glob.glob(os.path.join(facets_dir, '*.json'))

friction = {}
outcomes = {}
successes = {}
details = []

for f in files:
    try:
        with open(f) as fh:
            d = json.load(fh)
        for k, v in d.get('friction_counts', {}).items():
            friction[k] = friction.get(k, 0) + v
        o = d.get('outcome', 'unknown')
        outcomes[o] = outcomes.get(o, 0) + 1
        s = d.get('primary_success', '')
        if s and s != 'none':
            successes[s] = successes.get(s, 0) + 1
        detail = d.get('friction_detail', '')
        if detail:
            details.append(detail[:200])
    except Exception:
        continue

print(json.dumps({
    'total_sessions': len(files),
    'friction_counts': dict(sorted(friction.items(), key=lambda x: -x[1])),
    'outcomes': outcomes,
    'success_patterns': dict(sorted(successes.items(), key=lambda x: -x[1])[:5]),
    'friction_details': details[:10],
}))
" 2>/dev/null) || exit 0

[[ -z "$FACET_SUMMARY" ]] && exit 0

# ─── Call Claude to produce a seeded user model ──────────────────────────────
SYSTEM_PROMPT='You produce a user profile for a Claude Code coaching system, based on aggregated usage data from the /insights analysis tool.

Given a summary of the user'\''s session friction patterns, outcomes, and success patterns, produce a user model JSON object.

Rules:
1. Map high-frequency friction categories to weaknesses. Be specific — e.g., "submits vague requests without file paths or error context" not "vague prompts".
2. Map success patterns and fully_achieved outcomes to strengths. Only include if there are 3+ instances.
3. Set current_focus to the single highest-impact weakness.
4. Set recent_progress to empty string (no mentor observations yet).
5. Set intervention_history to empty array (no coaching has happened yet).
6. Be conservative. Only populate what the data clearly supports.
7. Include "seeded_from": "insights" at the top level.

Respond with ONLY the JSON object. No markdown fences, no explanation.'

USER_MESSAGE="Usage data summary from /insights analysis:
${FACET_SUMMARY}

Produce the user model JSON."

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
        seeded_from:          (.seeded_from          // "insights"),
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

echo "[$(date -Iseconds)] MENTOR-SEED seeded user model from ${FACET_COUNT} facets" >> "${COACHING_DIR}/hook-debug.log" 2>/dev/null || true

exit 0
