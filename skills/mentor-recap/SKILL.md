---
name: mentor-recap
description: >-
  Analyzes your cross-session Claude usage patterns from the interaction log
  (~/.claude/coaching/interactions.jsonl) and user model
  (~/.claude/coaching/user-model.json). Produces a structured behavioral
  report: skill usage, prompt quality trends, efficiency patterns, user model
  state, and suggestions.
  Usage: /mentor-recap
---

# /mentor-recap

Analyze the user's cross-session Claude usage patterns and produce a longitudinal coaching report.

---

## Step 1 — Load the interaction log and user model

Read both files in parallel:
- `~/.claude/coaching/interactions.jsonl`
- `~/.claude/coaching/user-model.json`

If the interaction log does not exist or is empty:
→ Tell the user Mentor hasn't logged enough data yet.
→ Remind them the hook logs automatically on every interaction — just keep using Claude normally.
→ Stop here.

If fewer than 20 entries exist:
→ Show what's available but note that patterns are more reliable after 20+ interactions.

Parse the JSONL: each line is one interaction entry with fields:
- `intent` — how the prompt was classified: `vague`, `skill-invoked`, or `direct`
- `skill_used` — skills invoked this session as a JSON array (e.g. `["/mentor", "/brainstorm"]`, or `[]` if none). Older entries may have a string or null instead — treat a string as a single-element array and null as `[]`.
- `turn_count` — number of turns to complete the task
- `coaching_triggered` — whether Mentor intervened
- `intervention_type` — type of intervention: `nudge`, `correction`, `challenge`, `reinforcement`, or null
- `friction_type` — friction category when coaching fired: `vague_request`, `wrong_approach`, `missing_diagnostics`, `scope_drift`, `missing_skill`, or null
- `skill_suggested` — specific skill the mentor recommended (e.g., `/superpowers:systematic-debugging`, or null)
- `skill_gap_description` — one-sentence sketch of an unmet skill need (or null)
- `session_outcome` — estimated outcome: `achieved`, `not_achieved`, or `unknown`
- `timestamp` — Unix epoch (seconds)

Use the last 100 entries (or all if fewer).

Parse the user model JSON (or use empty defaults if missing/invalid):
- `strengths`, `weaknesses`, `current_focus`, `recent_progress`, `intervention_history`

---

## Step 2 — Compute metrics

Calculate:

| Metric | How |
|--------|-----|
| Total interactions | Count entries |
| Intent distribution | Count by `intent` field |
| Skill usage | Flatten all `skill_used` arrays across entries, count and rank each distinct skill name |
| Direct prompts | Count entries where `skill_used` is empty (null, `[]`, or absent) |
| Avg turn count | Mean of `turn_count` across all entries |
| High-iteration rate | % of entries where `turn_count` >= 4 |
| Mentor trigger rate | % where `coaching_triggered` = true |
| Intervention breakdown | Count by `intervention_type` (nudge/correction/challenge/reinforcement) |
| Friction distribution | Count by `friction_type` field (non-null entries only) |
| Session outcomes | Count by `session_outcome` field |
| Skill suggestions | Count and rank each distinct `skill_suggested` value (non-null) |
| Skill adoption | For each `skill_suggested` value, count how many times that same skill appears anywhere in a `skill_used` array in subsequent entries |
| Skill gaps | Collect all `skill_gap_description` values (non-null) for pattern analysis |

---

## Step 3 — Identify patterns

Look for:

1. **Vagueness pattern** — high frequency of `vague` intent → prompt structure habit
2. **High iteration pattern** — avg turn_count > 3 → prompts not landing on first try
3. **Improving trend** — if sortable by timestamp: is avg turn_count decreasing over time?
4. **Mentor frequency** — if coaching triggered on >40% of prompts, threshold may be too sensitive
5. **Intervention type balance** — heavy correction/challenge with no reinforcement may indicate overly strict thresholds, or consistent issues
6. **User model alignment** — do the weaknesses in the model match the patterns in the log? Flag any discrepancy.
7. **Skill suggestion pattern** — if the same skill is suggested 3+ times, the user may not know about it or may be resisting it. Note the adoption rate.
8. **Skill gap clustering** — group `skill_gap_description` entries by theme. If 2+ entries describe similar unmet needs, this is a gap worth calling out.

