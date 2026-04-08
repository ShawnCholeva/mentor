# Mentor Phase 1.5 — Insights-Informed Coaching

## What This Is

A feature request for the mentor plugin. This doc describes six features that make mentor smarter by optionally integrating with `/insights` (Claude Code's built-in usage analysis) and improving the coaching system's own data and intervention quality.

This is **Phase 1.5** — it builds on Phase 1's accurate data pipeline (v3.2 spec) but does not require Phase 2's growth engine (milestones, before/after tracking). Phase 1 must ship first because these features depend on accurate interaction logging.

## How This Doc Should Be Used

This doc is designed to be handed to a Claude agent working in the mentor plugin repo. It describes problems and requirements only — no implementation prescriptions. The agent should read the existing codebase, the v3.2 spec, and decide how to build these features into the existing system.

## Discovery Context

These features were identified by comparing two systems that analyze the same user's Claude Code behavior:

- **`/mentor-recap`** — the mentor plugin's own behavioral analysis, built from `interactions.jsonl`. After 9 logged interactions, it showed: all corrections (zero reinforcement), no skill invocations recorded, 22 avg turns per task, an empty user model.

- **`/insights`** — Claude Code's built-in retrospective analysis across 160 sessions. It identified three distinct friction patterns (vague requests, wrong debugging approaches, premature exits), knew the user's strengths (batch triage, clear-spec sessions), and surfaced actionable suggestions with specific prompt scaffolds.

The gap is clear: insights has deep knowledge about the user that mentor doesn't leverage, and mentor's own data capture and intervention logic are too coarse to provide the same quality of coaching. These six features close that gap.

## Integration Model

**Optional integration.** Mentor must work fully standalone — insights is not a dependency. When insights data is available (e.g., at `~/.claude/usage-data/facets/` or `~/.claude/usage-data/report.html`), mentor reads it to improve its coaching. When it's not available, mentor falls back to its own interaction log and user model as it does today.

This is a one-directional read: mentor consumes insights data, never writes to it.

---

## Feature 1: Insights-Informed User Model Seeding

### Problem

The user model starts empty and takes 30+ interactions to populate meaningfully. The user model updater (`update-user-model.py`) requires a critical mass of interaction data before it can identify strengths, weaknesses, and focus areas. Meanwhile, `/insights` already has a rich profile of the user's strengths, weaknesses, friction patterns, and interaction style — derived from analyzing full session transcripts across weeks of usage.

After 55 interactions in the pre-v3.2 system, the user model had 0 strengths, 1 weakness, and 1 intervention history entry. With insights data available, that cold-start period could be eliminated entirely.

### Requirement

When insights data is available, mentor should be able to seed or enrich the user model from it. Specifically:

- Map insights' friction categories to user model `weaknesses`
- Map insights' "what works" patterns to user model `strengths`
- Use insights' interaction style analysis to set `current_focus`
- Seeding should happen on first run when the user model is empty, and periodically refresh when insights data is newer than the last sync

When insights data isn't available, mentor continues building the model from its own interaction log as it does today.

### Success Criteria

- A new user with insights data available has a populated user model within their first session instead of after 30+ interactions
- Insights-seeded data is clearly marked or separable from mentor-observed data so the model updater doesn't double-count
- The model continues evolving from mentor's own observations after seeding — insights provides a starting point, not a ceiling

---

## Feature 2: Richer Interaction Logging

### Problem

Current log entries in `interactions.jsonl` capture bare-bones fields: `intent`, `turn_count`, `prompt_summary`, `coaching_triggered`, `intervention_type`. This limits both `/mentor-recap`'s analysis and the user model updater's ability to reason about patterns.

`/insights` gets its depth from full session transcript analysis — it can identify friction *categories* (vague request vs. wrong debugging approach vs. premature exit), detect skill availability vs. usage, and estimate session outcomes. Mentor's log captures none of this signal.

### Requirement

Expand log entries to include:

- **Friction type** — classify what's wrong when coaching fires: `vague_request`, `wrong_approach`, `missing_diagnostics`, `scope_drift`, `premature_exit`, or `none`. This gives mentor-recap the same friction categorization that insights provides.
- **Skill availability** — whether a relevant skill was available but not invoked. The evaluator already sees the prompt — it can check if the prompt describes work that matches a known skill pattern (debugging, testing, payments, etc.) without the user invoking it.
- **Session outcome estimation** — at the `Stop` hook, estimate whether the session achieved its goal based on signals available in the transcript (e.g., commits made, tests run, errors at end vs. start). This can be coarse (achieved / partial / not_achieved / unknown).

The schema should be additive — existing log entries without these fields remain valid. All consumers should handle missing fields gracefully.

### Success Criteria

- `/mentor-recap` can identify the same top friction patterns that `/insights` found, using only its own log data
- The user model updater has enough signal to populate strengths and weaknesses within 15-20 interactions instead of 30+
- Existing log entries and consumers are not broken by the schema expansion

---

## Feature 3: Pattern-Specific Interventions

### Problem

Mentor currently fires generic corrections regardless of what's wrong. All 5 of the first 9 interventions were typed as `correction` but the coaching messages don't differentiate between fundamentally different problems.

`/insights` identified three distinct friction patterns in this user's sessions:

1. **Vague requests** — "fix this" or "test this" with no context, leading to 90%+ not_achieved rate
2. **Wrong debugging approaches** — Claude chasing wrong hypotheses because it wasn't pointed to docs or error output
3. **Premature exits** — leaving before fixes are verified, requiring follow-up sessions

Each of these needs a different coaching response. Telling someone with a vague request to "be more specific" is different from telling someone debugging without error output to "share the error message and relevant file paths."

### Requirement

The evaluator should classify the type of issue it detects and tailor its intervention message accordingly:

- **Vague request** — coaching should ask for: what file, what's the expected vs actual behavior, and any error output
- **Missing diagnostics** — coaching should prompt for: error messages, relevant file paths, or a pointer to docs before Claude starts exploring
- **Scope drift** — coaching should suggest: scoping down, resetting, or breaking the work into smaller pieces
- **Missing skill invocation** — coaching should suggest: the specific skill that matches the user's described work

The existing intervention types (nudge, correction, challenge, reinforcement) remain unchanged — they describe the *intensity*. This adds a *reason category* that shapes the message content. The evaluator's system prompt should include these categories and example responses.

### Success Criteria

- Coaching messages are specific to the friction pattern — a user can tell from the message what to fix, not just that something is wrong
- The reason category is logged in `interactions.jsonl` (ties into Feature 2's friction type)
- The evaluator doesn't over-classify — when the issue doesn't fit a known pattern, it falls back to the existing generic evaluation

---

## Feature 4: Session Pre-Flight Hook

### Problem

A significant portion of sessions start with zero context — "fix this", "test this" — leading to early exits and wasted time. `/insights` found this was the user's single biggest source of failed sessions.

Mentor currently evaluates prompts reactively. It fires *after* the user has already submitted a vague prompt, and by then the damage is done — the user gets a coaching nudge and a vague response from Claude in the same breath. A better approach is to ensure the user has context *before* they need to describe the problem.

### Requirement

An optional pre-flight mechanism that gathers project state at session start and presents it to the user before their first prompt. This could include:

- `git status` and recent diff stats
- Recent commit history
- Failing tests (if a test command is configured)
- TypeScript compiler errors (if applicable)
- Open TODOs/FIXMEs from recent commits

This should be:

- **Toggleable** — not every session needs a diagnostic dump (e.g., `/mentor preflight on|off`)
- **Configurable** — users should be able to specify which checks run (test command, compiler, etc.)
- **Non-blocking** — if a check hangs or fails, skip it and show what's available

The goal is to turn "fix this" into "fix the TypeScript error in `src/lib/auth.ts` that appeared after commit abc123" — the user points at a specific item from the pre-flight report instead of describing the problem from memory.

### Success Criteria

- Users who enable pre-flight start sessions with enough project context that vague prompts become unnecessary
- Pre-flight results are injected as context the user can reference, not as a coaching intervention
- The feature is off by default and doesn't add latency to sessions that don't need it

---

## Feature 5: Closed-Loop Feedback Cycle

### Problem

Mentor and insights are two isolated systems analyzing the same user's behavior. Insights identifies macro patterns ("vague requests are your #1 friction source at 90%+ failure rate") but mentor doesn't know this. Mentor fires interventions with equal weight on all issues, without knowing which patterns are actually costing the user the most time.

The result: mentor might spend coaching effort on a minor issue while the user's biggest problem goes under-weighted.

### Requirement

After `/insights` runs and generates its report, mentor can import the top friction patterns and adjust its evaluation priorities:

- Read insights' friction analysis to identify the user's top 3 friction patterns
- Weight the evaluator's attention toward those patterns — if vague requests are the #1 issue, mentor should be more sensitive to vague prompts and less aggressive about lower-impact issues
- This is a periodic sync that happens when insights data is refreshed (roughly monthly or on-demand), not a real-time connection
- The sync should update a mentor-internal config or weighting file, not modify the coaching philosophy (which is user-owned)

### Success Criteria

- Mentor's intervention priorities align with the user's actual top friction patterns as identified by insights, without manual threshold tuning
- The weighting is transparent — `/mentor status` should show what patterns are currently prioritized and why
- When insights data isn't available, all patterns are weighted equally (current behavior)

---

## Feature 6: Reinforcement, Not Just Correction

### Problem

All 5 of the first 9 recorded interventions were corrections. Zero nudges, zero challenges, zero reinforcement. The evaluator's rules already say reinforcement should fire roughly 1 in 10 interventions, but it never has.

Without positive feedback, the mentor feels like a nag rather than a coach. Users learn to ignore it — or worse, turn it off. `/insights` showed that the user's best sessions happen when they bring clear scope and use skills. Those are exactly the moments reinforcement should fire, and it's not.

### Requirement

Reinforcement should fire when the user demonstrates:

- **Growth in a weak area** — e.g., the user previously struggled with vague prompts but now provides specific file paths and error output. This requires the evaluator to have access to the user model's `weaknesses` and `intervention_history`.
- **Philosophy alignment** — the prompt exemplifies a principle from the coaching philosophy (e.g., "design before build", "show your work").
- **Skill usage** — the user invokes a relevant skill before starting work, especially if this is a new behavior.

The evaluator's system prompt should explicitly include the user's recent weaknesses so it can recognize when someone is improving. Reinforcement messages should reference the specific improvement, not offer generic praise ("Good prompt!" is useless — "You included the error output and file path this time — that's exactly what was missing before" is useful).

### Success Criteria

- Reinforcement fires at a natural rate (roughly 1 in 10 interventions) across a 50+ interaction window
- Reinforcement messages reference specific improvements or philosophy principles
- The user model's `recent_progress` field reflects patterns detected through reinforcement, not just absence of correction

---

## Prioritization Guidance

These features are listed in a suggested priority order based on impact and dependency:

1. **Richer Interaction Logging** (Feature 2) — foundation for everything else. Better data makes all other features more effective.
2. **Pattern-Specific Interventions** (Feature 3) — highest direct user impact. Makes coaching immediately more useful.
3. **Reinforcement** (Feature 6) — prevents user attrition from the coaching system. Without this, users turn mentor off.
4. **Insights-Informed User Model Seeding** (Feature 1) — eliminates cold-start. High impact for new users or users with existing insights data.
5. **Closed-Loop Feedback Cycle** (Feature 5) — makes mentor self-improving over time. Highest long-term value.
6. **Session Pre-Flight** (Feature 4) — most ambitious, most self-contained. Can be built independently of the others.

## Constraints

- Phase 1 (v3.2 data pipeline fix) must ship before any of these features. They depend on accurate interaction logging.
- Insights integration is always optional — mentor must degrade gracefully when insights data is absent.
- No changes to the coaching philosophy file format — that's user-owned.
- The user model schema can be extended but existing fields must remain backward-compatible.
- Hook timeout budgets are tight (30s for UserPromptSubmit, async for Stop). Features must respect these limits.
