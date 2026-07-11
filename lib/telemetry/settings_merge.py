#!/usr/bin/env python3
"""khub telemetry settings.json merge helper.

All JSON manipulation for `khub track` lives here so the khub CLI (bash) never
parses JSON itself. This is the highest-consequence surface in the telemetry
feature — a bad merge corrupts the engineer's Claude Code config — so every write
is:

  * NON-DESTRUCTIVE   only khub's own entries are added/removed; co-existing hooks
                      from ClaudeKit or anything else are never touched. khub's
                      entries are recognised by the stable hook-path token in their
                      command (see HOOK_TOKEN below), never by list position.
  * IDEMPOTENT        N enables leave exactly one khub block per event.
  * ATOMIC + MODE-SAFE  write to a temp file in the same dir, preserve the
                      original's permission bits (no 0600->0644 widening), fsync,
                      then os.replace(); a timestamped 0600 backup is kept first.
  * FLOCK + RACE-GUARDED  an exclusive lock serialises concurrent `khub track`
                      runs; the file's (mtime,size) is re-checked immediately
                      before the rename so a write by another process (an IDE
                      editing settings.json live) aborts instead of clobbering.
  * FAIL-CLOSED       malformed JSON or an unwritable target aborts with a clear
                      message and NO mutation.

Subcommands (the khub CLI is the only caller):

  enable  <settings_path> --command CMD
  disable <settings_path>
  status  <settings_path> [--command CMD]      # prints start=/end=/drift= lines

Exit codes: 0 ok · 2 usage · 3 malformed/uncooperative JSON · 4 not writable ·
5 changed under us (caller may retry once).
"""

import argparse
import fcntl
import glob
import json
import os
import stat
import sys
import tempfile
import time

# khub identifies its OWN hook entries by the stable path token in the registered
# command — NOT by an extra key in the entry. The Claude Code settings schema marks
# the hook-matcher object ``additionalProperties: false`` (only ``matcher``/``hooks``
# are allowed), so an in-band marker key would be schema-invalid: editor validators
# flag it, and a settings re-serialization by the config UI could silently strip it,
# breaking identity (duplicate-on-re-enable, orphan-on-disable). The command khub
# writes always runs ``<abs-python3> <XDG_DATA>/khub-telemetry/capture_hook.py`` — that
# path segment is khub's exclusive namespace, so matching it is both schema-clean and,
# for a path under khub's own data dir, not realistically forgeable or collision-prone.
HOOK_TOKEN = "khub-telemetry/capture_hook.py"
EVENTS = ("SessionStart", "SessionEnd")

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_MALFORMED = 3
EXIT_NOTWRITABLE = 4
EXIT_RACE = 5


class _RaceError(Exception):
    """The target changed between our read and the rename — the caller retries."""


# ---- load / identity --------------------------------------------------------
def load_settings(path):
    """Return (obj, existed). An absent or empty file is an empty object.

    Raises ValueError on malformed JSON so the caller can fail closed.
    """
    if not os.path.exists(path):
        return {}, False
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if text.strip() == "":
        return {}, True
    return json.loads(text), True  # JSONDecodeError is a ValueError subclass


def _entry_commands(entry):
    if not isinstance(entry, dict):
        return []
    hooks = entry.get("hooks")
    if not isinstance(hooks, list):
        return []
    return [h.get("command", "") for h in hooks if isinstance(h, dict)]


def is_khub_entry(entry):
    """khub's own entry: one of its hook commands references khub's hook path."""
    return any(HOOK_TOKEN in cmd for cmd in _entry_commands(entry))


def make_entry(command):
    # Schema-clean: exactly the {matcher?, hooks} the hookMatcher object permits — no
    # extra keys. No matcher => broadest firing intent (whether a matcher-less
    # SessionStart fires for every source was verified on a live session).
    # Identity is carried by the command path (HOOK_TOKEN), not a marker key.
    return {"hooks": [{"type": "command", "command": command}]}


