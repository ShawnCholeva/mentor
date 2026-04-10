# Skill Catalog Cache Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix skill invocation tracking so that `/skill` prompts reliably record `skill_used` in `interactions.jsonl`.

**Architecture:** Drop the STATE_FILE catalog cache entirely. Always build the skill catalog fresh from `installed_plugins.json` before the slash-command guard runs. Update the guard to use the in-memory catalog and handle creating STATE_FILE when it doesn't exist yet.

**Tech Stack:** Bash, jq

---

## Files

- Modify: `hooks/user-prompt-submit`
- Create: `tests/test_skill_capture.sh`

---

### Task 1: Write integration test (failing)

**Files:**
- Create: `tests/test_skill_capture.sh`

The hook uses `$HOME` for all paths. By overriding `HOME` to a temp dir, the test controls the full environment without touching real user data.

- [ ] **Step 1: Create the test file**

```bash
cat > tests/test_skill_capture.sh << 'TESTEOF'
#!/usr/bin/env bash
# Integration test: skill capture in user-prompt-submit
# Sets HOME to a temp dir to isolate the hook from real user data.

set -euo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/user-prompt-submit"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; (( PASS++ )) || true; }
fail() { echo "FAIL: $1"; (( FAIL++ )) || true; }

run_test() {
    local name="$1"
    local prompt="$2"
    local expected_skill="$3"   # empty string means expect no skill_invoked

    local TMPDIR
    TMPDIR=$(mktemp -d)
    trap "rm -rf '$TMPDIR'" EXIT

    export HOME="$TMPDIR"
    local SESSION_ID="test-session-$$"
    local COACHING_DIR="$TMPDIR/.claude/coaching"
    local STATE_FILE="$COACHING_DIR/session-${SESSION_ID}.tmp"
    local INSTALLED_PLUGINS="$TMPDIR/.claude/plugins/installed_plugins.json"
    local PLUGIN_PATH="$TMPDIR/.claude/plugins/cache/test-plugin/test/1.0.0"

    # Set up fake plugin with a known skill
    mkdir -p "$PLUGIN_PATH/skills/brainstorming"
    cat > "$PLUGIN_PATH/skills/brainstorming/SKILL.md" << 'EOF'
---
name: brainstorming
description: Use when you want to brainstorm a new feature or design
---
Content here.
EOF

    mkdir -p "$(dirname "$INSTALLED_PLUGINS")"
    printf '{"version":2,"plugins":{"test@test":[{"scope":"user","installPath":"%s"}]}}\n' \
        "$PLUGIN_PATH" > "$INSTALLED_PLUGINS"

    mkdir -p "$COACHING_DIR"
    # Write enough fake interactions to pass bootstrap check
    for i in $(seq 1 20); do
        printf '{"id":"%s","session_id":"old","timestamp":1,"intent":"direct","skill_used":[],"turn_count":1,"prompt_summary":"x","coaching_triggered":false,"intervention_type":null,"friction_type":null,"skill_suggested":null,"skill_gap_description":null,"session_outcome":"unknown"}\n' \
            "fake-$i" >> "$COACHING_DIR/interactions.jsonl"
    done

    # Run hook, capture stdout
    local INPUT
    INPUT=$(printf '{"prompt":"%s","session_id":"%s"}' "$prompt" "$SESSION_ID")
    echo "$INPUT" | bash "$HOOK" > /dev/null 2>&1 || true

    # Assert
    if [[ -n "$expected_skill" ]]; then
        if [[ -f "$STATE_FILE" ]]; then
            local actual
            actual=$(jq -r '.skill_invoked // ""' "$STATE_FILE" 2>/dev/null || echo "")
            if [[ "$actual" == "$expected_skill" ]]; then
                pass "$name"
            else
                fail "$name — expected skill_invoked='$expected_skill', got '$actual'"
            fi
        else
            fail "$name — STATE_FILE not created"
        fi
    else
        if [[ -f "$STATE_FILE" ]]; then
            local actual
            actual=$(jq -r '.skill_invoked // ""' "$STATE_FILE" 2>/dev/null || echo "")
            if [[ -z "$actual" || "$actual" == "null" ]]; then
                pass "$name"
            else
                fail "$name — expected no skill_invoked, got '$actual'"
            fi
        else
            pass "$name"  # no state file = no skill captured, correct
        fi
    fi

    trap - EXIT
    rm -rf "$TMPDIR"
}

# Test 1: slash command matching a known skill captures it
run_test "known skill captured on first prompt" "/brainstorming" "/brainstorming"

# Test 2: unknown slash command does not write to state
run_test "unknown slash command not captured" "/unknown-command" ""

# Test 3: known skill captured even when STATE_FILE already exists (e.g. from coaching)
# We pre-create the state file with some existing coaching data
run_test_with_existing_state() {
    local name="$1"
    local prompt="$2"
    local expected_skill="$3"

    local TMPDIR
    TMPDIR=$(mktemp -d)

    export HOME="$TMPDIR"
    local SESSION_ID="test-session-$$"
    local COACHING_DIR="$TMPDIR/.claude/coaching"
    local STATE_FILE="$COACHING_DIR/session-${SESSION_ID}.tmp"
    local INSTALLED_PLUGINS="$TMPDIR/.claude/plugins/installed_plugins.json"
    local PLUGIN_PATH="$TMPDIR/.claude/plugins/cache/test-plugin/test/1.0.0"

    mkdir -p "$PLUGIN_PATH/skills/brainstorming"
    cat > "$PLUGIN_PATH/skills/brainstorming/SKILL.md" << 'EOF'
---
name: brainstorming
description: Use when you want to brainstorm a new feature or design
---
EOF

    mkdir -p "$(dirname "$INSTALLED_PLUGINS")"
    printf '{"version":2,"plugins":{"test@test":[{"scope":"user","installPath":"%s"}]}}\n' \
        "$PLUGIN_PATH" > "$INSTALLED_PLUGINS"

    mkdir -p "$COACHING_DIR"
    for i in $(seq 1 20); do
        printf '{"id":"%s","session_id":"old","timestamp":1,"intent":"direct","skill_used":[],"turn_count":1,"prompt_summary":"x","coaching_triggered":false,"intervention_type":null,"friction_type":null,"skill_suggested":null,"skill_gap_description":null,"session_outcome":"unknown"}\n' \
            "fake-$i" >> "$COACHING_DIR/interactions.jsonl"
    done

    # Pre-create STATE_FILE with existing coaching data (no skill_catalog)
    printf '{"last_intervention_ts":1000,"coaching_triggered":true,"type":"nudge","message":"test"}\n' \
        > "$STATE_FILE"

    local INPUT
    INPUT=$(printf '{"prompt":"%s","session_id":"%s"}' "$prompt" "$SESSION_ID")
    echo "$INPUT" | bash "$HOOK" > /dev/null 2>&1 || true

    if [[ -f "$STATE_FILE" ]]; then
        local actual
        actual=$(jq -r '.skill_invoked // ""' "$STATE_FILE" 2>/dev/null || echo "")
        if [[ "$actual" == "$expected_skill" ]]; then
            pass "$name"
        else
            fail "$name — expected skill_invoked='$expected_skill', got '$actual'"
        fi
    else
        fail "$name — STATE_FILE missing after test"
    fi

    rm -rf "$TMPDIR"
}

run_test_with_existing_state "known skill captured when STATE_FILE exists" "/brainstorming" "/brainstorming"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
TESTEOF
chmod +x tests/test_skill_capture.sh
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
bash tests/test_skill_capture.sh
```

