# Skill Capture at Submission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move skill invocation capture from `stop-logger` (history.jsonl scan) to `user-prompt-submit` (raw PROMPT variable), eliminating the BSD grep/pipefail surface and per-session contamination bug.

**Architecture:** `user-prompt-submit` detects `/skill-name` prompts, looks up the name in the cached skill catalog, and writes `skill_invoked` into the session state file. `stop-logger` reads `skill_invoked` from the state it already loads — no history.jsonl scanning.

**Tech Stack:** Bash, jq (via `$JQ`), atomic temp-file writes for state merges.

---

## File Map

| File | Change |
|------|--------|
| `hooks/user-prompt-submit` | Move `STATE_FILE` definition up; replace bare skill guard with catalog lookup + state write; add stale-clear after affirmations guard |
| `hooks/stop-logger` | Add `DBG` function; replace `_DISPLAYS`/`_SKILL_NAMES`/history.jsonl block with single `skill_invoked` read from `$STATE`; add debug lines |

---

### Task 1: Move STATE_FILE definition up and add skill catalog lookup to skill guard

**Files:**
- Modify: `hooks/user-prompt-submit:87-88` (skill guard) and `:96` (STATE_FILE definition)

Currently `STATE_FILE` is defined at line 96 (inside the cooldown guard), but the skill guard at line 87 needs it. Move `STATE_FILE` to just before the skill guard section, then replace the bare exit with catalog lookup + state write.

- [ ] **Step 1: Add `STATE_FILE` definition before the skill guard**

In `hooks/user-prompt-submit`, insert one line between line 85 (end of bootstrap guard block) and line 87 (skill guard comment). The full replacement of that region:

Old (lines 85-88):
```bash
fi

# ─── Guard: skill invocations ─────────────────────────────────────────────────
echo "$PROMPT" | grep -qE "^/[a-z]" && { _EXIT_REASON="slash-command"; exit 0; }
```

New:
```bash
fi

STATE_FILE="${COACHING_DIR}/session-${SESSION_ID}.tmp"

# ─── Guard: skill invocations ─────────────────────────────────────────────────
if echo "$PROMPT" | grep -qE "^/[a-z]"; then
    _SKILL_WITH_SLASH=$(echo "$PROMPT" | grep -oE "^/[a-z][a-z0-9:-]*" | head -1 || echo "")
    _SKILL_BARE="${_SKILL_WITH_SLASH#/}"
    if [[ -n "$SESSION_ID" ]] && [[ -f "$STATE_FILE" ]]; then
        _CAT=$(cat "$STATE_FILE" 2>/dev/null | "$JQ" -c '.skill_catalog // []' 2>/dev/null || echo "[]")
        _IN_CAT=$(printf '%s' "$_CAT" | "$JQ" -r --arg s "$_SKILL_BARE" 'any(.[]; .name == $s)' 2>/dev/null || echo "false")
        if [[ "$_IN_CAT" == "true" ]]; then
            DBG "skill-capture: MATCH skill=${_SKILL_WITH_SLASH} → writing state"
            _MERGED=$(cat "$STATE_FILE" | "$JQ" -c --arg s "$_SKILL_WITH_SLASH" \
                '. + {skill_invoked: $s, coaching_triggered: false}' 2>/dev/null) || true
            if [[ -n "$_MERGED" ]]; then
                _TMP="${STATE_FILE}.tmp.$$"
                printf '%s\n' "$_MERGED" > "$_TMP" 2>/dev/null \
                    && mv "$_TMP" "$STATE_FILE" 2>/dev/null \
                    || { rm -f "$_TMP" 2>/dev/null || true; DBG "skill-capture: WARN state write failed"; } || true
            else
                DBG "skill-capture: WARN state write failed"
            fi
        else
            DBG "skill-capture: NO-MATCH skill=${_SKILL_WITH_SLASH} (not in catalog)"
        fi
    else
        DBG "skill-capture: SKIP skill=${_SKILL_WITH_SLASH} (no catalog cached)"
    fi
    _EXIT_REASON="slash-command"
    exit 0
fi
```

- [ ] **Step 2: Remove the old STATE_FILE definition at the cooldown guard**

Find and remove the now-duplicate `STATE_FILE` line from the cooldown guard section. The cooldown guard section currently starts:

```bash
# ─── Guard: per-session cooldown ─────────────────────────────────────────────
STATE_FILE="${COACHING_DIR}/session-${SESSION_ID}.tmp"
DBG "cooldown: session=...
```

Remove just the `STATE_FILE=...` line so it becomes:

```bash
# ─── Guard: per-session cooldown ─────────────────────────────────────────────
DBG "cooldown: session='${SESSION_ID:-EMPTY}' state_file=$([ -f "$STATE_FILE" ] && echo exists || echo missing) ls=$(ls -la "$STATE_FILE" 2>&1 || true)"
```

- [ ] **Step 3: Verify the script still exits 0 on a skill invocation with no state file**

Run (simulates first-turn skill with no session state):

