# Mentor Phase 1.5 — Insights-Informed Coaching Design

## Overview

Five features that make mentor smarter by improving its own data capture, tailoring interventions to friction patterns, adding reinforcement, and optionally integrating with `/insights` (Claude Code's built-in usage analysis).

Builds on Phase 1's accurate data pipeline (v3.2 spec). Phase 1 must be shipped first — these features depend on accurate interaction logging. Session Pre-Flight (Feature 4 from the original feature request) is deferred to a future spec.

**Constraints:**
- Insights integration is always optional — mentor works fully standalone
- No changes to the coaching philosophy file format (user-owned)
- User model schema can be extended; existing fields remain backward-compatible
- Hook timeout budgets: 28s for UserPromptSubmit, async for Stop
- Follow existing patterns: bash hooks orchestrate, shell wrappers call `claude -p`, Python for insights aggregation

## Build Order

1. **Richer Interaction Logging** (Feature 2) — foundation for everything else
2. **Pattern-Specific Interventions** (Feature 3) — highest direct user impact
3. **Reinforcement** (Feature 6) — prevents user attrition
4. **Insights-Informed User Model Seeding** (Feature 1) — eliminates cold-start
5. **Closed-Loop Feedback Cycle** (Feature 5) — self-improving over time

## Files Changed

| File | Action | Features |
|------|--------|----------|
| `hooks/lib/evaluate-prompt.sh` | Modify | F2, F3, F6 |
| `hooks/stop-logger` | Modify | F2, F5 |
| `hooks/user-prompt-submit` | Modify | F1 |
| `hooks/lib/seed-user-model.sh` | Create | F1 |
| `hooks/lib/sync-insights.py` | Create | F5 |
| `skills/mentor/SKILL.md` | Modify | F5 |
| `skills/mentor-recap/SKILL.md` | Modify | F2 |

---

## Feature 2: Richer Interaction Logging

### Design

**Evaluator response schema expansion.** When `intervene: true`, the evaluator returns an additional `friction` field:

```json
{"intervene": true, "type": "correction", "friction": "vague_request", "message": "..."}
```

Valid friction values: `vague_request`, `wrong_approach`, `missing_diagnostics`, `scope_drift`, `missing_skill`. When the issue doesn't fit a known category, the evaluator omits the `friction` field.

Friction classification is LLM-only — it happens inside the evaluator when coaching fires. Non-intervention prompts log `friction_type: null` without needing classification.

**New fields flow through the state file.** `user-prompt-submit` already writes `type` and `message` to the session state file when coaching fires. It also writes `friction` and `skill_available` from the judgment. The stop-logger reads them and includes them in the log entry.

**Skill availability detection.** The evaluator adds a `skill_available` boolean to its response: `true` when the prompt describes work matching a known skill pattern (debugging, testing, design) but no skill was invoked. This gets logged. It's a soft signal — the evaluator already sees the prompt and can pattern-match.

**Session outcome estimation.** At the stop hook, the stop-logger estimates outcome from transcript signals. This is a simple heuristic, not an LLM call:
- Transcript contains `git commit` → `achieved`
- Transcript ends with test failures or errors → `not_achieved`
- Fewer than 3 turns → `unknown`
- Otherwise → `unknown`

Intentionally coarse. Insights facets have high-quality outcome data; this field covers the no-insights case.

**Updated log entry schema:**

```json
{
  "id": "uuid",
  "session_id": "...",
  "timestamp": 1775357850,
  "intent": "direct",
  "skill_used": null,
  "turn_count": 8,
  "prompt_summary": "...",
  "coaching_triggered": true,
  "intervention_type": "correction",
  "friction_type": "vague_request",
  "skill_available": false,
  "session_outcome": "unknown"
}
```

New fields default to `null`/`false`/`"unknown"` when not present. All consumers handle missing fields gracefully.

### Changes

**`hooks/lib/evaluate-prompt.sh`:**
- Add friction categories and skill availability detection to the evaluator's system prompt
- Expand the response validation to accept optional `friction` (string, one of the valid values) and `skill_available` (boolean) fields
- Pass both through in the JSON output

**`hooks/user-prompt-submit`:**
- When writing the session state file after coaching fires, include `friction` and `skill_available` from the judgment (if present)

**`hooks/stop-logger`:**
- Read `friction` and `skill_available` from the session state file (defaults: `null` and `false`)
- Add `friction_type`, `skill_available`, and `session_outcome` to the log entry
- Add session outcome heuristic: grep transcript for commit messages, trailing errors, and turn count

**`skills/mentor-recap/SKILL.md`:**
- Add `friction_type` and `session_outcome` to the documented log entry fields
- Add a "Friction Patterns" section to the report format that groups interventions by friction type

### Success Criteria

- `/mentor-recap` can identify top friction patterns using only its own log data
- Existing log entries without the new fields don't break any consumer
- Session outcome estimation produces a non-`unknown` value for sessions with commits or trailing errors

---

## Feature 3: Pattern-Specific Interventions

### Design

The evaluator's system prompt gets friction categories with tailored coaching guidance. The existing intervention types (nudge/correction/challenge/reinforcement) remain as intensity levels. Friction categories add a reason dimension that shapes message content.

**New section added to the evaluator's system prompt:**

```
## Friction Categories
When you intervene, classify the friction type and tailor your message:

- vague_request: The prompt lacks specifics. Coach toward: what file, expected vs actual
  behavior, error output.
- wrong_approach: The user is heading down a path that won't work. Coach toward: stepping
  back, checking docs, rethinking the strategy.
- missing_diagnostics: The user is debugging without sharing error messages, logs, or file
  paths. Coach toward: sharing the error output and relevant context before Claude starts
  exploring.
- scope_drift: The task has grown beyond what was originally asked. Coach toward: scoping
  down, breaking into smaller pieces, or resetting.
- missing_skill: The prompt describes work that matches a known skill pattern (debugging,
  testing, design) but no skill was invoked. Coach toward: the specific skill category.

If the issue doesn't fit any category, omit the friction field and write a generic coaching
message as you do today.
```

**No changes to hook scripts for this feature.** The friction field flows through the existing state file → stop-logger path established in Feature 2. Only the evaluator's system prompt changes.

**Fallback behavior.** When the evaluator can't classify the friction, it omits the `friction` field and the message is generic, same as today. The system never forces a classification.

### Changes

**`hooks/lib/evaluate-prompt.sh`:**
- Add the friction categories section to the system prompt (listed above)

### Success Criteria

- Coaching messages are specific to the friction pattern — a user can tell from the message what to fix
- The friction category is logged in `interactions.jsonl` via Feature 2's pipeline
- Unclassifiable issues fall back to generic coaching without errors

---

## Feature 6: Reinforcement

### Design

The evaluator gets access to the user's `intervention_history` so it can recognize growth in previously weak areas. The system prompt gets explicit reinforcement triggers.

**Intervention history in the system prompt.** The evaluator already renders `strengths`, `weaknesses`, `current_focus`, and `recent_progress` from the user model. Add `intervention_history` — render the last 10 entries as a bulleted list:

```
Intervention history (recent coaching):
- correction: vague prompts
- correction: vague prompts
- correction: missing diagnostics
- nudge: scope drift
```

**New reinforcement section in the system prompt:**

```
## Reinforcement Triggers
Fire reinforcement when you see genuine growth:
- The user previously struggled with something (see intervention history) and this prompt
  shows improvement in that area. Name the specific improvement.
- The prompt exemplifies a philosophy principle well. Name which principle.
- The user invoked a relevant skill before starting work, especially if this is new behavior.

Reinforcement messages must reference the specific improvement — "You included the error
output and file path this time" not "Good prompt!". Generic praise is worse than no
reinforcement.
```

**Data flow.** `evaluate-prompt.sh` already reads the full `USER_MODEL` JSON and extracts fields. Add extraction of `intervention_history` — the last 10 entries rendered as a bulleted list in the model section. This is ~5 lines of bash in the model section builder.

**No changes to intervention type validation.** `reinforcement` is already valid in the evaluator response schema and in `user-prompt-submit`'s formatting case statement. It just never fires because the evaluator didn't have enough context to recognize growth.

### Changes

**`hooks/lib/evaluate-prompt.sh`:**
- Extract `intervention_history` from the user model JSON (last 10 entries)
- Add it to the `MODEL_SECTION` in the system prompt
- Add the reinforcement triggers section to the system prompt

### Success Criteria

- Reinforcement fires at roughly 1-in-10 rate over a 50+ interaction window
- Reinforcement messages reference specific improvements or philosophy principles
- The evaluator has enough context (via intervention_history) to distinguish growth from baseline

---

## Feature 1: Insights-Informed User Model Seeding

### Design

A new script `hooks/lib/seed-user-model.sh` runs once when the user model is empty and insights facet data exists. It aggregates facets and calls Claude Haiku to produce a seeded user model.

**Trigger condition.** In `user-prompt-submit`, after the bootstrap block that creates the empty user model file (~line 124): if the user model is empty (all arrays empty, no focus) AND `~/.claude/usage-data/facets/` exists with files in it, call the seeder. This runs once — after seeding, the model is no longer empty so the condition never fires again.

**Seeder script (`hooks/lib/seed-user-model.sh`):**

1. Reads all JSON files from `~/.claude/usage-data/facets/`
2. Aggregates: friction counts by category, outcome distribution, top goal categories, friction_detail texts (rich qualitative signal)
3. Builds a summary payload (~500 tokens of aggregated data)
4. Calls `claude -p` with Haiku and a system prompt that maps insights data to user model fields:
   - Friction categories → `weaknesses`
   - Positive outcomes + `primary_success` patterns → `strengths`
   - Top friction category → `current_focus`
5. Writes the seeded model atomically to `~/.claude/coaching/user-model.json`

**Insights-seeded data marking.** The seeded model includes `"seeded_from": "insights"` at the top level. The user model updater preserves unknown fields — it only overwrites the five known keys. This lets anyone inspecting the model see it was bootstrapped from insights.

**Graceful degradation.** No facets directory, empty directory, or script error → nothing happens. The empty model stays, mentor works as today.

**Timeout.** The seeder runs inline in `user-prompt-submit` but is a one-time cost. Uses `timeout 10` to stay within the 28s hook budget. If it times out, the empty model persists and the seeder re-runs on the next prompt.

### Changes

**`hooks/lib/seed-user-model.sh`:** New file (bash script using `claude -p`, following the pattern of `evaluate-prompt.sh` and `update-user-model.sh`).

**`hooks/user-prompt-submit`:**
- After the bootstrap block (~line 127), add a check: if user model is empty AND facets directory has files, call `seed-user-model.sh` with `timeout 10`

### Success Criteria

- A user with insights data and an empty user model has a populated model after their first prompt
- The `seeded_from` field distinguishes insights-seeded data from mentor-observed data
- The model continues evolving from mentor observations after seeding
- Without insights data, behavior is identical to today

---

## Feature 5: Closed-Loop Feedback Cycle

### Design

A new script `hooks/lib/sync-insights.py` reads insights facets and writes `~/.claude/coaching/priority-weights.json`. The evaluator reads this file to adjust its sensitivity toward the user's actual top friction patterns.

**Priority weights file format:**

```json
{
  "last_sync": 1775501642,
  "top_friction": [
    {"pattern": "wrong_approach", "weight": "high", "count": 16},
    {"pattern": "vague_request", "weight": "high", "count": 13},
    {"pattern": "user_rejected_action", "weight": "medium", "count": 6}
  ]
}
```

**Sync trigger.** In `stop-logger`, after the interaction log append: if `~/.claude/usage-data/facets/` exists, compare the most recent facet file's mtime against `last_sync` in `priority-weights.json`. If facets are newer (or weights file doesn't exist), run `sync-insights.py` async (backgrounded).

