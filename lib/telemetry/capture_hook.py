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

import hashlib
import hmac
import json
import os
import platform
import sys
from datetime import datetime

SCHEMA_VERSION = 1
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
SUBAGENT_TOOLS = ("Agent", "Task")
REWORK_MIN = 3            # a file edited >= this many times = a rework/churn signal
SHORT_PROMPT_MAX = 40     # a short, non-first prompt ~ a correction/clarification
TRUNC = 2000              # cap raw prompt/response text stored locally
# SDK/automation surfaces excluded from the population — interactive work is cli/ide/
# web. Matched by PREFIX so every sdk-* variant is dropped (sdk-ts, sdk-cli, …): a
# real transcript surfaced entrypoint "sdk-cli" (a synthetic, 0-token invocation) that
# an exact "sdk-ts" match let slip through and pollute the store.
DROP_ENTRYPOINT_PREFIXES = ("sdk-",)
SYNTHETIC_MODEL = "<synthetic>"  # a non-LLM synthetic turn — never real interactive work
RETAIN_DAYS = 14          # raw capture auto-purge age
CAPTURE_CAP_BYTES = 50 * 1024 * 1024   # ...or total-size cap, whichever hits first
DEBUG_LOG_MAX_LINES = 500 # bound the opt-in debug log


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


def _config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "khub")


def _read_salt():
    """Per-install random salt (written by `khub track enable`). Identity fields are
    HMAC'd with it so the aggregator cannot reverse a guessable input (a cwd/remote/
    skill name) — hashing guessable inputs without a secret salt is NOT anonymisation."""
    try:
        with open(os.path.join(_config_dir(), "telemetry-salt"), encoding="utf-8") as fh:
            s = fh.readline().strip()
            return s or None
    except Exception:
        return None


def _read_cohort():
    try:
        with open(os.path.join(_config_dir(), "telemetry-cohort"), encoding="utf-8") as fh:
            c = fh.readline().strip()
            return c or "unset"
    except Exception:
        return "unset"


def _debug_on():
    return os.path.exists(os.path.join(_config_dir(), "telemetry-debug"))


def _debug(event, sid, outcome, detail=""):
    """Append one line to the opt-in debug log documenting WHAT the fail-open hook did
    and why — the only visibility into a hook that otherwise swallows every error.
    Redacted BY CONSTRUCTION: event + a short session-id prefix + an outcome label +
    counts/labels only (never a prompt, path, or exception message). Never raises."""
    if not _debug_on():
        return
    try:
        state = _state_dir()
        os.makedirs(state, mode=0o700, exist_ok=True)
        log = os.path.join(state, "debug.log")
        sid8 = sid[:8] if isinstance(sid, str) and sid else "-"
        ts = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
        with open(log, "a", encoding="utf-8") as fh:
            fh.write("%s %-12s %-8s %-14s %s\n" % (ts, event or "-", sid8, outcome, detail))
        with open(log, encoding="utf-8") as fh:
            lines = fh.readlines()
        if len(lines) > DEBUG_LOG_MAX_LINES:
            with open(log, "w", encoding="utf-8") as fh:
                fh.writelines(lines[-DEBUG_LOG_MAX_LINES:])
    except Exception:
        pass


def _salted(salt_hex, value):
    """Keyed HMAC-SHA256 (truncated) of a value, or None if unsalted/absent. Stored
    instead of the raw value so a skill name / repo path never leaves as plaintext."""
    if not salt_hex or value is None or value == "":
        return None
    try:
        key = bytes.fromhex(salt_hex)
    except (ValueError, TypeError):
        key = salt_hex.encode("utf-8")
    try:
        return hmac.new(key, str(value).encode("utf-8"), hashlib.sha256).hexdigest()[:16]
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


def _dropped_surface(entrypoint):
    """True for SDK/automation surfaces (any sdk-* entrypoint) — excluded from the
    interactive-work population."""
    e = entrypoint or ""
    return any(e.startswith(p) for p in DROP_ENTRYPOINT_PREFIXES)


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
    model = None                    # first assistant model seen (for the setup fingerprint)
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
                if model is None:
                    mv = msg.get("model")
                    if isinstance(mv, str) and mv:
                        model = mv
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
        "model": model,
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


# ---- setup fingerprint (SessionStart) --------------------------------------
# Tags each session with the SETUP it ran under — the independent variable for
# "which way of working wins". Portable (pure filesystem/env, no ClaudeKit APIs);
# identity fields are salted hashes / counts, never raw names or paths.
def _detect_setup(cwd):
    claude = os.path.join(cwd, ".claude") if cwd else None
    has_claude = bool(claude) and os.path.isdir(claude)
    has_rules = has_claude and os.path.isdir(os.path.join(claude, "rules"))
    skills = []
    if has_claude and os.path.isdir(os.path.join(claude, "skills")):
        try:
            skills = sorted(d for d in os.listdir(os.path.join(claude, "skills"))
                            if os.path.isdir(os.path.join(claude, "skills", d)))
        except OSError:
            skills = []
    if not has_claude:
        harness = "vanilla"
    elif has_rules and skills:
        harness = "claudekit"
    elif has_rules or skills:
        harness = "custom"
    else:
        harness = "vanilla"          # .claude exists but no rules/skills (e.g. just settings.json)
    return harness, has_rules, skills