```bash
echo '{"prompt":"/brainstorm help me","session_id":"test-nosession-001"}' \
  | MENTOR_INTERNAL=1 bash /home/shawn/projects/claude-mentor/hooks/user-prompt-submit
```

Expected: exits 0, no output (no coaching emitted). No crash.

- [ ] **Step 4: Commit**

```bash
git add hooks/user-prompt-submit
git commit -m "feat: move STATE_FILE earlier, add skill catalog lookup to skill guard"
```

---

### Task 2: Add stale skill_invoked clear for normal prompts

**Files:**
- Modify: `hooks/user-prompt-submit` (after affirmations guard, before cooldown check)

After a skill turn, the next normal prompt must clear `skill_invoked` so stop-logger doesn't carry the previous skill forward.

- [ ] **Step 1: Insert stale-clear block after affirmations guard**

Current affirmations guard (ends with exit 0):
```bash
echo "$PROMPT_TRIMMED" | grep -qiE "$AFFIRMATIONS" && { _EXIT_REASON="affirmation"; exit 0; }
```

Insert immediately after that line:

```bash
# ─── Clear stale skill_invoked (this is a normal prompt, not a skill invocation) ─
if [[ -n "$SESSION_ID" ]] && [[ -f "$STATE_FILE" ]]; then
    _PREV_SKILL=$("$JQ" -r '.skill_invoked // ""' "$STATE_FILE" 2>/dev/null || echo "")
    if [[ -n "$_PREV_SKILL" ]]; then
        DBG "skill-capture: CLEAR (was ${_PREV_SKILL})"
        _MERGED=$(cat "$STATE_FILE" | "$JQ" -c '. + {skill_invoked: null}' 2>/dev/null) || true
        if [[ -n "$_MERGED" ]]; then
            _TMP="${STATE_FILE}.tmp.$$"
            printf '%s\n' "$_MERGED" > "$_TMP" 2>/dev/null \
                && mv "$_TMP" "$STATE_FILE" 2>/dev/null \
                || rm -f "$_TMP" 2>/dev/null || true
        fi
    fi
fi
```

- [ ] **Step 2: Commit**

```bash
git add hooks/user-prompt-submit
git commit -m "feat: clear stale skill_invoked on normal prompts in user-prompt-submit"
```

---

### Task 3: Update stop-logger to read skill_invoked from state; remove history.jsonl scan

**Files:**
- Modify: `hooks/stop-logger:89-103` (the `_DISPLAYS`/`_SKILL_NAMES`/history.jsonl block)

The `STATE` variable is already populated at line 47 (`STATE=$(cat "$STATE_FILE")`). We just read `skill_invoked` from it and replace the entire history.jsonl scanning block.

- [ ] **Step 1: Add a DBG function to stop-logger**

After the `mkdir -p "$COACHING_DIR"` line (line 17), insert:

```bash
DBG() { echo "[$(date -Iseconds)] STOP-LOGGER-DBG $*" >> "${COACHING_DIR}/hook-debug.log" 2>/dev/null || true; }
```

- [ ] **Step 2: Replace the history.jsonl skill detection block**

Remove lines 89–103 (the `# ─── Detect skill invocations from history.jsonl` section through the closing `fi`):

```bash
# ─── Detect skill invocations from history.jsonl (pre-expansion input) ────────
# The transcript contains expanded SKILL.md content, not the original /skill-name.
# history.jsonl .display has the raw user input before Claude Code expands skills.
# Steps are broken apart so grep returning 1 (no matches) doesn't kill the script
# under set -euo pipefail on bash 3.2 (macOS).
HISTORY_FILE="${HOME}/.claude/history.jsonl"
if [[ -n "$SESSION_ID" ]] && [[ -f "$HISTORY_FILE" ]]; then
    _DISPLAYS=$(grep "\"sessionId\":\"${SESSION_ID}\"" "$HISTORY_FILE" 2>/dev/null | \
        "$JQ" -r '.display // ""' 2>/dev/null || true)
    _SKILL_NAMES=$(printf '%s' "$_DISPLAYS" | grep -oE "^/[a-z][a-z0-9:-]+" 2>/dev/null | \
        sort -u || true)
    if [[ -n "$_SKILL_NAMES" ]]; then
        SKILL_USED=$(printf '%s' "$_SKILL_NAMES" | "$JQ" -Rn '[inputs]' 2>/dev/null || echo "[]")
    fi
fi
```

Replace with:

```bash
# ─── Read skill_invoked from state (written by user-prompt-submit) ────────────
SKILL_NAME=$(printf '%s' "${STATE:-}" | "$JQ" -r '.skill_invoked // ""' 2>/dev/null || echo "")
if [[ -n "$SKILL_NAME" ]]; then
    DBG "skill-used: read from state skill_invoked=${SKILL_NAME}"
    SKILL_USED="[\"${SKILL_NAME}\"]"
else
    DBG "skill-used: none (skill_invoked null or absent)"
fi
```

- [ ] **Step 3: Verify stop-logger parses correctly with a synthetic state**

Create a synthetic state file and run stop-logger with a minimal session input:

