#!/usr/bin/env python3
"""khub telemetry capture hook — SessionEnd rollup.

`khub track enable` registers this under SessionStart + SessionEnd in
~/.claude/settings.json. On **SessionEnd** (once per session — NOT Stop, which fires
per turn and would overwrite the record ~50x with partial data) it reads the session
transcript, extracts process metrics, and writes three local-first files keyed off the
hook-stdin session_id (== the transcript filename stem):

  <XDG_STATE>/khub-telemetry/metrics/<id>.json   export-safe: counts only, NO raw text
  <XDG_STATE>/khub-telemetry/capture/<id>.jsonl  raw turn pairs (local-only, truncated)
  <XDG_STATE>/khub-telemetry/report/<id>.txt      a pre-rendered human summary

FAIL-OPEN CONTRACT (do not weaken): a SessionEnd hook that exits non-zero blocks the
turn, and a missing interpreter yields 127. So this script takes NO argparse (reads
everything from stdin), skips any unparseable transcript line, and ALWAYS exits 0 —
even on malformed stdin, an absent transcript, or an internal exception. The command
khub registers is additionally guarded with ``|| exit 0``.

Determinism: every metric derives from the transcript alone (no wall-clock now), and
metrics/report are written with sorted keys, so re-parsing a transcript is byte-stable.
"""

import json
import os
import sys
from datetime import datetime

SCHEMA_VERSION = 1
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
SUBAGENT_TOOLS = ("Agent", "Task")
REWORK_MIN = 3            # a file edited >= this many times = a rework/churn signal
SHORT_PROMPT_MAX = 40     # a short, non-first prompt ~ a correction/clarification
TRUNC = 2000              # cap raw prompt/response text stored locally
DROP_ENTRYPOINTS = ("sdk-ts",)   # automation surfaces excluded from the population
RETAIN_DAYS = 14          # raw capture auto-purge age
CAPTURE_CAP_BYTES = 50 * 1024 * 1024   # ...or total-size cap, whichever hits first


# ---- paths / gating ---------------------------------------------------------
def _config_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "khub", "telemetry.conf")


def _state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "khub-telemetry")


def _enabled():
    try:
        with open(_config_path(), encoding="utf-8") as fh:
            for line in fh:
                if line.strip() == "enabled=1":
                    return True
    except Exception:
        return False
    return False


def _task_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "khub", "telemetry-task")


def _active_task():
    """The manually-set ticket id (`khub track task <id>`), or None to fall back to
    git-branch attribution."""
    try:
        with open(_task_path(), encoding="utf-8") as fh:
            t = fh.readline().strip()
            return t or None
    except Exception:
        return None


# ---- transcript helpers -----------------------------------------------------
def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def _is_tool_result_envelope(content):
    return isinstance(content, list) and any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    )


def _epoch(ts):
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _num(x):
    """int(x), or 0 on anything non-numeric — token fields must never raise."""
    try:
        return int(x)
    except (TypeError, ValueError):
        return 0


def _blocks(msg):
    c = msg.get("content") if isinstance(msg, dict) else None
    return c if isinstance(c, list) else []


def _zero_tokens():
    return {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}


