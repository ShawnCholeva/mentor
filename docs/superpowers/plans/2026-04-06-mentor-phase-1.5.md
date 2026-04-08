# Mentor Phase 1.5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add friction classification, pattern-specific coaching, reinforcement, insights-informed user model seeding, and closed-loop feedback to the mentor plugin.

**Architecture:** Five features layered onto the existing hook pipeline. The evaluator's system prompt gains friction categories and reinforcement triggers. The state file and stop-logger gain new fields. Two new scripts handle insights integration (one bash + LLM, one pure Python). All insights integration is optional and degrades gracefully.

**Tech Stack:** Bash (hooks, evaluator, seeder), Python 3 (insights sync), jq (JSON processing), Claude CLI (`claude -p`)

**Spec:** `docs/superpowers/specs/2026-04-06-mentor-phase-1.5-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `hooks/lib/evaluate-prompt.sh` | Modify | Add friction categories, skill availability, reinforcement triggers, priority weights to system prompt; expand response validation |
| `hooks/user-prompt-submit` | Modify | Pass friction + skill_available through state file; trigger user model seeding |
| `hooks/stop-logger` | Modify | Read new state fields, add session outcome heuristic, expand log entry schema, trigger insights sync |
| `hooks/lib/seed-user-model.sh` | Create | One-time user model seeding from insights facets via Claude Haiku |
| `hooks/lib/sync-insights.py` | Create | Aggregate insights facets into priority weights file (pure Python, no LLM) |
| `tests/test_sync_insights.py` | Create | Unit tests for sync-insights.py with fixture data |
| `skills/mentor/SKILL.md` | Modify | Add priority weights to status output |
| `skills/mentor-recap/SKILL.md` | Modify | Add friction_type and session_outcome to documented fields and report |

---

### Task 1: Evaluator — friction classification + pattern-specific coaching (F2+F3)

**Files:**
- Modify: `hooks/lib/evaluate-prompt.sh:62-108` (system prompt)
- Modify: `hooks/lib/evaluate-prompt.sh:148-157` (response validation)

This task adds friction categories with coaching guidance to the evaluator's system prompt, adds skill availability detection, and expands the response validation to pass through the new fields.

- [ ] **Step 1: Add friction categories and skill availability to system prompt**

In `hooks/lib/evaluate-prompt.sh`, insert a new section after the `## Rules` section (after line 92) and before `## Conversation Awareness` (line 94). Add:

```bash
# Find this line (line 93):
## Conversation Awareness

# Insert BEFORE it:
## Friction Categories
When you intervene, classify the friction type and tailor your message accordingly. Include a \"friction\" field in your JSON response.

- vague_request: The prompt lacks specifics — no file paths, no expected behavior, no error output. Coach toward: what file, expected vs actual behavior, and any error output.
- wrong_approach: The user is heading down a path that won't work or is inefficient. Coach toward: stepping back, checking docs, or rethinking the strategy.
- missing_diagnostics: The user is debugging without sharing error messages, logs, or relevant file paths. Coach toward: sharing the error output and relevant context before Claude starts exploring.
- scope_drift: The task has grown beyond what was originally asked or the user is trying to do too much at once. Coach toward: scoping down, breaking into smaller pieces, or resetting.
- missing_skill: The prompt describes work that matches a known skill pattern (debugging, testing, design, code review) but no skill was invoked. Coach toward: the specific skill category that would help.

If the issue doesn't fit any category, omit the friction field entirely. Do not force a classification.

## Skill Availability
If the user's prompt describes debugging, testing, building, designing, or reviewing work AND they did not invoke a skill (no / prefix), set \"skill_available\": true in your response. Otherwise omit it.
```

Also update the response format instruction at the end of the system prompt. Replace lines 105-108:

```bash
# Replace this block:
Respond with ONLY a JSON object, no markdown, no explanation:
{\"intervene\": false}
or
{\"intervene\": true, \"type\": \"nudge|correction|challenge|reinforcement\", \"message\": \"your coaching message here\"}

# With:
Respond with ONLY a JSON object, no markdown, no explanation:
{\"intervene\": false}
or
{\"intervene\": true, \"type\": \"nudge|correction|challenge|reinforcement\", \"message\": \"your coaching message here\", \"friction\": \"vague_request|wrong_approach|missing_diagnostics|scope_drift|missing_skill\", \"skill_available\": true}
The \"friction\" and \"skill_available\" fields are optional — include them only when applicable.
```