**Sync script (`hooks/lib/sync-insights.py`):**

1. Reads all facet files, aggregates `friction_counts` across all sessions
2. Ranks by total count, takes top 3
3. Maps insights friction categories to mentor friction categories:
   - `misunderstood_request` → `vague_request`
   - `wrong_approach` → `wrong_approach`
   - `buggy_code` → `wrong_approach`
   - `incomplete_changes` → `scope_drift`
   - `user_rejected_action` → (kept as-is, informational)
   - Others → (kept as-is, informational)
4. Writes `priority-weights.json` — no LLM call, pure aggregation

**Evaluator consumption.** In `evaluate-prompt.sh`, if `~/.claude/coaching/priority-weights.json` exists, read it and add a section to the system prompt:

```
## Priority Patterns (from usage analysis)
Your attention should be weighted toward these friction patterns:
- wrong_approach (high priority — 16 occurrences across sessions)
- vague_request (high priority — 13 occurrences)
Be more sensitive to these patterns. Lower-priority issues can still trigger interventions
but require higher confidence.
```

**`/mentor status` integration.** The mentor skill's status command reads `priority-weights.json` if present and shows current priority patterns and last sync time.

**Graceful degradation.** No facets → no weights file → evaluator treats all patterns equally (current behavior).

### Changes

**`hooks/lib/sync-insights.py`:** New file (Python script, no LLM call).

**`hooks/stop-logger`:**
- After log append, check facets directory mtime vs. weights file `last_sync`
- If stale, run `sync-insights.py` backgrounded

**`hooks/lib/evaluate-prompt.sh`:**
- If `priority-weights.json` exists, read it and add a priority patterns section to the system prompt

**`skills/mentor/SKILL.md`:**
- Add priority weights display to the `status` command output

### Success Criteria

- Evaluator priorities align with the user's actual top friction patterns from insights
- `/mentor status` shows current priority patterns and sync time
- Without insights data, all patterns weighted equally (current behavior)

---

## What This Does NOT Change

- The coaching message format and injection mechanism (additionalContext)
- The philosophy system (user-editable, feeds the evaluator)
- The cooldown system (per-session, configurable)
- The model selection (Haiku for chill, Sonnet for elite)
- The user model updater (`update-user-model.sh`) — continues working as-is with richer data
- The coaching philosophy file format (user-owned)

## Deferred

- **Session Pre-Flight** (Feature 4 from original request) — revisit in a future spec
- **Phase 2 growth engine** — milestones, before/after tracking (requires more real data)
