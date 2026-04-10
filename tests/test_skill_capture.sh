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
    local pre_state="${4:-}"    # optional: pre-existing state JSON to write to STATE_FILE

    local TMPDIR
    TMPDIR=$(mktemp -d)
    trap "rm -rf \"$TMPDIR\"" EXIT

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

    # If pre_state provided, write it to STATE_FILE before running hook
    if [[ -n "$pre_state" ]]; then
        printf '%s\n' "$pre_state" > "$STATE_FILE"
    fi

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
# This passes both before and after the fix — unrecognized commands should never capture

# Test 3: known skill captured even when STATE_FILE already exists (e.g. from coaching)
# We pre-create the state file with some existing coaching data
run_test "known skill captured when STATE_FILE exists" "/brainstorming" "/brainstorming" \
    '{"last_intervention_ts":1000,"coaching_triggered":true,"type":"nudge","message":"test"}'

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
