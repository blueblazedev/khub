#!/usr/bin/env python3
"""khub telemetry capture hook — PHASE 1 NO-OP STUB.

`khub track enable` registers this under SessionStart + SessionEnd in
~/.claude/settings.json. It exists only to prove the hook wire end-to-end: it
reads the hook's stdin JSON and — only when telemetry is enabled — appends a
one-line "fired" marker to the local state dir. Phase 2 replaces this body with
the real transcript capture + metrics.

FAIL-OPEN CONTRACT (do not weaken): a Stop/SessionEnd hook that exits non-zero
BLOCKS the session turn, and a missing interpreter yields exit 127. So this
script:
  * takes NO argparse (a usage error is a non-zero SystemExit) — it reads
    everything it needs from stdin;
  * wraps ALL work in try/except and ALWAYS exits 0, even on malformed stdin, an
    unreadable config, or any internal exception.
The command khub registers is additionally guarded with ``|| exit 0`` so even a
failed interpreter launch cannot fail the turn.
"""

import json
import os
import sys
import time


def _config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config"
    )
    return os.path.join(base, "khub", "telemetry.conf")


def _state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(base, "khub-telemetry")


def _enabled():
    """True only when the khub config file has ``enabled=1``. Any error (absent
    file, unreadable) reads as OFF — the hook must never assume it is on."""
    try:
        with open(_config_path(), encoding="utf-8") as fh:
            for line in fh:
                if line.strip() == "enabled=1":
                    return True
    except Exception:
        return False
    return False


def main():
    raw = sys.stdin.read()
    if not _enabled():
        return
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        payload = {}
    event = payload.get("hook_event_name", "?")
    session = payload.get("session_id", "?")
    state = _state_dir()
    os.makedirs(state, mode=0o700, exist_ok=True)
    with open(os.path.join(state, "last-fired"), "a", encoding="utf-8") as fh:
        fh.write("%s %s %d\n" % (event, session, int(time.time())))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
