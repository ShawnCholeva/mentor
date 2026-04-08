#!/usr/bin/env python3
"""
sync_insights.py — Aggregate insights facets into priority weights.

Reads all JSON files from ~/.claude/usage-data/facets/, aggregates friction
counts, ranks top 3, and writes ~/.claude/coaching/priority-weights.json.

No LLM call — pure aggregation.

Can be imported as a module (for testing) or run as a script.
"""

import glob
import json
import os
import sys
import time

FACETS_DIR = os.path.expanduser("~/.claude/usage-data/facets")
WEIGHTS_FILE = os.path.expanduser("~/.claude/coaching/priority-weights.json")

# Map insights friction categories to mentor friction categories
FRICTION_MAP = {
    "misunderstood_request": "vague_request",
    "wrong_approach": "wrong_approach",
    "buggy_code": "wrong_approach",
    "incomplete_changes": "scope_drift",
    # These don't map to mentor categories — kept as-is for informational value
}


def aggregate_facets(facets_dir: str) -> dict[str, int]:
    """Read all facet JSON files and aggregate friction_counts."""
    counts: dict[str, int] = {}
    try:
        files = glob.glob(os.path.join(facets_dir, "*.json"))
    except Exception:
        return counts

    for f in files:
        try:
            with open(f) as fh:
                data = json.load(fh)
            for key, val in data.get("friction_counts", {}).items():
                counts[key] = counts.get(key, 0) + val
        except Exception:
            continue

    return counts


def map_friction(insights_category: str) -> str:
    """Map an insights friction category to a mentor friction category."""
    return FRICTION_MAP.get(insights_category, insights_category)


def build_weights(friction_counts: dict[str, int]) -> list[dict]:
    """Build top-3 priority weights from aggregated friction counts."""
    if not friction_counts:
        return []

    # Map categories first, then aggregate to avoid duplicates
    # (e.g., wrong_approach + buggy_code both map to wrong_approach)
    mapped: dict[str, int] = {}
    for category, count in friction_counts.items():
        pattern = map_friction(category)
        mapped[pattern] = mapped.get(pattern, 0) + count

    # Sort by count descending, take top 3
    sorted_frictions = sorted(mapped.items(), key=lambda x: -x[1])[:3]

    max_count = sorted_frictions[0][1] if sorted_frictions else 0
    weights = []
    for pattern, count in sorted_frictions:
        weight = "high" if count >= max_count * 0.5 else "medium"
        weights.append({
            "pattern": pattern,
            "weight": weight,
            "count": count,
        })

    return weights


def main():
    facets_dir = sys.argv[1] if len(sys.argv) > 1 else FACETS_DIR
    output_file = sys.argv[2] if len(sys.argv) > 2 else WEIGHTS_FILE

    counts = aggregate_facets(facets_dir)
    if not counts:
        return

    weights = build_weights(counts)
    result = {
        "last_sync": int(time.time()),
        "top_friction": weights,
    }

    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    tmp_path = output_file + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            json.dump(result, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, output_file)
    except Exception:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass


if __name__ == "__main__":
    main()
