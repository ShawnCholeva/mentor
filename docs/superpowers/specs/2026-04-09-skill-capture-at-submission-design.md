# Spec: Capture Skill Invocations in UserPromptSubmit

**Date:** 2026-04-09
**Status:** Approved

---

## Problem

Skill invocation detection currently lives in `stop-logger`, which scans `history.jsonl` after each response to find `/skill-name` entries. This approach has produced five bug fixes (3.4.4–3.4.7) due to BSD grep incompatibility, `set -euo pipefail` interactions, transcript vs pre-expansion content, and session-wide contamination of per-turn log entries.

The root cause is architectural: the data originates in `user-prompt-submit` (the raw `PROMPT` variable, pre-expansion), gets discarded, and is reconstructed downstream from a secondary source.

A second problem: because stop-logger scans all of `history.jsonl` for the session, a skill invoked at turn 3 contaminates every subsequent turn's `skill_used` field for the rest of the session. In long-running sessions this makes per-turn skill data unreliable.

---

## Design

### Core Principle

Capture skill invocations where the data already exists — in `user-prompt-submit`, using the raw `PROMPT` variable — and pass them through the existing state file channel to `stop-logger`.

### Data Flow

```
UserPromptSubmit fires
  ├── PROMPT starts with /[a-z]
  │     ├── Read skill_catalog from state file
  │     ├── Skill name in catalog?
  │     │     ├── YES → merge {skill_invoked: "/name", coaching_triggered: false}
  │     │     │         into state file → exit 0
  │     │     └── NO  → internal command, exit 0 (no state written)
  │     └── (no catalog yet = first turn) → exit 0, no state written
  │
  └── Normal prompt
        ├── Merge {skill_invoked: null} into state file (clears stale skill)
        └── Continue to evaluation as normal

Stop fires
  └── Reads skill_invoked from state file (alongside existing coaching fields)
      └── If non-null → skill_used: ["/skill-name"]
          If null     → skill_used: []
          (removes all history.jsonl scanning)
```

### State File Schema

The state file (`~/.claude/coaching/session-<id>.tmp`) gains one field:

| Field | Type | Written by | Description |
|-------|------|-----------|-------------|
| `skill_invoked` | string \| null | user-prompt-submit | Raw skill name for this turn (e.g. `"/brainstorm"`), or null if none |

All existing fields (`last_intervention_ts`, `coaching_triggered`, `type`, `message`, `skill_catalog`, `friction`, `skill_suggested`, `skill_gap_description`) are unchanged. State file writes use merge semantics so existing fields are preserved.

### Skill Catalog Lookup

To distinguish installed plugin skills from Claude Code internal commands (`/exit`, `/usage`, `/help`, `/clear`, etc.), the skill catalog cached in the state file is used:

- State file has `skill_catalog: [{name: "...", trigger: "..."}]` written by the existing catalog-build logic on non-skill turns
- On a skill invocation, extract the name from PROMPT (strip leading `/`, strip after first space), check if it matches any `name` field in the catalog
- Match → user skill, record it
- No match → internal command, do not record
- No state file (first turn of session) → no catalog available, do not record

This is acceptable: the first turn of a session rarely produces meaningful skill analytics, and the catalog will be populated after the first non-skill turn.

### `skill_used` Array

`skill_used` remains a JSON array for schema compatibility. With per-turn capture it will always be `[]` or a single-element array `["/skill-name"]`. Multiple skills in one log entry (from the old session-scan approach) will no longer occur — skills across turns appear in their respective entries.

---

## Files Changed

### `hooks/user-prompt-submit`

**At the skill invocation guard** (currently `exit 0`):

Replace bare exit with:
1. Read `skill_catalog` from state file (if exists, using `$JQ -r '.skill_catalog // []'`)
2. Extract skill name from `$PROMPT` (strip leading `/`, take first token)
3. Check if name appears in catalog (jq `any(.[]; .name == $skill)`)
4. If match: merge `{skill_invoked: $skill, coaching_triggered: false}` into state file via temp file + mv (atomic)
5. `exit 0`

