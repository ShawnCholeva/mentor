#!/usr/bin/env python3
"""
update-user-model.py — Updates the persistent user model for the mentor plugin.

Reads a JSON payload from stdin:
  {
    "user_model": {...},
    "recent_interactions": [...],
    "session_coaching": {"type": "...", "message": "..."}
  }

Calls Claude haiku to produce an updated user model.
Writes the result atomically to ~/.claude/coaching/user-model.json.

Always exits 0. On any error, leaves the existing file unchanged.
"""

import json
import os
import sys
import tempfile

COACHING_DIR = os.path.expanduser("~/.claude/coaching")
USER_MODEL_FILE = os.path.join(COACHING_DIR, "user-model.json")

EMPTY_MODEL = {
    "strengths": [],
    "weaknesses": [],
    "current_focus": "",
    "recent_progress": "",
    "intervention_history": []
}


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw)
    except Exception:
        return

    user_model = payload.get("user_model", EMPTY_MODEL)
    recent_interactions = payload.get("recent_interactions", [])
    session_coaching = payload.get("session_coaching", {})

    if not recent_interactions:
        return

    try:
        import anthropic
    except ImportError:
        return

    system_prompt = """You maintain a user profile for a Claude Code coaching system. Given the recent interaction history and current profile, produce an updated profile.

Rules:
1. strengths: patterns the user consistently does well. Add only when you see 3+ clear instances. Remove if contradicted by recent behavior.
2. weaknesses: patterns the user consistently struggles with. Same 3+ instance threshold. Be specific (e.g., "skips design phase on complex tasks" not "vague prompts").
3. current_focus: the single most impactful area for improvement right now. Update when the previous focus shows consistent improvement or a more pressing issue has emerged.
4. recent_progress: what has genuinely improved in the last 10 interactions. Be specific. Empty string if no clear progress.
5. intervention_history: append a brief summary of the latest coaching (type + topic, max 10 words). Keep only the last 20 entries total.
6. Be conservative. Small, incremental updates. Do not rewrite the whole profile based on a few interactions.
7. If the profile is empty, only populate based on clear evidence. Do not guess or extrapolate.
8. Do not add placeholder text like "none" or "n/a" — use empty string or empty array instead.

Respond with ONLY the updated JSON object. No markdown fences, no explanation, no trailing text."""

    interactions_summary = json.dumps(recent_interactions, indent=2)
    coaching_summary = json.dumps(session_coaching) if session_coaching else "none"
    current_model_str = json.dumps(user_model, indent=2)

    user_message = f"""Current profile:
{current_model_str}

Recent interactions (last 20):
{interactions_summary}

Latest session coaching:
{coaching_summary}

Produce the updated profile JSON."""

    try:
        client = anthropic.Anthropic(timeout=10.0)
        response = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=600,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}]
        )
        text = response.content[0].text.strip()

        # Strip markdown fences if present
        if text.startswith("```"):
            lines = text.split("\n")
            inner = lines[1:]
            if inner and inner[-1].strip() == "```":
                inner = inner[:-1]
            text = "\n".join(inner)

        updated = json.loads(text)

        # Validate it has the expected keys
        for key in ("strengths", "weaknesses", "current_focus", "recent_progress", "intervention_history"):
            if key not in updated:
                updated[key] = user_model.get(key, EMPTY_MODEL[key])

        # Hard cap on intervention_history
        if isinstance(updated.get("intervention_history"), list):
            updated["intervention_history"] = updated["intervention_history"][-20:]

        # Atomic write
        os.makedirs(COACHING_DIR, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(dir=COACHING_DIR, suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(updated, f, indent=2)
                f.write("\n")
            os.replace(tmp_path, USER_MODEL_FILE)
        except Exception:
            try:
                os.unlink(tmp_path)
            except Exception:
                pass

    except Exception:
        pass


if __name__ == "__main__":
    main()