---

## Step 4 — Produce the report

Format the output as:

```
## Mentor Recap
(Last N interactions · Cross-session)

### Summary
[2-3 sentence overview of overall posture and trajectory]

### User Model
**Strengths:** [list, or "None recorded yet"]
**Weaknesses:** [list, or "None recorded yet"]
**Current focus:** [value or "Not set"]
**Recent progress:** [value or "None noted"]

[If user model is empty: "The user model is still building — it populates after every 5 interactions."]

### Patterns Detected
[For each pattern found:]
Pattern: [name]
  Frequency: [X% of interactions / N occurrences]
  Impact: [what this costs — extra turns, rework, wrong output]
  Suggestion: [specific, actionable change]

[If no patterns: "No strong patterns detected — usage looks balanced."]

### Friction Patterns
[Group interventions by friction_type. For each type that appeared 2+ times:]
- **[friction_type]**: [N] occurrences
  Impact: [what this costs — extra turns, rework, wrong output]
  Trend: [increasing/decreasing/stable over the window]

[If session_outcome data available:]
Session outcomes: [X] achieved · [Y] not_achieved · [Z] unknown

### Skill Usage
[Ranked list of skills used and how often, or "No skill invocations recorded" if none]
[Direct prompts: N]

### Skill Awareness
**Suggestions made:**
[For each skill_suggested value that appeared 2+ times:]
- **/[skill-name]**: suggested [N] times, adopted [M] times
  [If adoption is low: "You may not be aware of this skill or may not find it useful — it triggers when [trigger description]"]

[If no suggestions were made: "The mentor didn't suggest any specific skills. This may mean your skill usage is already good, or the skill catalog wasn't loaded (check /mentor status)."]

**Unused installed skills:**
[Skills that never appeared in skill_used or skill_suggested — these may not be relevant to your work, or you may be missing opportunities]

### Skill Gaps
[If skill_gap_description entries exist:]
[Group by theme and rank by frequency:]

You hit [N] sessions involving [theme] with no skill coverage.

A "[suggested-name]" skill could help here — triggered when [trigger condition]. It would enforce: [workflow sketch from the gap descriptions].

[For top 1-2 gap themes only. If only 1 occurrence of a gap, don't surface it — wait for a pattern.]

[If no gap descriptions: "No skill gaps identified yet. As you use Claude more, the mentor will flag areas where a custom skill could help."]

### Efficiency
Avg turns per task: [N]
High-iteration tasks (4+ turns): [X%]
[If trend data available: "Turn count is trending down/up over last N sessions"]

### Mentor Activity
Triggered: [X% of prompts]
Breakdown: nudge [N] · correction [N] · challenge [N] · reinforcement [N]
Top trigger: [most common intervention_type or friction_type]

[If reinforcement count is 0 and total interventions > 5: "No reinforcement fired yet — the mentor may be missing opportunities to acknowledge improvement."]

### Top Recommendations
1. [Most impactful change, grounded in the data above]
2. [Second most impactful]
3. [Third]
```

Keep the report concise. Focus on actionable patterns, not exhaustive statistics.

---

## Step 5 — Suggest next action

End with one of:
- If Mentor trigger rate is high: "Run `/mentor chill` to reduce intervention frequency."
- If turn count is high and vagueness is the top friction type: "Your prompts may benefit from more upfront structure — goal, constraints, output format."
- If user model weaknesses are stale (last intervention_history entry is old): "The user model may be stale. Keep using Claude normally and it will update every 5 interactions."
- If skill gaps were identified: "You have recurring [theme] work with no skill coverage. Consider building a custom skill — the gap analysis above has a starting point."
- If no strong patterns: "Things look solid. Keep an eye on turn count as a leading indicator."