**At the start of normal prompt evaluation** (after affirmations guard, before cooldown check):

If state file exists, merge `{skill_invoked: null}` to clear any stale skill from the previous turn.

Both writes use `|| true` guards throughout to prevent any failure from disrupting the prompt pipeline.

### `hooks/stop-logger`

**Replace** the `HISTORY_FILE` / `_DISPLAYS` / `_SKILL_NAMES` block (added in 3.4.6/3.4.7) with:

```bash
SKILL_NAME=$(echo "$STATE" | "$JQ" -r '.skill_invoked // ""' 2>/dev/null || echo "")
if [[ -n "$SKILL_NAME" ]]; then
    SKILL_USED="[\"${SKILL_NAME}\"]"
fi
```

No other changes to stop-logger.

---

## Edge Cases

| Scenario | Behaviour |
|----------|-----------|
| First turn of session (no state file) | Skill not recorded. Acceptable — catalog not yet seeded. |
| State file merge fails | `|| true` guards, existing flow unaffected |
| Internal command (`/exit`, `/help`) | Not in catalog → not recorded, `skill_used: []` |
| Unknown skill not in catalog | Not recorded (same as internal command) |
| Long-running session | Each turn accurately reflects only that turn's skill |
| State file has stale skill from prev turn | Cleared by null-merge at start of normal prompt evaluation |

---

## Debugging

All skill capture decisions must be visible in `~/.claude/coaching/hook-debug.log` (the same log used by the rest of `user-prompt-submit`). The `DBG` function is already defined in that script.

Required debug lines in `user-prompt-submit`:

| Event | Message |
|-------|---------|
| Skill detected, catalog match | `skill-capture: MATCH skill=/brainstorm → writing state` |
| Skill detected, no catalog match (internal command) | `skill-capture: NO-MATCH skill=/exit (not in catalog)` |
| Skill detected, no state file / no catalog yet | `skill-capture: SKIP skill=/brainstorm (no catalog cached)` |
| Normal prompt, stale skill cleared | `skill-capture: CLEAR (was /brainstorm)` |
| Normal prompt, no stale skill to clear | _(no log line — not interesting)_ |
| State file write fails | `skill-capture: WARN state write failed` |

Required debug line in `stop-logger`:

| Event | Message |
|-------|---------|
| Skill read from state | `skill-used: read from state skill_invoked=/brainstorm` |
| No skill in state | `skill-used: none (skill_invoked null or absent)` |

These lines make the full decision trail visible without running a debugger: open `hook-debug.log`, search for `skill-capture:` and `skill-used:` to trace any invocation end-to-end.

---

## Validation

At the end of implementation, before bumping the version, verify the fix end-to-end:

1. **Skill recorded correctly** — invoke a real installed skill (e.g. `/mentor status`), then inspect the most recent `interactions.jsonl` entry:
   ```bash
   tail -1 ~/.claude/coaching/interactions.jsonl | jq '.skill_used'
   # expected: ["/mentor"]
   ```

2. **Internal command not recorded** — invoke `/exit` or `/usage` in a session, confirm the log entry has `skill_used: []`.

3. **Stale skill cleared** — after a skill turn, submit a normal prompt, confirm that turn's log entry has `skill_used: []` (not the previous skill).

4. **Debug log trace** — after steps 1–3, confirm `hook-debug.log` contains `skill-capture:` and `skill-used:` lines that correctly explain each decision.

5. **No regression on non-skill sessions** — submit several normal prompts in a fresh session, confirm all entries log correctly with `skill_used: []` and `coaching_triggered` reflects actual interventions.

---

## What This Removes

- All `history.jsonl` scanning from `stop-logger`
- The `_DISPLAYS`, `_SKILL_NAMES` intermediate variables
- The `|| true` pipefail workarounds introduced in 3.4.7
- The BSD grep / pipefail interaction surface entirely

---

## Out of Scope

- Tracking multiple skills per turn (one invocation per prompt by definition)
- Retroactively correcting existing log entries (old entries keep their `skill_used` values)
