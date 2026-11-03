#!/usr/bin/env python3
"""
Session snapshot test (#1): the app keeps `session.json` in sync with its open tabs.

Covers the save half of restore. The snapshot is written every 2 s (only when it
changed), so a crash loses at most a couple of seconds. Restoring needs an app
relaunch and is checked by hand:

    kill -9 the app, relaunch, and the same tabs, splits, titles, directories and
    selected tab come back.

Usage:
    python3 tests/test_session_snapshot.py

Requirements:
    - cter must be running with the socket controller enabled
    - CTER_BUNDLE_ID / CTER_TAG must match the running app (see tests/cter.py)
"""

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cter import cter, cterError

# Autosave interval is 2 s; allow for timer tolerance.
SAVE_TIMEOUT_S = 6.0


def snapshot_path() -> Path:
    return (
        Path.home() / "Library" / "Application Support" / cter.default_bundle_id() / "session.json"
    )


def read_snapshot() -> dict:
    with open(snapshot_path()) as f:
        return json.load(f)


def wait_for_snapshot(predicate) -> dict:
    deadline = time.time() + SAVE_TIMEOUT_S
    last = None
    while time.time() < deadline:
        try:
            last = read_snapshot()
            if predicate(last):
                return last
        except (OSError, json.JSONDecodeError):
            pass
        time.sleep(0.25)
    raise AssertionError(f"snapshot at {snapshot_path()} never matched; last={last}")


def count_panes(node: dict) -> int:
    # Synthesized Codable for `NodeSnapshot` encodes `.split(x)` as {"split": {"_0": x}}.
    if "split" in node:
        split = node["split"]["_0"]
        return count_panes(split["left"]) + count_panes(split["right"])
    return 1


def test_snapshot_tracks_tabs(client: cter) -> None:
    before = len(client.list_tabs())
    tab_id = client.new_tab()
    try:
        snapshot = wait_for_snapshot(lambda s: len(s.get("tabs", [])) == before + 1)
        if snapshot.get("version") != 1:
            raise AssertionError(f"unexpected snapshot version {snapshot.get('version')}")
        selected = snapshot.get("selectedTabIndex")
        tabs = client.list_tabs()
        expected = next(index for index, tid, _, _ in tabs if tid == tab_id)
        if selected != expected:
            raise AssertionError(f"selectedTabIndex={selected}, expected {expected}")
    finally:
        client.close_tab(tab_id)
    wait_for_snapshot(lambda s: len(s.get("tabs", [])) == before)


def test_snapshot_tracks_splits(client: cter) -> None:
    tab_id = client.new_tab()
    try:
        client.new_split("right")
        tabs = client.list_tabs()
        index = next(index for index, tid, _, _ in tabs if tid == tab_id)

        def has_split(s: dict) -> bool:
            snapshot_tabs = s.get("tabs", [])
            return index < len(snapshot_tabs) and count_panes(snapshot_tabs[index]["layout"]) == 2

        wait_for_snapshot(has_split)
    finally:
        client.close_tab(tab_id)


def run_tests() -> int:
    tests = [test_snapshot_tracks_tabs, test_snapshot_tracks_splits]
    failures = 0
    with cter() as client:
        for test in tests:
            try:
                test(client)
                print(f"  {test.__name__}: PASS")
            except (AssertionError, cterError, StopIteration) as e:
                failures += 1
                print(f"  {test.__name__}: FAIL - {e!r}")
    print(f"\nPassed: {len(tests) - failures}/{len(tests)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run_tests())