def _sig(path):
    """A cheap change-signature (mtime_ns, size) for the race guard, or None."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size)


# ---- mutation primitives ----------------------------------------------------
def strip_khub(cfg):
    """Remove every khub-marked entry from every event array. Non-khub entries
    (and now-empty arrays that we emptied) are left exactly as they were."""
    hooks = cfg.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks.keys()):
        arr = hooks[event]
        if isinstance(arr, list):
            arr[:] = [e for e in arr if not is_khub_entry(e)]


def add_khub(cfg, command):
    """Add khub's block to each telemetry event, replacing any prior khub block
    (idempotent). Raises ValueError if the existing shape is hostile."""
    hooks = cfg.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("settings.json 'hooks' is not an object")
    for event in EVENTS:
        arr = hooks.setdefault(event, [])
        if not isinstance(arr, list):
            raise ValueError("settings.json 'hooks.%s' is not an array" % event)
        arr[:] = [e for e in arr if not is_khub_entry(e)]
        arr.append(make_entry(command))


def backup(path):
    """Copy an existing, non-empty settings.json to a 0600 timestamped backup,
    verify it landed, then prune to the last two."""
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return
    bak = "%s.khub-bak-%d" % (path, int(time.time()))
    fd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as dst, open(path, "rb") as src:
        data = src.read()
        dst.write(data)
    if data and os.path.getsize(bak) == 0:
        raise IOError("backup verification failed: %s" % bak)
    prune_backups(path)


def prune_backups(path, keep=2):
    baks = sorted(glob.glob(glob.escape(path) + ".khub-bak-*"))
    for old in baks[:-keep]:
        try:
            os.unlink(old)
        except OSError:
            pass


def atomic_write(path, obj, existed, expected_sig=None):
    """Serialise obj to path via temp+rename, preserving the original mode.

    If expected_sig is given, the target's (mtime,size) is re-checked in the last
    instant before os.replace and a mismatch raises _RaceError — closing the
    check-to-rename window where another writer (e.g. an IDE editing settings.json
    live) would otherwise be clobbered with our stale copy."""
    directory = os.path.dirname(path) or "."
    if existed and os.path.exists(path):
        mode = stat.S_IMODE(os.stat(path).st_mode)
    else:
        mode = 0o600
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".khub-settings.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        if expected_sig is not None and _sig(path) != expected_sig:
            raise _RaceError()
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    dfd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(dfd)
    except OSError:
        pass
    finally:
        os.close(dfd)


def with_lock(path, func):
    """Run func() while holding an exclusive lock on a sibling lockfile, so two
    concurrent `khub track` runs cannot interleave a read-modify-write."""
    directory = os.path.dirname(path) or "."
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        pass
    lock = "%s.khub-lock" % path
    lf = open(lock, "w")
    try:
        fcntl.flock(lf, fcntl.LOCK_EX)
        return func()
    finally:
        try:
            fcntl.flock(lf, fcntl.LOCK_UN)
        finally:
            lf.close()
        # The lockfile is intentionally NOT unlinked: unlinking lets a later opener
        # create a fresh inode and lock THAT instead, so two processes would run
        # concurrently and mutual exclusion would silently break. It is a 0-byte
        # sibling; `khub track disable`/`purge` remove it.


# ---- subcommands ------------------------------------------------------------
def _writable_target(path, existed):
    directory = os.path.dirname(path) or "."
    if existed and not os.access(path, os.W_OK):
        sys.stderr.write("settings.json is not writable: %s\n" % path)
        return False
    if not os.path.isdir(directory):
        try:
            os.makedirs(directory, exist_ok=True)
        except OSError:
            sys.stderr.write("cannot create directory: %s\n" % directory)
            return False
    if not os.access(directory, os.W_OK):
        sys.stderr.write("directory is not writable: %s\n" % directory)
        return False
    return True


def cmd_enable(args):
    def op():
        try:
            obj, existed = load_settings(args.path)
        except ValueError:
            sys.stderr.write("settings.json is not valid JSON: %s\n" % args.path)
            return EXIT_MALFORMED
        if not isinstance(obj, dict):
            sys.stderr.write("settings.json top-level is not an object: %s\n" % args.path)
            return EXIT_MALFORMED
        if not _writable_target(args.path, existed):
            return EXIT_NOTWRITABLE
        pre = _sig(args.path) if existed else None
        try:
            add_khub(obj, args.command)
        except ValueError as exc:
            sys.stderr.write("%s\n" % exc)
            return EXIT_MALFORMED
        if existed and _sig(args.path) != pre:
            sys.stderr.write("settings.json changed during update — retry\n")
            return EXIT_RACE
        backup(args.path)
        try:
            atomic_write(args.path, obj, existed, expected_sig=pre)
        except _RaceError:
            sys.stderr.write("settings.json changed during update — retry\n")
            return EXIT_RACE
        return EXIT_OK

    return with_lock(args.path, op)


def cmd_disable(args):
    def op():
        if not os.path.exists(args.path):
            return EXIT_OK
        try:
            obj, existed = load_settings(args.path)
        except ValueError:
            sys.stderr.write("settings.json is not valid JSON: %s\n" % args.path)
            return EXIT_MALFORMED
        if not isinstance(obj, dict):
            return EXIT_OK
        if not _writable_target(args.path, existed):
            return EXIT_NOTWRITABLE
        pre = _sig(args.path)
        strip_khub(obj)
        if _sig(args.path) != pre:
            sys.stderr.write("settings.json changed during update — retry\n")
            return EXIT_RACE
        backup(args.path)
        try:
            atomic_write(args.path, obj, True, expected_sig=pre)
        except _RaceError:
            sys.stderr.write("settings.json changed during update — retry\n")
            return EXIT_RACE
        return EXIT_OK

    return with_lock(args.path, op)


def cmd_status(args):
    result = {"start": "missing", "end": "missing", "drift": "none"}
    if os.path.exists(args.path):
        try:
            obj, _ = load_settings(args.path)
        except ValueError:
            sys.stdout.write("start=missing\nend=missing\ndrift=malformed\n")
            return EXIT_OK
        if not isinstance(obj, dict):
            obj = {}
        hooks = obj.get("hooks")
        hooks = hooks if isinstance(hooks, dict) else {}
        drift = False
        for event, key in (("SessionStart", "start"), ("SessionEnd", "end")):
            arr = hooks.get(event, [])
            arr = arr if isinstance(arr, list) else []
            entries = [e for e in arr if is_khub_entry(e)]
            if entries:
                result[key] = "present"
                if args.command is not None:
                    commands = [
                        h.get("command")
                        for e in entries
                        for h in e.get("hooks", [])
                        if isinstance(h, dict)
                    ]
                    if args.command not in commands:
                        drift = True
            elif args.command is not None:
                # An expected event with no khub entry is drift the caller repairs.
                drift = True
        if drift:
            result["drift"] = "yes"
    sys.stdout.write(
        "start=%s\nend=%s\ndrift=%s\n" % (result["start"], result["end"], result["drift"])
    )
    return EXIT_OK


def main(argv=None):
    parser = argparse.ArgumentParser(prog="settings_merge.py", add_help=True)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_en = sub.add_parser("enable")
    p_en.add_argument("path")
    p_en.add_argument("--command", required=True)
    p_en.set_defaults(func=cmd_enable)

    p_dis = sub.add_parser("disable")
    p_dis.add_argument("path")
    p_dis.set_defaults(func=cmd_disable)

    p_st = sub.add_parser("status")
    p_st.add_argument("path")
    p_st.add_argument("--command", default=None)
    p_st.set_defaults(func=cmd_status)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
