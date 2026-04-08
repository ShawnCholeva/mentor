#!/usr/bin/env bash
# evaluate-prompt.sh — Prompt evaluator using claude -p
#
# Input:  JSON via stdin {prompt, mode, philosophy, user_model, history}
# Output: JSON judgment  {intervene: bool, [type, message, friction?, skill_suggested?, skill_gap_description?]}
# Always exits 0. On any error outputs {"intervene":false}.

set -uo pipefail

FALLBACK='{"intervene":false}'

# ─── Resolve jq ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bootstrap-jq.sh" 2>/dev/null || { echo "$FALLBACK"; exit 0; }

# ─── Resolve claude CLI (hooks don't inherit full login shell PATH) ───────────
# Try common install locations if 'claude' isn't on the current PATH.
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
command -v claude &>/dev/null || { echo "$FALLBACK"; exit 0; }

# ─── Read and parse stdin ─────────────────────────────────────────────────────
INPUT=$(cat)

PROMPT=$(      echo "$INPUT" | "$JQ" -r '.prompt      // ""'      2>/dev/null || echo "")
MODE=$(         echo "$INPUT" | "$JQ" -r '.mode        // "chill"' 2>/dev/null || echo "chill")
PHILOSOPHY=$(   echo "$INPUT" | "$JQ" -r '.philosophy  // ""'      2>/dev/null || echo "")
USER_MODEL=$(   echo "$INPUT" | "$JQ" -c '.user_model  // {}'      2>/dev/null || echo "{}")
HISTORY=$(      echo "$INPUT" | "$JQ" -r '.history     // [] | .[]' 2>/dev/null || echo "")
TURN_COUNT=$(   echo "$INPUT" | "$JQ" '.history // [] | length'         2>/dev/null || echo "0")
SKILL_CATALOG=$(echo "$INPUT" | "$JQ" -c '.skill_catalog // []' 2>/dev/null || echo "[]")

