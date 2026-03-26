---
name: mentor-recap
description: >-
  Analyzes your cross-session Claude usage patterns from the interaction log
  (~/.claude/coaching/interactions.jsonl). Produces a structured behavioral
  report: skill usage, prompt quality trends, efficiency patterns, and suggestions.
  Usage: /mentor-recap
---

# /mentor-recap

Analyze the user's cross-session Claude usage patterns and produce a longitudinal coaching report.

---

## Step 1 — Load the interaction log

Read `~/.claude/coaching/interactions.jsonl` using the Read tool.

If the file does not exist or is empty:
→ Tell the user Mentor hasn't logged enough data yet.
→ Remind them the hook logs automatically on every interaction — just keep using Claude normally.
→ Stop here.

If fewer than 20 entries exist:
→ Show what's available but note that patterns are more reliable after 20+ interactions.

Parse the JSONL: each line is one interaction entry with fields:
- `intent` — how the prompt was classified: `vague`, `skill-invoked`, or `direct`
- `skill_used` — skill invoked (e.g. `/mentor`, or null if a direct prompt)
- `turn_count` — number of turns to complete the task
- `coaching_triggered` — whether Mentor intervened
- `tags` — matched trigger types (vague, high_iteration, missing_structure)
- `timestamp` — ISO8601

Use the last 100 entries (or all if fewer).

---

## Step 2 — Compute metrics

Calculate:

| Metric | How |
|--------|-----|
| Total interactions | Count entries |
| Intent distribution | Count by `intent` field |
| Skill usage | Count and rank each distinct `skill_used` value (non-null) |
| Direct prompts | Count entries where `skill_used` is null |
| Avg turn count | Mean of `turn_count` across all entries |
| High-iteration rate | % of entries where `turn_count` >= 4 |
| Mentor trigger rate | % where `coaching_triggered` = true |
| Top tags | Most frequent values in `tags` arrays |

---

## Step 3 — Identify patterns

Look for:

1. **Vagueness pattern** — high frequency of `vague` intent or tag → prompt structure habit
2. **High iteration pattern** — avg turn_count > 3 → prompts not landing on first try
4. **Improving trend** — if sortable by timestamp: is avg turn_count decreasing over time?
5. **Mentor frequency** — if coaching triggered on >40% of prompts, threshold may be too sensitive

---

## Step 4 — Produce the report

Format the output as:

```
## Mentor Recap
(Last N interactions · Cross-session)

### Summary
[2-3 sentence overview of overall posture]

### Patterns Detected
[For each pattern found:]
Pattern: [name]
  Frequency: [X% of interactions / N occurrences]
  Impact: [what this costs — extra turns, rework, wrong output]
  Suggestion: [specific, actionable change]

### Skill Usage
[Ranked list of skills used and how often, or "No skill invocations recorded" if none]
[Direct prompts: N]

### Efficiency
Avg turns per task: [N]
High-iteration tasks (4+ turns): [X%]
[If trend data available: "Turn count is trending down/up over last N sessions"]

### Mentor Activity
Triggered: [X% of prompts]
Top trigger: [most common tag]

### Top Recommendations
1. [Most impactful change]
2. [Second most impactful]
3. [Third]
```

Keep the report concise. Focus on actionable patterns, not exhaustive statistics.

---

## Step 5 — Suggest next action

End with one of:
- If Mentor trigger rate is high: "Run `/mentor chill` to reduce intervention frequency, or `/mentor elite` if you want more"
- If turn count is high and vagueness is the top tag: "Your prompts may benefit from more upfront structure — goal, constraints, output format"
- If no strong patterns: "Things look solid. Keep an eye on turn count as a leading indicator."