Expected: `FAIL: known skill captured on first prompt — STATE_FILE not created` (or similar). The test fails because the current hook doesn't capture skills when STATE_FILE doesn't already exist.

- [ ] **Step 3: Commit the failing test**

```bash
git add tests/test_skill_capture.sh
git commit -m "test: add failing integration test for skill capture"
```

---

### Task 2: Move catalog build before slash-command guard

**Files:**
- Modify: `hooks/user-prompt-submit`

The current catalog-build section lives at lines ~152–232 and is never reached for slash-command prompts (which exit at ~line 116). Move it to just after `STATE_FILE` is defined (~line 88), before the slash-command guard.

- [ ] **Step 1: Remove the old catalog-build section (lines ~152–165)**

Find and remove this block (the opening of the old build section):

```bash
# ─── Build skill catalog (once per session) ──────────────────────────────────
SKILL_CATALOG="[]"
SKILL_CATALOG_BUILT=false
INSTALLED_PLUGINS="${HOME}/.claude/plugins/installed_plugins.json"

if [[ -n "$SESSION_ID" ]] && [[ -f "$STATE_FILE" ]]; then
    # Reuse cached catalog from session state
    SKILL_CATALOG=$("$JQ" -c '.skill_catalog // []' "$STATE_FILE" 2>/dev/null || echo "[]")
    [[ "$SKILL_CATALOG" != "[]" ]] && SKILL_CATALOG_BUILT=true
fi

if [[ "$SKILL_CATALOG_BUILT" == "false" ]] && [[ -f "$INSTALLED_PLUGINS" ]]; then
```

