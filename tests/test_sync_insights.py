#!/usr/bin/env python3
"""Tests for sync-insights.py — insights facet aggregation."""

import json
import os
import sys
import tempfile

import pytest

# Add hooks/lib to path so we can import the module
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "hooks", "lib"))
from sync_insights import aggregate_facets, map_friction, build_weights


@pytest.fixture
def facets_dir():
    """Create a temp directory with sample facet files."""
    with tempfile.TemporaryDirectory() as d:
        facets = [
            {
                "outcome": "not_achieved",
                "friction_counts": {"wrong_approach": 2, "misunderstood_request": 1},
                "friction_detail": "User went down wrong path.",
                "session_id": "aaa",
            },
            {
                "outcome": "fully_achieved",
                "friction_counts": {},
                "friction_detail": "",
                "session_id": "bbb",
            },
            {
                "outcome": "not_achieved",
                "friction_counts": {"misunderstood_request": 1, "buggy_code": 1},
                "friction_detail": "Vague request led to wrong output.",
                "session_id": "ccc",
            },
            {
                "outcome": "partially_achieved",
                "friction_counts": {"incomplete_changes": 1},
                "friction_detail": "Scope grew beyond original ask.",
                "session_id": "ddd",
            },
        ]
        for i, f in enumerate(facets):
            with open(os.path.join(d, f"facet-{i}.json"), "w") as fh:
                json.dump(f, fh)
        yield d


def test_aggregate_facets(facets_dir):
    result = aggregate_facets(facets_dir)
    assert result["wrong_approach"] == 2
    assert result["misunderstood_request"] == 2
    assert result["buggy_code"] == 1
    assert result["incomplete_changes"] == 1


def test_aggregate_facets_empty_dir():
    with tempfile.TemporaryDirectory() as d:
        result = aggregate_facets(d)
        assert result == {}


def test_aggregate_facets_missing_dir():
    result = aggregate_facets("/nonexistent/path")
    assert result == {}


def test_map_friction():
    assert map_friction("misunderstood_request") == "vague_request"
    assert map_friction("wrong_approach") == "wrong_approach"
    assert map_friction("buggy_code") == "wrong_approach"
    assert map_friction("incomplete_changes") == "scope_drift"
    assert map_friction("user_rejected_action") == "user_rejected_action"
    assert map_friction("hallucinated_content") == "hallucinated_content"


def test_build_weights(facets_dir):
    counts = aggregate_facets(facets_dir)
    weights = build_weights(counts)
    assert len(weights) <= 3
    # Top pattern should be wrong_approach or misunderstood_request (both have count 2)
    patterns = [w["pattern"] for w in weights]
    assert "wrong_approach" in patterns
    assert "vague_request" in patterns
    # Weight should be "high" for top items
    for w in weights:
        assert w["weight"] in ("high", "medium")
        assert isinstance(w["count"], int)


def test_build_weights_empty():
    weights = build_weights({})
    assert weights == []