```bash
# Setup
mkdir -p ~/.claude/coaching
SESSION="test-skill-logger-001"
STATE_F="${HOME}/.claude/coaching/session-${SESSION}.tmp"
printf '{"skill_invoked":"/brainstorm","coaching_triggered":false}\n' > "$STATE_F"

# Run stop-logger (supply minimal JSON, use a session that matches the temp state)
printf '{"session_id":"%s","transcript_path":""}\n' "$SESSION" \
  | bash /home/shawn/projects/claude-mentor/hooks/stop-logger

# Check log entry
tail -1 ~/.claude/coaching/interactions.jsonl | jq '.skill_used, .intent'
```

Expected output:
```
["/brainstorm"]
"skill-invoked"
```

- [ ] **Step 4: Clean up test artifact**

```bash
rm -f "${HOME}/.claude/coaching/session-test-skill-logger-001.tmp"
```

- [ ] **Step 5: Commit**

```bash
git add hooks/stop-logger
git commit -m "feat: read skill_invoked from state file in stop-logger, remove history.jsonl scan"
```

---

### Task 4: End-to-end validation (spec checklist)

**Files:** None modified — read-only verification.

Run all 5 checks from the spec before bumping the version.

- [ ] **Check 1: Skill recorded correctly**

In a live Claude Code session, run a real installed skill — e.g. type `/mentor status` and submit it. Then inspect the most recent interactions log entry:

```bash
tail -1 ~/.claude/coaching/interactions.jsonl | jq '.skill_used, .intent'
```

Expected:
```
["/mentor"]
"skill-invoked"
```

- [ ] **Check 2: Internal command not recorded**

In the same or a new session, invoke `/help` or `/usage` (a Claude Code internal command not in the skill catalog), then submit a normal prompt to trigger a log entry. Inspect:

```bash
tail -1 ~/.claude/coaching/interactions.jsonl | jq '.skill_used'
```

Expected:
```
[]
```

- [ ] **Check 3: Stale skill cleared**

After the skill turn from Check 1, submit a plain normal prompt (e.g. "what files are in this directory"). Inspect:

```bash
tail -1 ~/.claude/coaching/interactions.jsonl | jq '.skill_used'
```

Expected:
```
[]
```

(Not `["/mentor"]` from the previous turn.)

- [ ] **Check 4: Debug log trace**

After Checks 1–3, scan the debug log for the full decision trail:

```bash
grep -E "skill-capture:|skill-used:" ~/.claude/coaching/hook-debug.log | tail -20
```

Expected lines (in order, for Checks 1–3):
```
... skill-capture: MATCH skill=/mentor → writing state
... skill-used: read from state skill_invoked=/mentor
... skill-capture: CLEAR (was /mentor)
... skill-used: none (skill_invoked null or absent)
```

For Check 2 (internal command), look for:
```
... skill-capture: NO-MATCH skill=/help (not in catalog)
... skill-used: none (skill_invoked null or absent)
```

- [ ] **Check 5: No regression on non-skill sessions**

Start a fresh session (new terminal / new Claude Code window). Submit 3 normal prompts. Check the last 3 log entries:

```bash
tail -3 ~/.claude/coaching/interactions.jsonl | jq -c '{intent, skill_used, coaching_triggered}'
```

Expected: all entries have `skill_used: []`, and `coaching_triggered` correctly reflects whether mentor intervened (not uniformly `true` or `false`).

---

### Task 5: Bump version to 3.4.8 and push

**Files:**
- Modify: `.claude-plugin/marketplace.json`
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Bump version in both files**

In `.claude-plugin/marketplace.json`, change `"version": "3.4.7"` → `"version": "3.4.8"`.

In `.claude-plugin/plugin.json`, change `"version": "3.4.7"` → `"version": "3.4.8"`.

- [ ] **Step 2: Commit and push**

```bash
git add .claude-plugin/marketplace.json .claude-plugin/plugin.json
git commit -m "chore: bump version to 3.4.8 — skill capture moved to user-prompt-submit"
git push
```

---

## Self-Review

**Spec coverage check:**

| Spec requirement | Covered by |
|-----------------|------------|
| Capture skill at UserPromptSubmit via raw PROMPT | Task 1 |
| Catalog lookup to exclude internal commands | Task 1 |
| `skill_invoked` field written to state file | Task 1 |
| `coaching_triggered: false` written on skill turns | Task 1 |
| Stale skill cleared on normal prompts | Task 2 |
| `|| true` guards throughout | Task 1, Task 2 |
| stop-logger reads `skill_invoked` from state | Task 3 |
| history.jsonl scanning removed | Task 3 |
| DBG lines: MATCH, NO-MATCH, SKIP, CLEAR, WARN | Task 1, Task 2 |
| DBG lines in stop-logger: read / none | Task 3 |
| 5 validation checks | Task 4 |
| Version bump | Task 5 |

**No placeholders.** All code blocks are complete and directly usable.

**Type consistency:** `skill_invoked` stored as `"/skill-name"` (with slash) in Task 1; read the same way in Task 3; stored in `skill_used` array as `["/skill-name"]` — consistent throughout.