Replace the entire block (from the `# ─── Build skill catalog` comment down through the closing `fi` of the outer `if [[ "$SKILL_CATALOG_BUILT" ... ]]` block, ending at the `DBG "skill_catalog: ..."` line) with nothing. You'll re-add it in the next step.

- [ ] **Step 2: Insert the new catalog-build section before the slash-command guard**

Find the `STATE_FILE` definition line (looks like `STATE_FILE="${COACHING_DIR}/session-${SESSION_ID}.tmp"`) and insert the new block immediately after it:

```bash
# ─── Build skill catalog (always fresh from installed_plugins.json) ──────────
SKILL_CATALOG="[]"
INSTALLED_PLUGINS="${HOME}/.claude/plugins/installed_plugins.json"

if [[ -f "$INSTALLED_PLUGINS" ]]; then
    CATALOG_ENTRIES="[]"
    while IFS= read -r install_path; do
        [[ -z "$install_path" ]] && continue
        for skill_md in "$install_path"/skills/*/SKILL.md; do
            [[ -f "$skill_md" ]] || continue
            skill_dir=$(basename "$(dirname "$skill_md")")

            # Skip meta-skills and self-referential skills
            case "$skill_dir" in
                using-*|mentor|mentor-recap) continue ;;
            esac

            # Extract name and description from YAML frontmatter
            skill_name=""
            skill_desc=""
            in_frontmatter=false
            in_desc=false
            while IFS= read -r line; do
                line="${line%$'\r'}"
                if [[ "$line" == "---" ]]; then
                    if [[ "$in_frontmatter" == "true" ]]; then
                        break
                    fi
                    in_frontmatter=true
                    continue
                fi
                if [[ "$in_frontmatter" == "true" ]]; then
                    if [[ "$line" =~ ^name:\ *(.*) ]]; then
                        skill_name="${BASH_REMATCH[1]}"
                        in_desc=false
                    elif [[ "$line" =~ ^description:\ *\>-?$ ]]; then
                        in_desc=true
                        skill_desc=""
                    elif [[ "$line" =~ ^description:\ *\"(.*)\"$ ]]; then
                        skill_desc="${BASH_REMATCH[1]}"
                        in_desc=false
                    elif [[ "$line" =~ ^description:\ *(.*) ]]; then
                        skill_desc="${BASH_REMATCH[1]}"
                        in_desc=true
                    elif [[ "$in_desc" == "true" ]]; then
                        if [[ "$line" =~ ^[a-z_]+: ]] || [[ -z "$line" ]]; then
                            in_desc=false
                        else
                            skill_desc="${skill_desc} $(echo "$line" | sed 's/^[[:space:]]*//')"
                        fi
                    fi
                fi
            done < "$skill_md"

            # Use directory name as fallback for skill name
            [[ -z "$skill_name" ]] && skill_name="$skill_dir"

            # Skip skills with no trigger description
            skill_desc=$(echo "$skill_desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$skill_desc" ]] && continue

            # Truncate description to 200 chars
            skill_desc="${skill_desc:0:200}"

            CATALOG_ENTRIES=$(echo "$CATALOG_ENTRIES" | "$JQ" -c \
                --arg name "$skill_name" \
                --arg trigger "$skill_desc" \
                '. + [{"name": $name, "trigger": $trigger}]' 2>/dev/null || echo "$CATALOG_ENTRIES")
        done
    done < <("$JQ" -r '.plugins | to_entries[] | .value[0].installPath // empty' "$INSTALLED_PLUGINS" 2>/dev/null)

    SKILL_CATALOG="$CATALOG_ENTRIES"
fi
DBG "skill_catalog: entries=$(echo "$SKILL_CATALOG" | "$JQ" 'length' 2>/dev/null || echo '?')"
```