- [ ] **Step 2: Expand response validation to pass through new fields**

In `hooks/lib/evaluate-prompt.sh`, replace the validation block at lines 148-157:

```bash
# Replace this:
JUDGMENT=$(printf '%s' "$TEXT" | "$JQ" -e '
    if type != "object" then error("not object")
    elif .intervene == false then {intervene: false}
    elif (.intervene == true
          and (.type | IN("nudge","correction","challenge","reinforcement"))
          and (.message | type == "string" and length > 0))
    then {intervene: true, type: .type, message: .message}
    else error("invalid")
    end' 2>/dev/null) || { echo "$FALLBACK"; exit 0; }

# With:
JUDGMENT=$(printf '%s' "$TEXT" | "$JQ" -e '
    if type != "object" then error("not object")
    elif .intervene == false then {intervene: false}
    elif (.intervene == true
          and (.type | IN("nudge","correction","challenge","reinforcement"))
          and (.message | type == "string" and length > 0))
    then {intervene: true, type: .type, message: .message}
         + (if .friction then {friction: .friction} else {} end)
         + (if .skill_available then {skill_available: true} else {} end)
    else error("invalid")
    end' 2>/dev/null) || { echo "$FALLBACK"; exit 0; }
```

- [ ] **Step 3: Verify evaluator changes**

Run a quick smoke test by feeding a vague prompt through the evaluator:

```bash
echo '{"prompt":"fix this","mode":"chill","philosophy":"","user_model":{},"history":[]}' \
  | bash hooks/lib/evaluate-prompt.sh
```

Expected: JSON response. If `intervene: true`, it should include a `friction` field (likely `vague_request`). If `intervene: false`, that's also valid — the LLM may not find it worth intervening on.

- [ ] **Step 4: Commit**

```bash
git add hooks/lib/evaluate-prompt.sh
git commit -m "feat: add friction classification and skill availability to evaluator (F2+F3)"
```

---

### Task 2: State file — pass friction + skill_available through (F2)

**Files:**
- Modify: `hooks/user-prompt-submit:175-192` (judgment parsing + state file write)

- [ ] **Step 1: Parse friction and skill_available from judgment**

In `hooks/user-prompt-submit`, after line 181 (`[[ -z "$FEEDBACK" ]] && ...`), add:

```bash
# After this line:
[[ -z "$FEEDBACK" ]] && { _EXIT_REASON="empty-feedback"; exit 0; }

# Add:
FRICTION=$(         echo "$JUDGMENT" | "$JQ" -r '.friction         // ""'    2>/dev/null || echo "")
SKILL_AVAILABLE=$(  echo "$JUDGMENT" | "$JQ" -r '.skill_available  // false' 2>/dev/null || echo "false")
```

- [ ] **Step 2: Write friction and skill_available to state file**

Replace the state file write block at lines 184-192:

```bash
# Replace this:
NOW_EPOCH=$(date +%s)
"$JQ" -n \
    --argjson ts "$NOW_EPOCH" \
    --argjson coaching_triggered true \
    --arg     type    "$INTERVENTION_TYPE" \
    --arg     message "$FEEDBACK" \
    '{last_intervention_ts: $ts, coaching_triggered: $coaching_triggered, type: $type, message: $message}' \
    > "$STATE_FILE" 2>/dev/null || true
DBG "state_write: path=$STATE_FILE coaching=true type=$INTERVENTION_TYPE exists=$([ -f "$STATE_FILE" ] && echo yes || echo no)"

# With:
NOW_EPOCH=$(date +%s)
FRICTION_ARG=""
[[ -n "$FRICTION" ]] && FRICTION_ARG="--arg friction $FRICTION"
"$JQ" -n \
    --argjson ts "$NOW_EPOCH" \
    --argjson coaching_triggered true \
    --arg     type    "$INTERVENTION_TYPE" \
    --arg     message "$FEEDBACK" \
    --argjson skill_available "$SKILL_AVAILABLE" \
    $FRICTION_ARG \
    '{last_intervention_ts: $ts, coaching_triggered: $coaching_triggered, type: $type, message: $message, skill_available: $skill_available}
     + (if $ARGS.named | has("friction") then {friction: $friction} else {} end)' \
    > "$STATE_FILE" 2>/dev/null || true
DBG "state_write: path=$STATE_FILE coaching=true type=$INTERVENTION_TYPE friction=${FRICTION:-none} exists=$([ -f "$STATE_FILE" ] && echo yes || echo no)"
```