def _rules_text(cwd):
    for rel in ("CLAUDE.md", os.path.join(".claude", "rules", "CLAUDE.md")):
        try:
            with open(os.path.join(cwd, rel), encoding="utf-8", errors="replace") as fh:
                return fh.read()
        except Exception:
            continue
    return None


def _repo_ident(cwd):
    """Stable repo id: the git remote url if readable, else the cwd path. Stored ONLY
    as a salted hash (never raw)."""
    try:
        with open(os.path.join(cwd, ".git", "config"), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("url = "):
                    return s[6:].strip()
    except Exception:
        pass
    return cwd


def _hub_present(cwd):
    if not cwd:
        return False
    for rel in ("knowledge-hub", os.path.join("..", "knowledge-hub")):
        if os.path.isdir(os.path.join(cwd, rel, ".knowledge")):
            return True
    return False


def build_fingerprint(session_id, cwd, surface):
    salt = _read_salt()
    harness, has_rules, skills = _detect_setup(cwd)
    return {
        "schema_version": SCHEMA_VERSION,
        "session_id": session_id,
        "harness": harness,
        "surface": surface or "unknown",
        "os": "%s %s" % (platform.system(), platform.machine()),
        "python": platform.python_version(),
        "model": None,               # filled from the transcript at the SessionEnd merge
        "skills_count": len(skills),
        "rules_present": has_rules,
        "rules_hash": _salted(salt, _rules_text(cwd)),
        "skills_hash": _salted(salt, ",".join(skills)) if skills else None,
        "hub_present": _hub_present(cwd),
        "repo_id": _salted(salt, _repo_ident(cwd)),
        "cohort": _read_cohort(),
        "has_salt": bool(salt),
    }


def write_fingerprint(payload):
    sid = payload.get("session_id")
    if not sid:
        _debug("SessionStart", sid, "no-session-id")
        return
    surface = payload.get("entrypoint") or "unknown"
    if _dropped_surface(surface):
        _debug("SessionStart", sid, "dropped-sdk", surface)
        return                       # don't fingerprint automation sessions either
    cwd = payload.get("cwd") or os.getcwd()
    fp = build_fingerprint(sid, cwd, surface)
    _atomic_write(os.path.join(_state_dir(), "fingerprint", "%s.json" % sid),
                  json.dumps(fp, sort_keys=True, indent=2) + "\n")
    _debug("SessionStart", sid, "ok", "harness=%s salt=%s" % (fp["harness"], fp["has_salt"]))


def _read_fingerprint(session_id):
    try:
        with open(os.path.join(_state_dir(), "fingerprint", "%s.json" % session_id), encoding="utf-8") as fh:
            fp = json.load(fh)
        return fp if isinstance(fp, dict) else None
    except Exception:
        return None


def rollup(session_id, transcript_path):
    if not session_id or not transcript_path or not os.path.isfile(transcript_path):
        _debug("SessionEnd", session_id, "no-transcript")
        return
    metrics, entrypoint, raw_turns = parse_transcript(transcript_path, _active_task())
    if _dropped_surface(entrypoint):
        _debug("SessionEnd", session_id, "dropped-sdk", entrypoint)
        return                       # automation surface — excluded from the population
    if metrics.get("model") == SYNTHETIC_MODEL:
        _debug("SessionEnd", session_id, "dropped-synthetic")
        return                       # a synthetic (non-LLM) session — not real work
    metrics["session_id"] = session_id
    fp = _read_fingerprint(session_id)   # join the SessionStart setup fingerprint (F7: by stdin id)
    if fp is not None:
        fp = dict(fp)
        if not fp.get("model"):
            fp["model"] = metrics.get("model")
        if fp.get("surface") in (None, "", "unknown"):
            fp["surface"] = metrics.get("entrypoint")
        metrics["setup"] = fp
    state = _state_dir()
    _atomic_write(os.path.join(state, "metrics", "%s.json" % session_id),
                  json.dumps(metrics, sort_keys=True, indent=2) + "\n")
    _atomic_write(os.path.join(state, "report", "%s.txt" % session_id),
                  render_report(session_id, metrics))
    cap = os.path.join(state, "capture", "%s.jsonl" % session_id)
    _atomic_write(cap, "".join(json.dumps(t, sort_keys=True) + "\n" for t in raw_turns))
    purge_old_captures(os.path.join(state, "capture"))
    _debug("SessionEnd", session_id, "ok",
           "prompts=%d tools=%d out=%d setup=%s"
           % (metrics["prompts"], metrics["tool_calls_total"], metrics["tokens"]["output"],
              "yes" if "setup" in metrics else "no"))


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        _debug("?", None, "bad-stdin")
        return
    event = payload.get("hook_event_name")
    sid = payload.get("session_id")
    if not _enabled():
        _debug(event, sid, "gated-off")   # logged even when off, to reveal that state
        return
    try:
        if event == "SessionStart":
            write_fingerprint(payload)
        elif event == "SessionEnd":
            rollup(sid, payload.get("transcript_path"))
        else:
            _debug(event, sid, "ignored-event")
    except Exception as exc:
        _debug(event, sid, "error", type(exc).__name__)   # type only — never the message


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