- [ ] **Step 3: Run the test — expect partial progress**

```bash
bash tests/test_skill_capture.sh
```

Expected: Test 1 still fails (`STATE_FILE not created`) because the slash-command guard still checks `[[ -f "$STATE_FILE" ]]` before attempting capture. Tests 2 and 3 may vary. We fix this in the next task.

---

### Task 3: Update slash-command guard to use in-memory catalog

**Files:**
- Modify: `hooks/user-prompt-submit`

The slash-command guard currently reads `skill_catalog` from STATE_FILE and skips capture if STATE_FILE doesn't exist. Change it to use the in-memory `$SKILL_CATALOG` and create STATE_FILE from scratch when needed.

- [ ] **Step 1: Replace the slash-command guard block**

Find the existing guard (starts with `# ─── Guard: skill invocations`) and replace it entirely with:

```bash
# ─── Guard: skill invocations ─────────────────────────────────────────────────
if echo "$PROMPT" | grep -qE "^/[a-z]"; then
    _SKILL_WITH_SLASH=$(echo "$PROMPT" | grep -oE "^/[a-z][a-z0-9:-]*" | head -1 || echo "")
    _SKILL_BARE="${_SKILL_WITH_SLASH#/}"
    if [[ -n "$SESSION_ID" ]]; then
        _IN_CAT=$(printf '%s' "$SKILL_CATALOG" | "$JQ" -r --arg s "$_SKILL_BARE" \
            'any(.[]; .name == $s)' 2>/dev/null || echo "false")
        if [[ "$_IN_CAT" == "true" ]]; then
            DBG "skill-capture: MATCH skill=${_SKILL_WITH_SLASH} → writing state"
            if [[ -f "$STATE_FILE" ]]; then
                _MERGED=$(cat "$STATE_FILE" 2>/dev/null | "$JQ" -c --arg s "$_SKILL_WITH_SLASH" \
                    '. + {skill_invoked: $s, coaching_triggered: false}' 2>/dev/null) || true
            else
                _MERGED=$("$JQ" -n -c --arg s "$_SKILL_WITH_SLASH" \
                    '{skill_invoked: $s, coaching_triggered: false}' 2>/dev/null) || true
            fi
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
    fi
    _EXIT_REASON="slash-command"
    exit 0
fi
```

- [ ] **Step 2: Run the test — expect all 3 to pass**

```bash
bash tests/test_skill_capture.sh
```

Expected:
```
PASS: known skill captured on first prompt
PASS: unknown slash command not captured
PASS: known skill captured when STATE_FILE exists

Results: 3 passed, 0 failed
```

If any test fails, read the failure message. The most likely issue is a jq error — check that `$SKILL_CATALOG` is a valid JSON array at the point of the guard.

---

### Task 4: Remove skill_catalog from coaching STATE_FILE write and make it atomic

**Files:**
- Modify: `hooks/user-prompt-submit`

The coaching write at the bottom of the file uses `jq -n` to create a fresh STATE_FILE object. It currently includes `skill_catalog` (which we no longer store there) and uses a direct overwrite (`> "$STATE_FILE"`) which can truncate the file on jq failure.

- [ ] **Step 1: Remove `skill_catalog` from the coaching write**