- [ ] **Step 3: Commit**

```bash
git add hooks/user-prompt-submit
git commit -m "feat: pass friction and skill_available through session state file (F2)"
```

---

### Task 3: Stop-logger — richer log entries (F2)

**Files:**
- Modify: `hooks/stop-logger:37-48` (state file reading)
- Modify: `hooks/stop-logger:50-55` (after turn count — add session outcome)
- Modify: `hooks/stop-logger:93-117` (log entry builder)

- [ ] **Step 1: Read friction and skill_available from state file**

In `hooks/stop-logger`, after the existing state file reading block (line 48), add:

```bash
# After this existing line:
    COACHING_MESSAGE=$( echo "$STATE" | "$JQ" -r '.message // ""'                                       2>/dev/null || echo "")

# Add these lines inside the if block (before the closing fi):
    FRICTION=$(         echo "$STATE" | "$JQ" -r '.friction // ""'                                      2>/dev/null || echo "")
    SKILL_AVAILABLE=$(  echo "$STATE" | "$JQ" -r 'if .skill_available then "true" else "false" end'      2>/dev/null || echo "false")
```

Also add defaults before the `if` block, after line 41:

```bash
# After this line:
COACHING_MESSAGE=""

# Add:
FRICTION=""
SKILL_AVAILABLE="false"
```

- [ ] **Step 2: Add session outcome heuristic**

After the turn count block (after line 55), add:

```bash
# ─── Estimate session outcome from transcript ──────────────────────────────
SESSION_OUTCOME="unknown"
if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
    if grep -q '"git commit"\|"git add"\|committed' "$TRANSCRIPT_PATH" 2>/dev/null; then
        SESSION_OUTCOME="achieved"
    elif tail -c 5000 "$TRANSCRIPT_PATH" 2>/dev/null | grep -qiE '"error"|"fail"|"FAIL"|"Error"|traceback' 2>/dev/null; then
        SESSION_OUTCOME="not_achieved"
    elif [[ "$TURN_COUNT" -lt 3 ]]; then
        SESSION_OUTCOME="unknown"
    fi
fi
```

- [ ] **Step 3: Add new fields to log entry**

Replace the log entry builder at lines 97-117:

```bash
# Replace this:
"$JQ" -n -c \
    --arg     id                "$ENTRY_ID" \
    --arg     session_id        "$SESSION_ID" \
    --argjson timestamp         "$TIMESTAMP" \
    --arg     intent            "$INTENT" \
    --argjson skill_used        "$SKILL_USED" \
    --argjson turn_count        "$TURN_COUNT" \
    --arg     prompt_summary    "$PROMPT_SUMMARY" \
    --argjson coaching_triggered "$COACHING_TRIGGERED" \
    --argjson intervention_type "$INTERVENTION_TYPE" \
    '{
        id:                 $id,
        session_id:         $session_id,
        timestamp:          $timestamp,
        intent:             $intent,
        skill_used:         $skill_used,
        turn_count:         $turn_count,
        prompt_summary:     $prompt_summary,
        coaching_triggered: $coaching_triggered,
        intervention_type:  $intervention_type
    }' >> "$LOG_FILE" 2>/dev/null || true

# With:
FRICTION_TYPE="null"
[[ -n "$FRICTION" ]] && FRICTION_TYPE="\"${FRICTION}\""

"$JQ" -n -c \
    --arg     id                "$ENTRY_ID" \
    --arg     session_id        "$SESSION_ID" \
    --argjson timestamp         "$TIMESTAMP" \
    --arg     intent            "$INTENT" \
    --argjson skill_used        "$SKILL_USED" \
    --argjson turn_count        "$TURN_COUNT" \
    --arg     prompt_summary    "$PROMPT_SUMMARY" \
    --argjson coaching_triggered "$COACHING_TRIGGERED" \
    --argjson intervention_type "$INTERVENTION_TYPE" \
    --argjson friction_type     "$FRICTION_TYPE" \
    --argjson skill_available   "$SKILL_AVAILABLE" \
    --arg     session_outcome   "$SESSION_OUTCOME" \
    '{
        id:                 $id,
        session_id:         $session_id,
        timestamp:          $timestamp,
        intent:             $intent,
        skill_used:         $skill_used,
        turn_count:         $turn_count,
        prompt_summary:     $prompt_summary,
        coaching_triggered: $coaching_triggered,
        intervention_type:  $intervention_type,
        friction_type:      $friction_type,
        skill_available:    $skill_available,
        session_outcome:    $session_outcome
    }' >> "$LOG_FILE" 2>/dev/null || true
```