def parse_transcript(path, manual_task=None):
    """Single streaming pass → (metrics dict, entrypoint, raw_turns). Parsed
    defensively: an unparseable line is skipped, and each field is read with a safe
    fallback (non-numeric tokens → 0, non-string keys → "unknown"/"?"), so a future
    transcript-schema drift degrades gracefully instead of dropping the whole
    session's metrics.

    Token attribution: if manual_task is set (`khub track task <id>`) the whole
    session's tokens are booked to that ticket; otherwise they are split by the
    git branch each turn ran on (one-branch-per-ticket workflows get this free)."""
    tool_calls = {}
    tokens = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}
    tokens_by_branch = {}           # gitBranch -> token dict (for auto attribution)
    edits = {}                      # file_path -> count
    prompts = 0
    slash = 0
    corrections = 0
    error_retries = 0
    subagents = {}                  # subagent_type -> count
    subagents_total = 0
    ts_min = ts_max = None
    entrypoint = None
    pending_error = False           # an error tool_result awaiting a retry tool_use
    raw_turns = []
    cur = None                      # current turn being assembled for raw capture

    def flush():
        if cur is not None:
            raw_turns.append(cur)

    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            # duration spans EVERY timestamped line (sidechain/meta included)
            e = _epoch(obj.get("timestamp"))
            if e is not None:
                ts_min = e if ts_min is None else min(ts_min, e)
                ts_max = e if ts_max is None else max(ts_max, e)
            if entrypoint is None and obj.get("entrypoint"):
                entrypoint = obj.get("entrypoint")
            if obj.get("isSidechain") is True:
                continue            # subagent line — excluded from the population's metrics
            t = obj.get("type")
            msg = obj.get("message")

            if t == "assistant" and isinstance(msg, dict):
                usage = msg.get("usage")
                if isinstance(usage, dict):
                    ui = _num(usage.get("input_tokens"))
                    uo = _num(usage.get("output_tokens"))
                    ur = _num(usage.get("cache_read_input_tokens"))
                    uc = _num(usage.get("cache_creation_input_tokens"))
                    tokens["input"] += ui
                    tokens["output"] += uo
                    tokens["cache_read"] += ur
                    tokens["cache_creation"] += uc
                    br = obj.get("gitBranch")
                    br = br if isinstance(br, str) and br else "unknown"
                    bt = tokens_by_branch.setdefault(br, _zero_tokens())
                    bt["input"] += ui
                    bt["output"] += uo
                    bt["cache_read"] += ur
                    bt["cache_creation"] += uc
                for b in _blocks(msg):
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use":
                        name = b.get("name")
                        name = name if isinstance(name, str) and name else "?"
                        tool_calls[name] = tool_calls.get(name, 0) + 1
                        if pending_error:
                            error_retries += 1
                            pending_error = False
                        inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                        if name in EDIT_TOOLS:
                            fp = inp.get("file_path") or inp.get("notebook_path")
                            if isinstance(fp, str) and fp:
                                edits[fp] = edits.get(fp, 0) + 1
                        if name in SUBAGENT_TOOLS:
                            subagents_total += 1
                            st = inp.get("subagent_type")
                            st = st if isinstance(st, str) and st else "unknown"
                            subagents[st] = subagents.get(st, 0) + 1
                        if cur is not None:
                            cur["tools"].append(name)
                    elif b.get("type") == "text" and cur is not None:
                        cur["response"] = (cur["response"] + str(b.get("text", "")))[:TRUNC]

            elif t == "user" and isinstance(msg, dict):
                content = msg.get("content")
                if _is_tool_result_envelope(content):
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error") is True:
                            pending_error = True
                    continue
                if obj.get("isMeta") is True:
                    continue
                text = _text_of(content).strip()
                if not text:
                    continue
                prompts += 1
                is_slash = text.startswith("/")
                if is_slash:
                    slash += 1
                # a short, non-first prompt that is NOT a slash command ~ a correction
                if prompts > 1 and not is_slash and len(text) <= SHORT_PROMPT_MAX:
                    corrections += 1
                flush()
                cur = {"ts": obj.get("timestamp"), "prompt": text[:TRUNC],
                       "response": "", "tools": []}
    flush()

    distinct = len(edits)
    reworked = sum(1 for n in edits.values() if n >= REWORK_MIN)
    duration = int(round((ts_max - ts_min))) if (ts_min is not None and ts_max is not None) else 0
    # Token attribution → per ticket. Manual tag books the whole session to that
    # ticket; otherwise split by git branch (the dominant branch names the session).
    if manual_task:
        task = manual_task
        tokens_by_task = {manual_task: dict(tokens)}
    elif tokens_by_branch:
        tokens_by_task = tokens_by_branch
        task = max(tokens_by_branch, key=lambda b: tokens_by_branch[b]["output"])
    else:
        task = "unknown"
        tokens_by_task = {}
    metrics = {
        "schema_version": SCHEMA_VERSION,
        "entrypoint": entrypoint or "unknown",
        "duration_seconds": duration,
        "prompts": prompts,
        "turns": prompts,
        "task": task,
        "tokens_by_task": tokens_by_task,
        "tool_calls_total": sum(tool_calls.values()),
        "tool_calls": tool_calls,
        "tokens": tokens,
        "edits": {"total": sum(edits.values()), "distinct_files": distinct, "reworked_files": reworked},
        "error_retries": error_retries,
        "subagents": {"total": subagents_total, "types": subagents},
        "slash_commands": slash,
        "user_corrections": corrections,
    }
    return metrics, (entrypoint or "unknown"), raw_turns