Find the coaching state write block (starts with `"$JQ" -n \` near `--argjson skill_catalog`). Remove the `--argjson skill_catalog "$SKILL_CATALOG" \` argument line and the `skill_catalog: $skill_catalog` field from the jq object expression.

Before (relevant lines):
```bash
"$JQ" -n \
    --argjson ts "$NOW_EPOCH" \
    --argjson coaching_triggered true \
    --arg     type    "$INTERVENTION_TYPE" \
    --arg     message "$FEEDBACK" \
    --argjson skill_catalog "$SKILL_CATALOG" \
    "${FRICTION_ARGS[@]+"${FRICTION_ARGS[@]}"}" \
    "${SKILL_ARGS[@]+"${SKILL_ARGS[@]}"}" \
    '{last_intervention_ts: $ts, coaching_triggered: $coaching_triggered, type: $type, message: $message, skill_catalog: $skill_catalog}
     + (if $ARGS.named | has("friction") then {friction: $friction} else {} end)
     + (if $ARGS.named | has("skill_suggested") then {skill_suggested: $skill_suggested} else {} end)
     + (if $ARGS.named | has("skill_gap_description") then {skill_gap_description: $skill_gap_description} else {} end)' \
    > "$STATE_FILE" 2>/dev/null || true
```

After:
```bash
_TMP_STATE="${STATE_FILE}.tmp.$$"
"$JQ" -n \
    --argjson ts "$NOW_EPOCH" \
    --argjson coaching_triggered true \
    --arg     type    "$INTERVENTION_TYPE" \
    --arg     message "$FEEDBACK" \
    "${FRICTION_ARGS[@]+"${FRICTION_ARGS[@]}"}" \
    "${SKILL_ARGS[@]+"${SKILL_ARGS[@]}"}" \
    '{last_intervention_ts: $ts, coaching_triggered: $coaching_triggered, type: $type, message: $message}
     + (if $ARGS.named | has("friction") then {friction: $friction} else {} end)
     + (if $ARGS.named | has("skill_suggested") then {skill_suggested: $skill_suggested} else {} end)
     + (if $ARGS.named | has("skill_gap_description") then {skill_gap_description: $skill_gap_description} else {} end)' \
    > "$_TMP_STATE" 2>/dev/null \
    && mv "$_TMP_STATE" "$STATE_FILE" 2>/dev/null \
    || { rm -f "$_TMP_STATE" 2>/dev/null || true; } || true
```

Also find and remove the debug line that references `from_cache`:
```bash
DBG "state_write: path=$STATE_FILE coaching=true type=$INTERVENTION_TYPE friction=${FRICTION:-none} exists=$([ -f "$STATE_FILE" ] && echo yes || echo no)"
```
(This line is fine as-is — no change needed, it doesn't reference skill_catalog.)

- [ ] **Step 2: Run the tests again to confirm nothing regressed**

```bash
bash tests/test_skill_capture.sh
```

Expected:
```
PASS: known skill captured on first prompt
PASS: unknown slash command not captured
PASS: known skill captured when STATE_FILE exists

Results: 3 passed, 0 failed
```

- [ ] **Step 3: Commit**

```bash
git add hooks/user-prompt-submit tests/test_skill_capture.sh
git commit -m "fix: drop skill catalog cache, always build fresh from installed_plugins.json

Fixes race condition where slash-command prompts exit before catalog
is built. Catalog now built from installed_plugins.json before the
slash-command guard on every prompt. STATE_FILE created fresh when
skill invoked in a new session."
```

---

## Verification

After implementation, test on the target machine by running `/mentor` (or any installed skill) as the first prompt in a new session:

```bash
# In a new Claude Code session, run /mentor then check:
tail -1 ~/.claude/coaching/interactions.jsonl | jq '.skill_used'
# Expected: ["/mentor"]

# Also check debug log for MATCH line:
grep "skill-capture" ~/.claude/coaching/hook-debug.log | tail -5
# Expected: "skill-capture: MATCH skill=/mentor → writing state"
```