- [ ] **Step 4: Verify log entry format**

Check that a sample log entry has the right shape by examining a recent entry after running:

```bash
tail -1 ~/.claude/coaching/interactions.jsonl | python3 -m json.tool
```

Expected: JSON with all original fields plus `friction_type`, `skill_available`, `session_outcome`.

- [ ] **Step 5: Commit**

```bash
git add hooks/stop-logger
git commit -m "feat: add friction_type, skill_available, session_outcome to interaction log (F2)"
```

---

### Task 4: Update mentor-recap skill (F2)

**Files:**
- Modify: `skills/mentor-recap/SKILL.md`

- [ ] **Step 1: Add new fields to documented schema**

In `skills/mentor-recap/SKILL.md`, replace the field list in Step 1 (around lines 33-38):

```markdown
Parse the JSONL: each line is one interaction entry with fields:
- `intent` — how the prompt was classified: `vague`, `skill-invoked`, or `direct`
- `skill_used` — skill invoked (e.g. `/mentor`, or null if a direct prompt)
- `turn_count` — number of turns to complete the task
- `coaching_triggered` — whether Mentor intervened
- `intervention_type` — type of intervention: `nudge`, `correction`, `challenge`, `reinforcement`, or null
- `friction_type` — friction category when coaching fired: `vague_request`, `wrong_approach`, `missing_diagnostics`, `scope_drift`, `missing_skill`, or null
- `skill_available` — whether a relevant skill was available but not invoked
- `session_outcome` — estimated outcome: `achieved`, `not_achieved`, or `unknown`
- `timestamp` — ISO8601
```

Note: remove the `tags` field reference — it was removed in v3.2.

- [ ] **Step 2: Add Friction Patterns section to the report format**

In Step 4 (the report format), after the `### Patterns Detected` section (around line 99), add:

```markdown
### Friction Patterns
[Group interventions by friction_type. For each type that appeared 2+ times:]
- **[friction_type]**: [N] occurrences
  Impact: [what this costs — extra turns, rework, wrong output]
  Trend: [increasing/decreasing/stable over the window]

[If session_outcome data available:]
Session outcomes: [X] achieved · [Y] not_achieved · [Z] unknown
```

- [ ] **Step 3: Update metrics table**

In Step 2 (metrics computation, around line 57), add rows:

```markdown
| Friction distribution | Count by `friction_type` field (non-null entries only) |
| Session outcomes | Count by `session_outcome` field |
| Skill availability | Count entries where `skill_available` = true but `skill_used` is null |
```

- [ ] **Step 4: Remove stale tags reference**

Remove `tags` from the field list and the `Top tags` metric row. Remove the reference in the Patterns section to tags arrays.

- [ ] **Step 5: Commit**

```bash
git add skills/mentor-recap/SKILL.md
git commit -m "feat: add friction patterns and session outcomes to mentor-recap report (F2)"
```

---

### Task 5: Reinforcement — intervention history + triggers (F6)

**Files:**
- Modify: `hooks/lib/evaluate-prompt.sh:35-55` (model section builder)
- Modify: `hooks/lib/evaluate-prompt.sh:62-108` (system prompt)

- [ ] **Step 1: Extract intervention_history from user model**

In `hooks/lib/evaluate-prompt.sh`, inside the `if [[ "$HAS_MODEL" == "true" ]]` block (after line 46), add extraction of intervention_history:

```bash
# After this line:
    PROGRESS=$(  echo "$USER_MODEL" | "$JQ" -r '.recent_progress // ""'   2>/dev/null || echo "")

# Add:
    INTERVENTION_HIST=$(echo "$USER_MODEL" | "$JQ" -r '
        (.intervention_history // [])[-10:] |
        if length > 0 then
            map("- " + .) | join("\n")
        else
            "No coaching history yet."
        end' 2>/dev/null || echo "No coaching history yet.")
```

- [ ] **Step 2: Add intervention history to MODEL_SECTION**

Update the `MODEL_SECTION` assignment to include the history:

