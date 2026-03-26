---
name: mentor
description: >-
  Configure the inline coaching system. Toggle coaching on/off, switch between
  chill and elite intervention thresholds, set bootstrap minimum, and view current settings.
  Usage: /mentor [chill|elite|on|off|status|bootstrap <n>]
---

# /mentor

Configure the inline prompt coaching system.

## Usage

```
/mentor chill         — fewer interventions (default, high-confidence only)
/mentor elite         — more interventions (fires on missing structure too)
/mentor on            — enable coaching
/mentor off           — disable coaching
/mentor status        — show current settings and log stats
/mentor bootstrap <n> — set minimum interactions before pattern detection fires (default: 20)
```

---

## Step 1 — Parse the argument

Read the argument provided by the user (after `/mentor`).

If no argument provided → show status (same as `status`).

Valid arguments: `chill`, `elite`, `on`, `off`, `status`, `bootstrap <n>`.
If unrecognized: explain valid options and stop.

---

## Step 2 — Execute the command

### `on` / `off`

Use the Bash tool to update `~/.claude/coaching/config.json`:

```bash
# Read current config (or use defaults)
CONFIG_FILE="$HOME/.claude/coaching/config.json"
mkdir -p "$HOME/.claude/coaching"

# Read existing or default
CURRENT=$(cat "$CONFIG_FILE" 2>/dev/null || echo '{}')

# Update enabled field
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
- **chill**: "Coaching set to chill — only high-confidence triggers fire (vagueness)."
- **elite**: "Coaching set to elite — additional triggers enabled (missing output format on complex prompts)."

---

### `bootstrap <n>`

Update the `bootstrap_min` field in `~/.claude/coaching/config.json`:

```bash
CONFIG_FILE="$HOME/.claude/coaching/config.json"
mkdir -p "$HOME/.claude/coaching"
CURRENT=$(cat "$CONFIG_FILE" 2>/dev/null || echo '{}')

python3 -c "
import json, sys
d = json.loads(sys.argv[1])
n = int(sys.argv[2])
if n < 1:
    print('error', end='')
else:
    d['bootstrap_min'] = n
    print(json.dumps(d, indent=2))
" "$CURRENT" "<N>" > "$CONFIG_FILE"
```

If `<n>` is not a positive integer: tell the user and stop.

Confirm: "Bootstrap minimum set to **N**. Pattern detection fires after N interactions are logged."

---

### `status`

Read `~/.claude/coaching/config.json` and `~/.claude/coaching/interactions.jsonl`, then report:

```
## Coaching Status

Mode: [chill / elite]
Enabled: [yes / no]
Bootstrap minimum: [N] interactions (patterns active after this)

Log: [N] interactions recorded
  — Coaching triggered: [X] times ([Y]%)
  — Last logged: [timestamp]

Run /mentor-recap for a full behavioral analysis.
```

If the log file doesn't exist yet: "No interactions logged yet. The coaching system activates automatically on your next prompt."

---

## Step 3 — Done

No further action needed — this is a configuration command.
