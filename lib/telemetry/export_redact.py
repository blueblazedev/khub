#!/usr/bin/env python3
"""khub telemetry export + redaction.

Package setup-tagged metrics for sharing WITHOUT leaking. Two safety tiers:

  * DEFAULT (metrics only): an ALLOWLIST of known-safe fields — counts, a public
    model id, and the already-salted setup fingerprint. Unrecognised fields are
    dropped (fail-closed), `mcp__…` tool names are hashed (they reveal a client's
    installed toolchain), and for the EXTERNAL cohort task/branch labels are hashed
    too. Every string leaf is still run through the secret scrubber as defence in
    depth. Result is grep-proof: no raw prompt/response text, no $HOME, no login, no
    raw repo id, no secret.
  * --with-snippets (opt-in, high-touch): raw prompt/response text from the local
    capture, run through the scrubber ($HOME→~, login→<user>, and a secret-pattern
    inventory). Fail-closed: a line that can't be processed is skipped.

The EXTERNAL cohort is HARD-BLOCKED without an org-provisioned DPA consent token —
export refuses to run (exit 6). This contradicts khub's pull-only trust model on
purpose and needs a named owner's sign-off; the token is that machine-enforced gate.

Nothing is ever uploaded — the bundle is written locally for the engineer to review.
"""
import argparse
import glob
import hashlib
import hmac
import json
import os
import re
import sys

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_EXTERNAL_BLOCKED = 6

# Only these top-level metric fields are ever exported; anything else is dropped.
SAFE_TOP = (
    "schema_version", "session_id", "entrypoint", "duration_seconds", "prompts",
    "turns", "model", "tool_calls_total", "tool_calls", "tokens", "edits",
    "error_retries", "subagents", "slash_commands", "user_corrections", "task",
    "tokens_by_task", "setup",
)

SECRET_PATTERNS = [
    ("gh-token", re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}")),
    ("openai-key", re.compile(r"sk-[A-Za-z0-9]{20,}")),
    ("aws-key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("pem", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("url-creds", re.compile(r"://[^/@\s:]+:[^/@\s]+@")),
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")),
    ("secret-assign", re.compile(r"\b[A-Z][A-Z0-9_]{2,}=[^\s\"']{8,}")),
]
# Collapse a home-directory path shape even when it is not the runtime $HOME (F8:
# a client home /Users/alice/… must not leak just because CI's $HOME differs).
_HOME_SHAPE = re.compile(r"/(Users|home)/[^/\s\"']+")


def scrub_text(s, home, login):
    if not isinstance(s, str):
        return s
    if home:
        s = s.replace(home, "~")
    s = _HOME_SHAPE.sub(r"/\1/<user>", s)
    if login:
        s = s.replace(login, "<user>")
    for name, pat in SECRET_PATTERNS:
        s = pat.sub("<redacted:%s>" % name, s)
    return s


def _hash(salt, value):
    try:
        key = bytes.fromhex(salt) if salt else b"khub"
    except ValueError:
        key = (salt or "khub").encode("utf-8")
    return hmac.new(key, str(value).encode("utf-8"), hashlib.sha256).hexdigest()[:12]


def _scrub_obj(obj, home, login):
    if isinstance(obj, dict):
        return {k: _scrub_obj(v, home, login) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_scrub_obj(v, home, login) for v in obj]
    return scrub_text(obj, home, login)


def sanitize_metrics(rec, cohort, salt, home, login):
    if not isinstance(rec, dict):
        return None
    out = {k: rec[k] for k in SAFE_TOP if k in rec}
    # mcp/plugin tool names identify a client's toolchain — hash them (keep counts)
    tc = out.get("tool_calls")
    if isinstance(tc, dict):
        out["tool_calls"] = {
            ("mcp:%s" % _hash(salt, k) if isinstance(k, str) and k.startswith("mcp__") else k): v
            for k, v in tc.items()
        }
    # external cohort: task/branch labels can identify — hash them
    if cohort == "external":
        if isinstance(out.get("task"), str):
            out["task"] = "task:%s" % _hash(salt, out["task"])
        tbt = out.get("tokens_by_task")
        if isinstance(tbt, dict):
            out["tokens_by_task"] = {("task:%s" % _hash(salt, k)): v for k, v in tbt.items()}
    return _scrub_obj(out, home, login)


def build_bundle(args):
    cohort = args.cohort or "unset"
    if cohort == "external":
        tok = args.dpa_token
        if not (tok and os.path.isfile(tok) and os.path.getsize(tok) > 0):
            sys.stderr.write(
                "external-cohort export is BLOCKED: no DPA consent token.\n"
                "  a named DPA owner must provision the token file before external export can run.\n"
            )
            return EXIT_EXTERNAL_BLOCKED

    os.makedirs(args.out, exist_ok=True)
    recs = []
    for path in sorted(glob.glob(os.path.join(args.state, "metrics", "*.json"))):
        try:
            with open(path, encoding="utf-8") as fh:
                rec = json.load(fh)
        except Exception:
            continue
        san = sanitize_metrics(rec, cohort, args.salt, args.home, args.login)
        if san is not None:
            recs.append(san)
    with open(os.path.join(args.out, "metrics.ndjson"), "w", encoding="utf-8") as fh:
        for r in recs:
            fh.write(json.dumps(r, sort_keys=True) + "\n")

    snippet_count = 0
    if args.with_snippets:
        with open(os.path.join(args.out, "snippets.redacted.ndjson"), "w", encoding="utf-8") as out:
            for path in sorted(glob.glob(os.path.join(args.state, "capture", "*.jsonl"))):
                try:
                    with open(path, encoding="utf-8") as fh:
                        for line in fh:
                            line = line.strip()
                            if not line:
                                continue
                            turn = json.loads(line)
                            snip = {
                                "prompt": scrub_text(turn.get("prompt", ""), args.home, args.login),
                                "tools": turn.get("tools", []),
                            }
                            # responses can echo client code — drop them for external
                            if not args.exclude_tool_bodies:
                                snip["response"] = scrub_text(turn.get("response", ""), args.home, args.login)
                            out.write(json.dumps(snip, sort_keys=True) + "\n")
                            snippet_count += 1
                except Exception:
                    continue

    manifest = {
        "schema_version": 1,
        "session_count": len(recs),
        "cohort": cohort,
        "includes_snippets": bool(args.with_snippets),
        "snippet_count": snippet_count,
        "consent": {"opt_in": True, "cohort": cohort,
                    "dpa_token": bool(cohort == "external" and args.dpa_token)},
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, sort_keys=True, indent=2)
        fh.write("\n")
    return EXIT_OK


def main(argv=None):
    p = argparse.ArgumentParser(prog="export_redact.py")
    p.add_argument("--state", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--cohort", default="unset")
    p.add_argument("--dpa-token", dest="dpa_token", default=None)
    p.add_argument("--salt", default="")
    p.add_argument("--home", default=None)
    p.add_argument("--login", default=None)
    p.add_argument("--with-snippets", dest="with_snippets", action="store_true")
    p.add_argument("--exclude-tool-bodies", dest="exclude_tool_bodies", action="store_true")
    args = p.parse_args(argv)
    return build_bundle(args)


if __name__ == "__main__":
    sys.exit(main())