```bash
# Replace this:
    MODEL_SECTION="## User Profile
Strengths: ${STRENGTHS}
Weaknesses: ${WEAKNESSES}
Current focus: ${FOCUS}
Recent progress: ${PROGRESS}"

# With:
    MODEL_SECTION="## User Profile
Strengths: ${STRENGTHS}
Weaknesses: ${WEAKNESSES}
Current focus: ${FOCUS}
Recent progress: ${PROGRESS}

Intervention history (recent coaching):
${INTERVENTION_HIST}"
```

- [ ] **Step 3: Add reinforcement triggers to system prompt**

In the system prompt, after the `## Friction Categories` section and before `## Skill Availability`, add:

```bash
## Reinforcement Triggers
Fire reinforcement when you see genuine growth:
- The user previously struggled with something (see intervention history) and this prompt shows improvement in that area. Name the specific improvement — e.g., \"You included the error output and file path this time — that's exactly what was missing in your last few prompts.\"
- The prompt exemplifies a philosophy principle well. Name which principle and why it matters.
- The user invoked a relevant skill before starting work, especially if this is a new behavior.

Reinforcement messages must reference the specific improvement. Generic praise (\"Good prompt!\", \"Nice work!\") is worse than no reinforcement — it teaches the user nothing. Be specific about WHAT improved and WHY it matters.
```

- [ ] **Step 4: Verify intervention history renders**

Create a test user model with intervention_history and check the evaluator processes it:

```bash
echo '{"prompt":"Fix the auth bug in src/auth.ts — the token refresh is returning 401 on expired tokens. Error log attached.","mode":"chill","philosophy":"","user_model":{"strengths":[],"weaknesses":["vague prompts"],"current_focus":"prompt specificity","recent_progress":"","intervention_history":["correction: vague prompt","correction: vague prompt","correction: missing diagnostics"]},"history":[]}' \
  | bash hooks/lib/evaluate-prompt.sh
```

Expected: JSON response. This prompt is specific and shows growth in a weak area — the evaluator may fire `reinforcement`. Either way, no errors.

- [ ] **Step 5: Commit**

```bash
git add hooks/lib/evaluate-prompt.sh
git commit -m "feat: add intervention history and reinforcement triggers to evaluator (F6)"
```

---

### Task 6: Insights sync script (F5)

**Files:**
- Create: `hooks/lib/sync-insights.py`
- Create: `tests/test_sync_insights.py`

- [ ] **Step 1: Write tests for sync-insights.py**

Create `tests/test_sync_insights.py`:

```python
#!/usr/bin/env python3
"""Tests for sync-insights.py — insights facet aggregation."""

import json
import os
import sys
import tempfile

import pytest

# Add hooks/lib to path so we can import the module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "hooks", "lib"))
from sync_insights import aggregate_facets, map_friction, build_weights


@pytest.fixture
def facets_dir():
    """Create a temp directory with sample facet files."""
    with tempfile.TemporaryDirectory() as d:
        facets = [
            {
                "outcome": "not_achieved",
                "friction_counts": {"wrong_approach": 2, "misunderstood_request": 1},
                "friction_detail": "User went down wrong path.",
                "session_id": "aaa",
            },
            {
                "outcome": "fully_achieved",
                "friction_counts": {},
                "friction_detail": "",
                "session_id": "bbb",
            },
            {
                "outcome": "not_achieved",
                "friction_counts": {"misunderstood_request": 1, "buggy_code": 1},
                "friction_detail": "Vague request led to wrong output.",
                "session_id": "ccc",
            },
            {
                "outcome": "partially_achieved",
                "friction_counts": {"incomplete_changes": 1},
                "friction_detail": "Scope grew beyond original ask.",
                "session_id": "ddd",
            },
        ]
        for i, f in enumerate(facets):
            with open(os.path.join(d, f"facet-{i}.json"), "w") as fh:
                json.dump(f, fh)
        yield d


def test_aggregate_facets(facets_dir):
    result = aggregate_facets(facets_dir)
    assert result["wrong_approach"] == 2
    assert result["misunderstood_request"] == 2
    assert result["buggy_code"] == 1
    assert result["incomplete_changes"] == 1


def test_aggregate_facets_empty_dir():
    with tempfile.TemporaryDirectory() as d:
        result = aggregate_facets(d)
        assert result == {}


def test_aggregate_facets_missing_dir():
    result = aggregate_facets("/nonexistent/path")
    assert result == {}


def test_map_friction():
    assert map_friction("misunderstood_request") == "vague_request"
    assert map_friction("wrong_approach") == "wrong_approach"
    assert map_friction("buggy_code") == "wrong_approach"
    assert map_friction("incomplete_changes") == "scope_drift"
    assert map_friction("user_rejected_action") == "user_rejected_action"
    assert map_friction("hallucinated_content") == "hallucinated_content"


def test_build_weights(facets_dir):
    counts = aggregate_facets(facets_dir)
    weights = build_weights(counts)
    assert len(weights) <= 3
    # Top pattern should be wrong_approach or misunderstood_request (both have count 2)
    patterns = [w["pattern"] for w in weights]
    assert "wrong_approach" in patterns
    assert "vague_request" in patterns
    # Weight should be "high" for top items
    for w in weights:
        assert w["weight"] in ("high", "medium")
        assert isinstance(w["count"], int)


def test_build_weights_empty():
    weights = build_weights({})
    assert weights == []
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /home/shawn/projects/claude-mentor && python3 -m pytest tests/test_sync_insights.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'sync_insights'`