[[ -z "$PROMPT" ]] && { echo "$FALLBACK"; exit 0; }

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
    INTERVENTION_HIST=$(echo "$USER_MODEL" | "$JQ" -r '
        (.intervention_history // [])[-10:] |
        if length > 0 then
            map("- " + .) | join("\n")
        else
            "No coaching history yet."
        end' 2>/dev/null || echo "No coaching history yet.")
    MODEL_SECTION="## User Profile
Strengths: ${STRENGTHS}
Weaknesses: ${WEAKNESSES}
Current focus: ${FOCUS}
Recent progress: ${PROGRESS}

Intervention history (recent coaching):
${INTERVENTION_HIST}"
else
    MODEL_SECTION="## User Profile
No profile yet — this is a new user. Be conservative with interventions."
fi

# ─── Build priority weights section (from insights sync) ────────────────────
PRIORITY_SECTION=""
PRIORITY_WEIGHTS_FILE="${HOME}/.claude/coaching/priority-weights.json"
if [[ -f "$PRIORITY_WEIGHTS_FILE" ]]; then
    PRIORITY_LIST=$(cat "$PRIORITY_WEIGHTS_FILE" 2>/dev/null | "$JQ" -r '
        .top_friction // [] |
        map("- " + .pattern + " (" + .weight + " priority — " + (.count | tostring) + " occurrences across sessions)") |
        join("\n")' 2>/dev/null || echo "")
    if [[ -n "$PRIORITY_LIST" ]]; then
        PRIORITY_SECTION="## Priority Patterns (from usage analysis)
Your attention should be weighted toward these friction patterns:
${PRIORITY_LIST}
Be more sensitive to these patterns. Lower-priority issues can still trigger interventions but require higher confidence."
    fi
fi

# ─── Build skill catalog section ─────────────────────────────────────────────
SKILL_SECTION=""
SKILL_COUNT=$(echo "$SKILL_CATALOG" | "$JQ" 'length' 2>/dev/null || echo "0")
if [[ "$SKILL_COUNT" -gt 0 ]]; then
    SKILL_LIST=$(echo "$SKILL_CATALOG" | "$JQ" -r '.[] | "- /" + .name + " — " + .trigger' 2>/dev/null || echo "")
    if [[ -n "$SKILL_LIST" ]]; then
        SKILL_SECTION="## Available Skills
The user has these skills installed. When their prompt describes work that matches a skill's trigger and they did not invoke it (no / prefix), weave a suggestion into your coaching message.

${SKILL_LIST}"
    fi
fi

PHILO_TEXT="${PHILOSOPHY:-Clarity upfront is better than iteration later. Think in systems, not tasks.}"

# Truncate prompt to 500 chars
PROMPT_TRUNC="${PROMPT:0:500}"

SYSTEM_PROMPT="You are a prompt coach for a Claude Code user. You evaluate their prompt and decide whether to offer guidance before it reaches Claude. Your voice is warm but honest — like an encouraging mentor who believes in the user's growth and helps them see gaps for themselves.

## Philosophy
${PHILO_TEXT}

${MODEL_SECTION}
${PRIORITY_SECTION:+${PRIORITY_SECTION}

}${SKILL_SECTION:+${SKILL_SECTION}

}## Intervention Types
- nudge: Light suggestion. The prompt is okay but could be better. Tone: friendly pointer.
- correction: Clear gap worth addressing. The prompt has a flaw that will lead to a worse outcome. Tone: constructive, specific.
- challenge: Strong pushback. The user's approach or thinking has a real problem. Tone: direct but respectful — explain WHY the thinking is flawed, not just what to fix.
- reinforcement: Positive feedback. The prompt shows real growth in an area the user previously struggled with. Tone: genuine, specific praise — name what improved and why it matters.

## Message Format
Structure your coaching message naturally using these elements (not as labeled sections — weave them together):
1. **Acknowledge** what's working or where they've grown (skip if nothing applies)
2. **Name the gap** and explain WHY it matters — what will go wrong or be slower without the fix
3. **Show a better version** — rewrite their prompt or show what a stronger version looks like
4. **Close with a question** that helps them internalize the principle, not just follow the rule

Keep messages under 100 words. Write like a person, not a linter. Vary your phrasing — never start multiple messages the same way. Use contractions. No bullet points or labeled fields in the output.

## Rules
1. Default to NOT intervening. Most prompts are fine. Only intervene when you have high confidence.
2. Never intervene on skill invocations (prompts starting with /).
3. Never intervene on short affirmative responses (yes, no, ok, proceed, sure, etc.).
4. Reinforcement should fire roughly 1 in 10 interventions.
5. If the user profile has a current_focus, weight your evaluation toward that area.
6. Consider the user's strengths — do not coach on things they already do well.
7. Mode is \"${MODE}\". In \"chill\" mode, only intervene on high-confidence issues (vague prompts, missing diagnostics). In \"elite\" mode, also intervene on subtler issues (missing output format, scope underestimation).
8. Prefer one precise observation over multiple generic suggestions.
9. If you notice a pattern across the recent prompt history (repeated vagueness, improving specificity, etc.), weave that observation in naturally. Do not start with \"Pattern:\" or label it mechanically.

## Friction Categories
When you intervene, classify the friction type and tailor your message accordingly. Include a \"friction\" field in your JSON response.

- vague_request: The prompt lacks specifics — no file paths, no expected behavior, no error output. Coach toward: what file, expected vs actual behavior, and any error output.
- wrong_approach: The user is heading down a path that won't work or is inefficient. Coach toward: stepping back, checking docs, or rethinking the strategy.
- missing_diagnostics: The user is debugging without sharing error messages, logs, or relevant file paths. Coach toward: sharing the error output and relevant context before Claude starts exploring.
- scope_drift: The task has grown beyond what was originally asked or the user is trying to do too much at once. Coach toward: scoping down, breaking into smaller pieces, or resetting.
- missing_skill: The prompt describes work that matches a known skill pattern (debugging, testing, design, code review) but no skill was invoked. Coach toward: the specific skill category that would help.

If the issue doesn't fit any category, omit the friction field entirely. Do not force a classification.

## Reinforcement Triggers
Fire reinforcement when you see genuine growth:
- The user previously struggled with something (see intervention history) and this prompt shows improvement in that area. Name the specific improvement — e.g., \"You included the error output and file path this time — that's exactly what was missing in your last few prompts.\"
- The prompt exemplifies a philosophy principle well. Name which principle and why it matters.
- The user invoked a relevant skill before starting work, especially if this is a new behavior.

Reinforcement messages must reference the specific improvement. Generic praise (\"Good prompt!\", \"Nice work!\") is worse than no reinforcement — it teaches the user nothing. Be specific about WHAT improved and WHY it matters.

## Skill Awareness
When the user's prompt describes work that matches an installed skill (see Available Skills above) and they did not invoke it (no / prefix):
- Set \"skill_suggested\": \"/skill-name\" in your response
- Weave the suggestion naturally into your coaching message — explain why this skill would help for their specific task, don't just name-drop it

When the prompt describes work that NO installed skill covers, but a skill would clearly help (recurring task type, complex workflow, structured process):
- Set \"skill_gap_description\" with a one-sentence sketch of what the skill would do and when it would trigger
- Only mention the gap in your coaching message if confidence is high — otherwise just log it for recap analysis

Do not set both fields on the same prompt. Either an existing skill fits, or none does.

## Conversation Awareness
This is turn ${TURN_COUNT} of the conversation (${TURN_COUNT} previous prompts in session history).

IMPORTANT: You cannot see Claude's responses — only the user's prompts. This means you CANNOT judge whether a prompt adequately answers a question Claude asked. Assume short mid-conversation prompts are valid responses to something Claude said.

If turn count > 1, the user is mid-conversation. Claude already has the full conversation context.
- References to prior discussion (\"option 1\", \"the first one\", \"tell me more\", \"that approach\", \"both\", \"yes do X\", \"I'd like to see\") are normal follow-ups. Do NOT flag these as lacking context.
- Short prompts (under 10 words) at turn > 1 are almost always conversational — answering Claude's question, picking an option, confirming a direction. Do NOT intervene on these unless they indicate clear scope creep or a dangerous approach.
- \"Missing context\" or \"vague\" is NEVER a valid reason to intervene after turn 1. Claude has the full conversation — you don't. Trust that context exists even if you can't see it.
- Only intervene on mid-conversation prompts for substantive issues: scope creep, missing diagnostics for an active debugging task, or a fundamentally flawed technical approach. When in doubt, do not intervene.

Respond with ONLY a JSON object, no markdown, no explanation:
{\"intervene\": false}
or
{\"intervene\": true, \"type\": \"nudge|correction|challenge|reinforcement\", \"message\": \"your coaching message here\", \"friction\": \"vague_request|wrong_approach|missing_diagnostics|scope_drift|missing_skill\", \"skill_suggested\": \"/skill-name\", \"skill_gap_description\": \"one-sentence sketch\"}
The \"friction\", \"skill_suggested\", and \"skill_gap_description\" fields are optional — include them only when applicable. Do not set both skill_suggested and skill_gap_description on the same response."

# ─── Build user message with optional history ────────────────────────────────
if [[ -n "$HISTORY" ]]; then
    HISTORY_NUMBERED=""
    IDX=1
    while IFS= read -r line; do
        HISTORY_NUMBERED="${HISTORY_NUMBERED}${IDX}. ${line:0:500}
"
        IDX=$((IDX + 1))
    done <<< "$HISTORY"

    USER_MESSAGE="Recent prompts in this session:
${HISTORY_NUMBERED}---
Evaluate this prompt:
---
${PROMPT_TRUNC}
---"
else
    USER_MESSAGE="Evaluate this prompt:
---
${PROMPT_TRUNC}
---"
fi

# ─── Call Claude via CLI ─────────────────────────────────────────────────────
# --setting-sources "" strips plugin/user-level system prompt injection
# cd /tmp prevents CLAUDE.md from the project dir being loaded
# Together these give an isolated LLM call that still works with OAuth auth
TEXT=$(printf '%s' "$USER_MESSAGE" | MENTOR_INTERNAL=1 timeout 25 \
    bash -c 'cd /tmp && exec claude -p \
        --model "$1" \
        --system-prompt "$2" \
        --no-session-persistence \
        --setting-sources "" \
        2>/dev/null' _ "$MODEL" "$SYSTEM_PROMPT") || true

[[ -z "$TEXT" ]] && { echo "$FALLBACK"; exit 0; }
# Log raw model response for debugging (distinguish real response from fallback)
echo "[$(date -Iseconds)] MENTOR-EVAL raw_response='$(printf '%s' "$TEXT" | tr -d '\n' | cut -c1-200)'" >> "${HOME}/.claude/coaching/hook-debug.log" 2>/dev/null || true

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
         + (if .friction and (.friction | IN("vague_request","wrong_approach","missing_diagnostics","scope_drift","missing_skill")) then {friction: .friction} else {} end)
         + (if .skill_suggested and (.skill_suggested | type == "string") then {skill_suggested: .skill_suggested} else {} end)
         + (if .skill_gap_description and (.skill_gap_description | type == "string") then {skill_gap_description: .skill_gap_description} else {} end)
    else error("invalid")
    end' 2>/dev/null) || { echo "$FALLBACK"; exit 0; }

echo "$JUDGMENT"
exit 0
