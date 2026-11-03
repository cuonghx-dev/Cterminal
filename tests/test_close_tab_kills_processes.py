#!/usr/bin/env python3
"""
Regression test: closing a tab must end the processes running in it.

Closing a tab used to only remove it from the UI. The Ghostty surface (and its PTY)
was freed in `TerminalSurface.deinit`, which never ran because view handlers retained
the surface, so `login -> zsh -> <command>` kept running until the app quit.

Usage:
    python3 tests/test_close_tab_kills_processes.py

Requirements:
    - cter must be running with the socket controller enabled
"""

import os
import random
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cter import cter, cterError

# Ghostty waits up to 12 s for SIGHUP before escalating; `sleep` exits on SIGHUP at once.
EXIT_TIMEOUT_S = 15.0


def marker_running(marker: str) -> bool:
    return subprocess.run(["pgrep", "-f", marker], capture_output=True).returncode == 0


def wait_for(predicate, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.1)
    return predicate()


def start_marker(client: cter, surface_id: str) -> str:
    # A unique duration identifies the process in `pgrep -f`.
    marker = f"sleep {random.randint(700000, 799999)}"
    client.send_surface(surface_id, marker + "\n")
    if not wait_for(lambda: marker_running(marker), 5.0):
        raise cterError(f"'{marker}' never started in surface {surface_id}")
    return marker


def test_close_tab(client: cter) -> None:
    tab_id = client.new_tab()
    time.sleep(0.5)
    surface_id = client.list_surfaces(tab_id)[0][1]
    marker = start_marker(client, surface_id)

    client.close_tab(tab_id)

    if not wait_for(lambda: not marker_running(marker), EXIT_TIMEOUT_S):
        raise AssertionError(f"'{marker}' still running {EXIT_TIMEOUT_S}s after close_tab")


def test_close_tab_with_split(client: cter) -> None:
    tab_id = client.new_tab()
    time.sleep(0.5)
    client.new_split("right")
    time.sleep(0.5)
    surfaces = client.list_surfaces(tab_id)
    if len(surfaces) < 2:
        raise cterError(f"expected 2 surfaces after split, got {len(surfaces)}")
    markers = [start_marker(client, s[1]) for s in surfaces[:2]]

    client.close_tab(tab_id)

    for marker in markers:
        if not wait_for(lambda: not marker_running(marker), EXIT_TIMEOUT_S):
            raise AssertionError(f"'{marker}' still running {EXIT_TIMEOUT_S}s after close_tab")


def run_tests() -> int:
    tests = [test_close_tab, test_close_tab_with_split]
    failures = 0
    with cter() as client:
        for test in tests:
            try:
                test(client)
                print(f"  {test.__name__}: PASS")
            except (AssertionError, cterError) as e:
                failures += 1
                print(f"  {test.__name__}: FAIL - {e}")
    print(f"\nPassed: {len(tests) - failures}/{len(tests)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run_tests())