- [ ] **Step 3: Create sync-insights.py**

Create `hooks/lib/sync-insights.py`:

```python
#!/usr/bin/env python3
"""
sync-insights.py — Aggregate insights facets into priority weights.

Reads all JSON files from ~/.claude/usage-data/facets/, aggregates friction
counts, ranks top 3, and writes ~/.claude/coaching/priority-weights.json.

No LLM call — pure aggregation.

Can be imported as a module (for testing) or run as a script.
"""

import glob
import json
import os
import sys
import time

FACETS_DIR = os.path.expanduser("~/.claude/usage-data/facets")
WEIGHTS_FILE = os.path.expanduser("~/.claude/coaching/priority-weights.json")

# Map insights friction categories to mentor friction categories
FRICTION_MAP = {
    "misunderstood_request": "vague_request",
    "wrong_approach": "wrong_approach",
    "buggy_code": "wrong_approach",
    "incomplete_changes": "scope_drift",
    # These don't map to mentor categories — kept as-is for informational value
}


def aggregate_facets(facets_dir: str) -> dict[str, int]:
    """Read all facet JSON files and aggregate friction_counts."""
    counts: dict[str, int] = {}
    try:
        files = glob.glob(os.path.join(facets_dir, "*.json"))
    except Exception:
        return counts

    for f in files:
        try:
            with open(f) as fh:
                data = json.load(fh)
            for key, val in data.get("friction_counts", {}).items():
                counts[key] = counts.get(key, 0) + val
        except Exception:
            continue

    return counts


def map_friction(insights_category: str) -> str:
    """Map an insights friction category to a mentor friction category."""
    return FRICTION_MAP.get(insights_category, insights_category)


def build_weights(friction_counts: dict[str, int]) -> list[dict]:
    """Build top-3 priority weights from aggregated friction counts."""
    if not friction_counts:
        return []

    # Sort by count descending, take top 3
    sorted_frictions = sorted(friction_counts.items(), key=lambda x: -x[1])[:3]

    max_count = sorted_frictions[0][1] if sorted_frictions else 0
    weights = []
    for category, count in sorted_frictions:
        weight = "high" if count >= max_count * 0.5 else "medium"
        weights.append({
            "pattern": map_friction(category),
            "weight": weight,
            "count": count,
        })

    return weights


def main():
    facets_dir = sys.argv[1] if len(sys.argv) > 1 else FACETS_DIR
    output_file = sys.argv[2] if len(sys.argv) > 2 else WEIGHTS_FILE

    counts = aggregate_facets(facets_dir)
    if not counts:
        return

    weights = build_weights(counts)
    result = {
        "last_sync": int(time.time()),
        "top_friction": weights,
    }

    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    tmp_path = output_file + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            json.dump(result, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, output_file)
    except Exception:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /home/shawn/projects/claude-mentor && python3 -m pytest tests/test_sync_insights.py -v
```

Expected: All 6 tests PASS.

- [ ] **Step 5: Make sync-insights.py executable**

```bash
chmod +x hooks/lib/sync-insights.py
```

- [ ] **Step 6: Commit**

```bash
git add hooks/lib/sync-insights.py tests/test_sync_insights.py
git commit -m "feat: add insights sync script with tests (F5)"
```

---

### Task 7: Insights sync trigger + evaluator priority reading (F5)

