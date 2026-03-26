# Mentor

Mentor is an inline prompt coaching plugin for Claude Code. It watches every prompt before it reaches Claude and, when it spots something worth flagging, injects a short coaching note so Claude surfaces it at the top of its response.

## How it works

The moment you submit a prompt, Mentor evaluates it against a set of heuristics. If something looks off, it doesn't block your prompt — it slips a coaching note into the context Claude sees:

> ⚠️ Mentor: Prompt is very short. Add: what you want, any constraints, and expected output format.

Claude sees the note, surfaces it to you in a sentence or two, then proceeds with your request as normal. You get the feedback in context, right when it's useful, without any extra steps.

After enough interactions are logged (20 by default), Mentor also starts watching for patterns across your session history. If your recent prompts have frequently been vague and led to extra back-and-forth, it'll flag that too.

Everything is logged to `~/.claude/coaching/interactions.jsonl`.

## Installation

```bash
/plugin install ShawnCholeva/mentor
```

Start a new session after installing — the coaching hooks activate automatically, no configuration needed.

## What it catches

**In both modes:**

| Trigger | What Mentor says |
|---|---|
| Prompt under 6 words (not a skill invocation) | Add what you want, constraints, and expected output format |
| Vague opener ("help me", "fix this", "make it work") under 12 words | Specify what system/component, desired behavior, and what success looks like |
| 5+ vague prompts in your last 20 (after bootstrap) | Pattern: recent prompts have often been vague — try goal + constraints + output format upfront |

**Elite mode adds:**

| Trigger | What Mentor says |
|---|---|
| Prompt over 15 words with no output format specified | No output format specified — adding one often improves response quality |

## Configuration

Use `/mentor` to control the coaching system:

```
/mentor               — show current status and log stats
/mentor on            — enable coaching (on by default)
/mentor off           — disable coaching
/mentor chill         — fewer interventions: high-confidence triggers only (default)
/mentor elite         — more interventions: also fires on missing output format
/mentor bootstrap <n> — set how many interactions to log before pattern detection activates (default: 20)
/mentor status        — same as /mentor with no arguments
```

Config is stored at `~/.claude/coaching/config.json` and persists across sessions.

### Modes in detail

**Chill** (default) — only fires on high-confidence signals: very short prompts and obvious vague openers. Most sessions you won't see it at all.

**Elite** — adds a check for longer prompts that don't specify what kind of output they want. Useful if you want to build the habit of always declaring format upfront.

### Bootstrap minimum

The pattern-detection check (repeated vague prompts) doesn't fire until you have at least `bootstrap_min` interactions in your log. This prevents false positives in a fresh session. Default is 20; set lower to get pattern feedback sooner, higher to let more history accumulate first.

## What the log contains

Each interaction appended to `~/.claude/coaching/interactions.jsonl` includes:

- Session ID and timestamp
- Detected intent (`vague`, `skill-invoked`, or `direct`)
- Which skill was invoked, if any
- Turn count for the conversation
- Whether coaching fired, and with what tags

Run `/mentor-recap` for a structured behavioral analysis across your full history — skill usage, prompt quality trends, efficiency patterns, and recommendations.

## Philosophy

Mentor doesn't try to stop you. It never blocks a prompt. It holds up a mirror at the moment you're most likely to act on what it shows — right before Claude responds.

The goal isn't perfect prompts every time. It's closing the loop between "that response wasn't what I wanted" and "here's what to do differently."

## License

MIT

## Issues

https://github.com/ShawnCholeva/mentor/issues
