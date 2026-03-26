---
name: mentor
description: >-
  Configure the inline coaching system. Toggle coaching on/off, switch between
  chill and elite intervention thresholds, set bootstrap minimum, view current
  settings, and manage your philosophy and user model.
  Usage: /mentor [chill|elite|on|off|status|bootstrap <n>|philosophy|model [reset]]
---

# /mentor

Configure the inline prompt coaching system.

## Usage

```
/mentor chill              — fewer interventions (default, high-confidence only)
/mentor elite              — more interventions (fires on subtler issues too)
/mentor on                 — enable coaching
/mentor off                — disable coaching
/mentor status             — show current settings and log stats
/mentor bootstrap <n>      — set minimum interactions before pattern detection fires (default: 20)
/mentor philosophy         — show your coaching philosophy and how to edit it
/mentor model              — display your current user model (strengths, weaknesses, focus)
/mentor model reset        — reset the user model to empty
```

---

## Step 1 — Parse the argument

Read the argument provided by the user (after `/mentor`).

If no argument provided → show status (same as `status`).

Valid arguments: `chill`, `elite`, `on`, `off`, `status`, `bootstrap <n>`, `philosophy`, `model`, `model reset`.
If unrecognized: explain valid options and stop.

---

## Step 2 — Execute the command

### `on` / `off`

Use the Bash tool to update `~/.claude/coaching/config.json`:

```bash
CONFIG_FILE="$HOME/.claude/coaching/config.json"
mkdir -p "$HOME/.claude/coaching"
CURRENT=$(cat "$CONFIG_FILE" 2>/dev/null || echo '{}')
python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['enabled'] = $([ '$ARG' == 'on' ] && echo 'True' || echo 'False')
print(json.dumps(d, indent=2))
" "$CURRENT" > "$CONFIG_FILE"
```

Confirm: "Coaching is now **[on/off]**."

---

### `chill` / `elite`

Update the `mode` field in `~/.claude/coaching/config.json`:

```bash
python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['enabled'] = True
d['mode'] = 'NEWMODE'
print(json.dumps(d, indent=2))
" "$CURRENT" > "$CONFIG_FILE"
```

Confirm with a one-line explanation:
- **chill**: "Coaching set to chill — only high-confidence triggers fire (vague prompts, missing diagnostics)."
- **elite**: "Coaching set to elite — additional triggers enabled (missing output format, scope underestimation, subtler issues)."

---

### `bootstrap <n>`

Update the `bootstrap_min` field in `~/.claude/coaching/config.json`.

If `<n>` is not a positive integer: tell the user and stop.

Confirm: "Bootstrap minimum set to **N**. Pattern detection fires after N interactions are logged."

---

### `status`

Read `~/.claude/coaching/config.json`, `~/.claude/coaching/interactions.jsonl`, `~/.claude/coaching/user-model.json`, then report:

```
## Coaching Status

Enabled: [yes / no]
Mode: [chill / elite]
Bootstrap minimum: [N] interactions
Philosophy: [loaded / not found — run /mentor philosophy for details]

### User Model
Strengths: [list or "none yet"]
Weaknesses: [list or "none yet"]
Current focus: [value or "none yet"]
Recent progress: [value or "none yet"]
Intervention history: [N entries]

### Interaction Log
[N] interactions recorded
  — Coaching triggered: [X] times ([Y]%)
  — Last logged: [timestamp]

Run /mentor-recap for a full behavioral analysis.
```

If the log file doesn't exist yet: "No interactions logged yet. The coaching system activates automatically on your next prompt."

---

### `philosophy`

Read `~/.claude/coaching/philosophy.md` using the Read tool and display it.

Then explain:

"This file defines your mentor's operating beliefs — the principles it uses to decide what matters and when to intervene. Edit it directly to customize your mentor's values:

```
~/.claude/coaching/philosophy.md
```

Changes take effect immediately on the next prompt. The default philosophy was seeded from the plugin's `defaults/philosophy.md`."

If the file doesn't exist: "Philosophy file not found at `~/.claude/coaching/philosophy.md`. It will be created automatically on your next prompt, seeded from the plugin defaults. You can also create it manually."

---

### `model`

Read `~/.claude/coaching/user-model.json` using the Read tool.

Display it in a readable format:

```
## Your User Model

**Strengths**
[list each strength, or "None recorded yet"]

**Weaknesses**
[list each weakness, or "None recorded yet"]

**Current focus:** [value or "None set"]
**Recent progress:** [value or "None yet"]

**Intervention history** ([N] entries)
[list last 5 entries, or "None yet"]
```

Then explain: "This model is updated automatically every 5 interactions by the stop hook. It informs the mentor's coaching — areas you're strong in won't be coached, and your current focus gets extra weight."

---

### `model reset`

Reset the user model to empty:

```bash
CONFIG_FILE="$HOME/.claude/coaching/user-model.json"
printf '{"strengths":[],"weaknesses":[],"current_focus":"","recent_progress":"","intervention_history":[]}\n' > "$CONFIG_FILE"
```

Confirm: "User model reset. The mentor will rebuild it from scratch as you continue working."

---

## Step 3 — Done

No further action needed — this is a configuration command.