**Files:**
- Modify: `hooks/stop-logger` (after log append, ~line 118)
- Modify: `hooks/lib/evaluate-prompt.sh:55-57` (after model section, before system prompt)

- [ ] **Step 1: Add sync trigger to stop-logger**

In `hooks/stop-logger`, after the log entry append (after the `>> "$LOG_FILE"` line) and before the user model update trigger, add:

```bash
# ─── Trigger insights sync if facets are newer than weights ─────────────────
FACETS_DIR="${HOME}/.claude/usage-data/facets"
WEIGHTS_FILE="${COACHING_DIR}/priority-weights.json"
SYNC_SCRIPT="${SCRIPT_DIR}/lib/sync-insights.py"

if [[ -d "$FACETS_DIR" ]] && [[ -f "$SYNC_SCRIPT" ]]; then
    NEWEST_FACET=$(find "$FACETS_DIR" -name '*.json' -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
    LAST_SYNC=0
    [[ -f "$WEIGHTS_FILE" ]] && LAST_SYNC=$("$JQ" -r '.last_sync // 0' "$WEIGHTS_FILE" 2>/dev/null || echo "0")

    if [[ -n "$NEWEST_FACET" ]] && [[ "$NEWEST_FACET" -gt "$LAST_SYNC" ]]; then
        python3 "$SYNC_SCRIPT" "$FACETS_DIR" "$WEIGHTS_FILE" &
    fi
fi
```

- [ ] **Step 2: Add priority weights reading to evaluator**

In `hooks/lib/evaluate-prompt.sh`, after the `MODEL_SECTION` block (after line 55) and before the `PHILO_TEXT` line, add:

```bash
# ─── Build priority weights section (from insights sync) ────────────────────
PRIORITY_SECTION=""
PRIORITY_WEIGHTS_FILE="${HOME}/.claude/coaching/priority-weights.json"
if [[ -f "$PRIORITY_WEIGHTS_FILE" ]]; then
    PRIORITY_LIST=$(echo "$PRIORITY_WEIGHTS_FILE" | xargs cat 2>/dev/null | "$JQ" -r '
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
```

Then insert `${PRIORITY_SECTION}` into the system prompt. Add it after the `${MODEL_SECTION}` reference in the system prompt string (after line 67):

```bash
# In the system prompt, change this:
${MODEL_SECTION}
## Intervention Types

# To:
${MODEL_SECTION}
${PRIORITY_SECTION:+${PRIORITY_SECTION}

}## Intervention Types
```

The `${PRIORITY_SECTION:+...}` syntax only expands if PRIORITY_SECTION is non-empty, avoiding blank lines when no weights exist.

- [ ] **Step 3: Verify sync runs**

```bash
# Manually trigger the sync to verify it works:
python3 hooks/lib/sync-insights.py ~/.claude/usage-data/facets ~/.claude/coaching/priority-weights.json
cat ~/.claude/coaching/priority-weights.json
```

Expected: JSON with `last_sync` timestamp and `top_friction` array with up to 3 entries.

- [ ] **Step 4: Commit**

```bash
git add hooks/stop-logger hooks/lib/evaluate-prompt.sh
git commit -m "feat: add insights sync trigger and priority weights in evaluator (F5)"
```

---

### Task 8: User model seeder script (F1)

**Files:**
- Create: `hooks/lib/seed-user-model.sh`

- [ ] **Step 1: Create seed-user-model.sh**

Create `hooks/lib/seed-user-model.sh`:

```bash
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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x hooks/lib/seed-user-model.sh
```

- [ ] **Step 3: Verify seeder runs standalone**

```bash
# Back up current model, then test:
cp ~/.claude/coaching/user-model.json ~/.claude/coaching/user-model.json.bak
printf '{"strengths":[],"weaknesses":[],"current_focus":"","recent_progress":"","intervention_history":[]}\n' > ~/.claude/coaching/user-model.json
bash hooks/lib/seed-user-model.sh
cat ~/.claude/coaching/user-model.json
# Restore backup:
mv ~/.claude/coaching/user-model.json.bak ~/.claude/coaching/user-model.json
```

Expected: The seeded model should have populated `strengths`, `weaknesses`, `current_focus`, and `"seeded_from": "insights"`.

- [ ] **Step 4: Commit**

```bash
git add hooks/lib/seed-user-model.sh
git commit -m "feat: add insights-informed user model seeder script (F1)"
```

---

### Task 9: User model seeder trigger (F1)

