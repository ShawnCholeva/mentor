#!/usr/bin/env python3
"""
evaluate-prompt.py — Claude API-powered prompt evaluator for mentor plugin.

Reads a JSON payload from stdin:
  {"prompt": "...", "mode": "chill|elite", "philosophy": "...", "user_model": "..."}

Calls Claude haiku to evaluate the prompt quality.
Outputs a JSON judgment to stdout:
  {"intervene": false}
  {"intervene": true, "type": "nudge|correction|challenge|reinforcement", "message": "..."}

Always exits 0. On any error, outputs {"intervene": false}.
"""

import json
import sys

FALLBACK = json.dumps({"intervene": False})

def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw)
    except Exception:
        print(FALLBACK)
        return

    prompt = payload.get("prompt", "").strip()
    mode = payload.get("mode", "chill")
    philosophy = payload.get("philosophy", "").strip()
    user_model_raw = payload.get("user_model", "{}")

    if not prompt:
        print(FALLBACK)
        return

    try:
        import anthropic
    except ImportError:
        print(FALLBACK)
        return

    # Parse user model for embedding
    try:
        user_model = json.loads(user_model_raw) if isinstance(user_model_raw, str) else user_model_raw
        has_model = bool(
            user_model.get("strengths") or
            user_model.get("weaknesses") or
            user_model.get("current_focus")
        )
    except Exception:
        user_model = {}
        has_model = False

    if has_model:
        model_section = f"""## User Profile
Strengths: {json.dumps(user_model.get("strengths", []))}
Weaknesses: {json.dumps(user_model.get("weaknesses", []))}
Current focus: {user_model.get("current_focus", "none")}
Recent progress: {user_model.get("recent_progress", "none")}
"""
    else:
        model_section = "## User Profile\nNo profile yet — this is a new user. Be conservative with interventions."

    system_prompt = f"""You are a coaching evaluator for a Claude Code operator. Your job is to decide whether to intervene on a user's prompt before it reaches Claude.

## Philosophy
{philosophy if philosophy else "Clarity upfront is better than iteration later. Think in systems, not tasks."}

{model_section}
## Intervention Types
- nudge: Light suggestion. Small improvement opportunity. Use when the prompt is okay but could be better.
- correction: Clear mistake worth addressing. Use when the prompt has a specific flaw that will lead to a worse outcome.
- challenge: Strong pushback. Use when the user's thinking is flawed or they are approaching the problem wrong.
- reinforcement: Positive feedback. Use when the prompt demonstrates growth in an area the user previously struggled with, or exemplifies a philosophy principle well.

## Rules
1. Default to NOT intervening. Most prompts are fine. Only intervene when you have high confidence.
2. Never intervene on skill invocations (prompts starting with /).
3. Never intervene on short affirmative responses (yes, no, ok, proceed, sure, etc.).
4. Reinforcement should fire roughly 1 in 10 interventions — use it to build trust and reward real improvement.
5. Keep messages under 30 words. Be direct, not preachy. Do not moralize.
6. If the user profile has a current_focus, weight your evaluation toward that area.
7. Consider the user's strengths — do not coach on things they already do well.
8. Mode is "{mode}". In "chill" mode, only intervene on high-confidence issues (vague prompts, missing diagnostics). In "elite" mode, also intervene on subtler issues (missing output format, scope underestimation).
9. When you challenge, explain WHY the thinking is flawed — not just what to fix.
10. Prefer one precise observation over multiple generic suggestions.

Respond with ONLY a JSON object, no markdown, no explanation:
{{"intervene": false}}
or
{{"intervene": true, "type": "nudge|correction|challenge|reinforcement", "message": "your coaching message here"}}"""

    user_message = f"""Evaluate this prompt:
---
{prompt[:500]}
---"""

    try:
        model = "claude-sonnet-4-6" if mode == "elite" else "claude-haiku-4-5-20251001"
        client = anthropic.Anthropic(timeout=5.0)
        response = client.messages.create(
            model=model,
            max_tokens=150,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}]
        )
        text = response.content[0].text.strip()

        # Strip markdown fences if present
        if text.startswith("```"):
            lines = text.split("\n")
            text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])

        result = json.loads(text)

        # Validate structure
        if not isinstance(result.get("intervene"), bool):
            print(FALLBACK)
            return

        if result["intervene"]:
            if result.get("type") not in ("nudge", "correction", "challenge", "reinforcement"):
                print(FALLBACK)
                return
            if not result.get("message"):
                print(FALLBACK)
                return

        print(json.dumps(result))

    except Exception:
        print(FALLBACK)


if __name__ == "__main__":
    main()
