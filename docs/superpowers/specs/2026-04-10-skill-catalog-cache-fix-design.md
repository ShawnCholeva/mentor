---
title: Fix skill catalog race condition in user-prompt-submit
date: 2026-04-10
status: approved
---

## Problem

Skill invocations (e.g. `/mentor`) are not being recorded in the interaction log (`interactions.jsonl`). The `skill_used` field always shows `[]` even when a skill was clearly invoked.

### Root Cause

Two compounding bugs in `hooks/user-prompt-submit`:

**Bug 1 — Ordering:** The catalog-build section (which scans `installed_plugins.json` for SKILL.md files) runs after the slash-command guard exits. Slash-command prompts exit early at line 115, so the catalog is never built during a skill invocation.

**Bug 2 — Cache erasure:** The skill catalog was cached in `STATE_FILE`. `STATE_FILE` is only created when coaching fires. If coaching hasn't fired yet, STATE_FILE doesn't exist and skill capture is skipped with "no catalog cached". Even when the catalog was present in STATE_FILE, a subsequent coaching write using `jq -n > $STATE_FILE` (direct overwrite) could wipe it if `$SKILL_CATALOG` happened to be `[]` at that moment.

## Solution

Drop the STATE_FILE catalog cache entirely and always build fresh from `installed_plugins.json`.

`installed_plugins.json` is maintained by Claude Code and is always current. Scanning ~19 SKILL.md files takes ~1ms — negligible compared to the Claude API call made on coaching prompts. This eliminates both bugs by removing the caching layer that caused them.

## Changes to `hooks/user-prompt-submit`

### 1. Move catalog build before the slash-command guard

The catalog-build block currently at lines 163–232 moves to just after `STATE_FILE` is defined (after line 88), before the slash-command guard at line 90.

Remove the cache-read block (currently lines 157–161) and the `SKILL_CATALOG_BUILT` flag entirely. The catalog is always built fresh from `installed_plugins.json`.

### 2. Rewrite the slash-command guard to use in-memory `$SKILL_CATALOG`

Replace the current guard logic that reads `skill_catalog` from STATE_FILE with a direct check against the in-memory `$SKILL_CATALOG` variable (already built in step 1).

Remove the `[[ -f "$STATE_FILE" ]]` precondition that prevented capture when no STATE_FILE existed. Instead:
- If STATE_FILE exists: merge `skill_invoked` and `coaching_triggered: false` into it (existing behavior)
- If STATE_FILE does not exist: create it fresh with `jq -n '{skill_invoked: $s, coaching_triggered: false}'`

### 3. Remove `skill_catalog` from the coaching STATE_FILE write

Remove `skill_catalog` from the `jq -n` object written at the coaching fire section (currently lines 355–362). The catalog no longer lives in STATE_FILE.

### 4. Make the coaching STATE_FILE write atomic

Change the coaching write from direct overwrite (`> "$STATE_FILE"`) to the atomic temp-file-then-move pattern already used elsewhere in the file. This prevents STATE_FILE truncation if `jq` fails mid-write.

## No changes to `stop-logger`

`stop-logger` reads `skill_invoked` from STATE_FILE. That field is still written correctly by the updated slash-command guard.

## Verification

After the fix, invoking `/mentor` as the first prompt in a fresh session should:
1. Build catalog (entries=19) from `installed_plugins.json`
2. Match `/mentor` in the in-memory catalog
3. Create STATE_FILE with `{skill_invoked: "/mentor", coaching_triggered: false}`
4. `stop-logger` reads `skill_invoked="/mentor"` → logs `skill_used=["/mentor"]`

Check `~/.claude/coaching/hook-debug.log` for `skill-capture: MATCH` and `~/.claude/coaching/interactions.jsonl` for `skill_used` containing the skill name.