**Files:**
- Modify: `hooks/user-prompt-submit:149-152` (after bootstrap block)

- [ ] **Step 1: Add seeder trigger after bootstrap**

In `hooks/user-prompt-submit`, after the bootstrap block that creates the empty user model (after line 152), add:

```bash
# After this block:
if [[ ! -f "$USER_MODEL_FILE" ]]; then
    printf '{"strengths":[],"weaknesses":[],"current_focus":"","recent_progress":"","intervention_history":[]}\n' \
        > "$USER_MODEL_FILE" 2>/dev/null || true
fi

# Add:
# ─── Seed user model from insights if empty and facets available ────────────
SEED_SCRIPT="${SCRIPT_DIR}/lib/seed-user-model.sh"
if [[ -f "$SEED_SCRIPT" ]] && [[ -f "$USER_MODEL_FILE" ]]; then
    MODEL_EMPTY=$("$JQ" -r '
        if ((.strengths // []) | length == 0)
           and ((.weaknesses // []) | length == 0)
           and ((.current_focus // "") | length == 0)
        then "true" else "false" end' "$USER_MODEL_FILE" 2>/dev/null || echo "false")
    FACETS_DIR="${HOME}/.claude/usage-data/facets"
    if [[ "$MODEL_EMPTY" == "true" ]] && [[ -d "$FACETS_DIR" ]]; then
        FACET_COUNT=$(find "$FACETS_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$FACET_COUNT" -gt 0 ]]; then
            DBG "seeding: model empty, ${FACET_COUNT} facets available — running seeder"
            timeout 10 bash "$SEED_SCRIPT" 2>/dev/null || true
        fi
    fi
fi
```

- [ ] **Step 2: Commit**

```bash
git add hooks/user-prompt-submit
git commit -m "feat: trigger user model seeding from insights on first run (F1)"
```

---

### Task 10: Mentor skill status — priority weights display (F5)

**Files:**
- Modify: `skills/mentor/SKILL.md`

- [ ] **Step 1: Add priority weights to status output**

In `skills/mentor/SKILL.md`, in the `status` section (around line 96), update the status report format. After the `### Interaction Log` section, add:

```markdown
### Priority Patterns
[If ~/.claude/coaching/priority-weights.json exists:]
Source: /insights usage analysis
Last synced: [timestamp from last_sync]
Patterns:
  — [pattern] ([weight] priority, [count] occurrences)
  — [pattern] ([weight] priority, [count] occurrences)

[If file doesn't exist:]
Priority patterns: Not configured (run /insights to generate usage data, then patterns sync automatically)
```

- [ ] **Step 2: Add seeded_from to model display**

In the `model` section (around line 149), update the display to show the seeding source:

```markdown
[If user model has seeded_from field:]
**Seeded from:** [value] (initial profile was bootstrapped from /insights data)
```

- [ ] **Step 3: Commit**

```bash
git add skills/mentor/SKILL.md
git commit -m "feat: add priority weights and seeding info to /mentor status (F5)"
```

---

## Self-Review Checklist

**Spec coverage:**
- Feature 2 (Richer Logging): Tasks 1-4 — evaluator friction/skill_available (T1), state file (T2), stop-logger schema + outcome (T3), mentor-recap (T4). Covered.
- Feature 3 (Pattern-Specific Interventions): Task 1 — friction categories with coaching guidance in evaluator. Covered.
- Feature 6 (Reinforcement): Task 5 — intervention_history + reinforcement triggers. Covered.
- Feature 1 (User Model Seeding): Tasks 8-9 — seeder script (T8), trigger in user-prompt-submit (T9). Covered.
- Feature 5 (Closed-Loop Feedback): Tasks 6-7, 10 — sync script + tests (T6), sync trigger + evaluator reading (T7), skill status (T10). Covered.

**Placeholder scan:** No TBD, TODO, or "similar to Task N" found.

**Type consistency:**
- `friction` field name: used consistently as `friction` in evaluator response, `friction` in state file, `FRICTION` in bash variable, `friction_type` in log entry. The log entry uses `friction_type` (not `friction`) to be explicit alongside `intervention_type`. Consistent.
- `skill_available` field name: consistent across evaluator response, state file, bash variable, and log entry.
- `session_outcome` field name: consistent in stop-logger and log entry.
- `FRICTION_MAP` in sync-insights.py: mapping keys match actual insights friction categories from the facets data.