# ---- output -----------------------------------------------------------------
def _atomic_write(path, text, mode=0o600):
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode), "w", encoding="utf-8") as fh:
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def render_report(session_id, m):
    tc = ", ".join("%s %d" % (k, m["tool_calls"][k]) for k in sorted(m["tool_calls"]))
    st = ", ".join("%s %d" % (k, m["subagents"]["types"][k]) for k in sorted(m["subagents"]["types"]))
    tk = m["tokens"]
    lines = [
        "khub telemetry — session %s" % session_id,
        "task: %s · output tokens: %d" % (m.get("task", "unknown"), tk["output"]),
        "entrypoint: %s · duration: %ds · prompts: %d · turns: %d"
        % (m["entrypoint"], m["duration_seconds"], m["prompts"], m["turns"]),
        "tools: %d total (%s)" % (m["tool_calls_total"], tc or "none"),
        "tokens: in %d / out %d / cache-read %d / cache-create %d"
        % (tk["input"], tk["output"], tk["cache_read"], tk["cache_creation"]),
        "edits: %d (%d files, %d reworked)"
        % (m["edits"]["total"], m["edits"]["distinct_files"], m["edits"]["reworked_files"]),
        "errors→retries: %d · subagents: %d (%s)" % (m["error_retries"], m["subagents"]["total"], st or "none"),
        "slash-commands: %d · user-corrections: %d" % (m["slash_commands"], m["user_corrections"]),
    ]
    return "\n".join(lines) + "\n"


def purge_old_captures(cap_dir):
    """Best-effort retention: drop raw capture files older than RETAIN_DAYS, then
    enforce a total-size cap by removing the oldest. Never raises."""
    try:
        import time
        files = []
        for name in os.listdir(cap_dir):
            fp = os.path.join(cap_dir, name)
            if os.path.isfile(fp):
                files.append((os.stat(fp).st_mtime, os.path.getsize(fp), fp))
        now = time.time()
        cutoff = now - RETAIN_DAYS * 86400
        kept = []
        for mtime, size, fp in files:
            if mtime < cutoff:
                try:
                    os.unlink(fp)
                except OSError:
                    pass
            else:
                kept.append((mtime, size, fp))
        total = sum(s for _, s, _ in kept)
        for mtime, size, fp in sorted(kept):   # oldest first
            if total <= CAPTURE_CAP_BYTES:
                break
            try:
                os.unlink(fp)
                total -= size
            except OSError:
                pass
    except Exception:
        pass


def rollup(session_id, transcript_path):
    if not session_id or not transcript_path or not os.path.isfile(transcript_path):
        return
    metrics, entrypoint, raw_turns = parse_transcript(transcript_path, _active_task())
    if entrypoint in DROP_ENTRYPOINTS:
        return                       # automation surface — excluded from the population
    metrics["session_id"] = session_id
    state = _state_dir()
    _atomic_write(os.path.join(state, "metrics", "%s.json" % session_id),
                  json.dumps(metrics, sort_keys=True, indent=2) + "\n")
    _atomic_write(os.path.join(state, "report", "%s.txt" % session_id),
                  render_report(session_id, metrics))
    cap = os.path.join(state, "capture", "%s.jsonl" % session_id)
    _atomic_write(cap, "".join(json.dumps(t, sort_keys=True) + "\n" for t in raw_turns))
    purge_old_captures(os.path.join(state, "capture"))


def main():
    raw = sys.stdin.read()
    if not _enabled():
        return
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return
    if payload.get("hook_event_name") != "SessionEnd":
        return                       # SessionStart fingerprint is a later phase
    rollup(payload.get("session_id"), payload.get("transcript_path"))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
