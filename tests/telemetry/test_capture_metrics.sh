#!/usr/bin/env bash
# Tests for lib/telemetry/capture_hook.py — the SessionEnd rollup that turns a real
# Claude Code transcript into process metrics. Asserts every metric against a
# hand-counted fixture, determinism, fail-open behaviour, the population filter
# (drop sdk-ts/automation), the session-id join (F7), and that metrics carry NO raw
# prompt/response text.
#
# NOTE: -e is intentionally OFF — several cases assert on non-zero-free fail-open.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
HOOK="$repo_root/lib/telemetry/capture_hook.py"
FIX="$here/fixtures"
PY="$(command -v python3 || true)"

pass=0; fail=0
_ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
_no() { printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

sandbox() { mktemp -d "${TMPDIR:-/tmp}/khub-cap.XXXXXX"; }
# fire the hook as Claude Code would: stdin JSON with event + session_id + transcript
fire() { # <sandbox> <event> <session_id> <transcript_path>
  printf '{"hook_event_name":"%s","session_id":"%s","transcript_path":"%s"}' "$2" "$3" "$4" | \
    XDG_CONFIG_HOME="$1/config" XDG_STATE_HOME="$1/state" "$PY" "$HOOK"
}
enable_cfg() { mkdir -p "$1/config/khub"; printf 'enabled=1\nschema_version=1\n' > "$1/config/khub/telemetry.conf"; }
metrics_json() { printf '%s/state/khub-telemetry/metrics/%s.json' "$1" "$2"; }
mval() { "$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2" 2>/dev/null; }

[ -n "$PY" ] || { echo "python3 required"; exit 1; }

# ---------------------------------------------------------------------------
# 1. metrics match the hand-counted fixture, keyed off the stdin session_id
sb="$(sandbox)"; enable_cfg "$sb"
fire "$sb" SessionEnd S1 "$FIX/session-cli.transcript.jsonl"; rc=$?
mj="$(metrics_json "$sb" S1)"
if [ "$rc" -eq 0 ] && [ -f "$mj" ]; then
  ok_all=1
  chk() { local got; got="$("$PY" -c 'import json,sys;d=json.load(open(sys.argv[1]))
k=sys.argv[2]; v=d
for part in k.split("."): v=v[part] if not part.isdigit() else v[int(part)]
print(json.dumps(v,sort_keys=True))' "$mj" "$1" 2>/dev/null)"
    if [ "$got" != "$2" ]; then _no "metric $1 = $got (expected $2)"; ok_all=0; fi; }
  chk session_id '"S1"'
  chk prompts 3
  chk turns 3
  chk tool_calls_total 6
  chk tool_calls '{"Agent": 1, "Bash": 1, "Edit": 3, "Write": 1}'
  chk tokens '{"cache_creation": 35, "cache_read": 70, "input": 700, "output": 350}'
  chk edits '{"distinct_files": 2, "reworked_files": 1, "total": 4}'
  chk error_retries 1
  chk subagents '{"total": 1, "types": {"code-reviewer": 1}}'
  chk slash_commands 1
  chk user_corrections 1
  chk duration_seconds 120
  chk entrypoint '"cli"'
  if [ "$ok_all" -eq 1 ]; then _ok "metrics match hand-counted fixture (all fields)"; fi
else _no "capture: no metrics file produced (rc=$rc)"; fi
# raw capture + report also written
if [ -f "$sb/state/khub-telemetry/capture/S1.jsonl" ]; then _ok "raw capture/S1.jsonl written"; else _no "no raw capture file"; fi
if [ -f "$sb/state/khub-telemetry/report/S1.txt" ]; then _ok "report/S1.txt written"; else _no "no report file"; fi
rm -rf "$sb"

# 2. determinism: re-parsing the same transcript yields byte-identical metrics
sb="$(sandbox)"; enable_cfg "$sb"
fire "$sb" SessionEnd S1 "$FIX/session-cli.transcript.jsonl" >/dev/null 2>&1
h1="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$(metrics_json "$sb" S1)")"
fire "$sb" SessionEnd S1 "$FIX/session-cli.transcript.jsonl" >/dev/null 2>&1
h2="$("$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$(metrics_json "$sb" S1)")"
if [ "$h1" = "$h2" ]; then _ok "determinism: re-run => byte-identical metrics"; else _no "determinism: metrics changed on re-run"; fi
rm -rf "$sb"

# 3. metrics carry NO raw prompt/response text, tool output, or file paths
sb="$(sandbox)"; enable_cfg "$sb"
fire "$sb" SessionEnd S1 "$FIX/session-cli.transcript.jsonl" >/dev/null 2>&1
mj="$(metrics_json "$sb" S1)"
leak=0
for needle in "how do I add a hook" "OUTPUT" "a.py" "b.py" "/repo/"; do
  grep -qF "$needle" "$mj" && { leak=1; echo "       leaked: $needle"; }
done
if [ "$leak" -eq 0 ]; then _ok "metrics: no raw text / tool output / file paths"; else _no "metrics leaked raw content"; fi
# but raw capture MAY hold text (local-only); it exists
if [ -s "$sb/state/khub-telemetry/capture/S1.jsonl" ]; then _ok "raw capture is non-empty (local-only detail)"; else _no "raw capture empty"; fi
rm -rf "$sb"

# 4. population filter: an sdk-ts session is DROPPED (no metrics written)
sb="$(sandbox)"; enable_cfg "$sb"
fire "$sb" SessionEnd S2 "$FIX/session-sdk.transcript.jsonl"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$(metrics_json "$sb" S2)" ]; then _ok "population filter: sdk-ts session dropped, exit 0"
else _no "population filter: sdk-ts not dropped (rc=$rc)"; fi
rm -rf "$sb"

# 4b. any sdk-* surface is dropped (sdk-cli seen live), and a <synthetic>-model
#     session is dropped even under an interactive entrypoint
sb="$(sandbox)"; enable_cfg "$sb"; sdkcli="$sb/sdkcli.jsonl"; syn="$sb/syn.jsonl"
{
  printf '%s\n' '{"type":"user","timestamp":"2026-07-11T00:00:00Z","entrypoint":"sdk-cli","message":{"role":"user","content":"x"}}'
  printf '%s\n' '{"type":"assistant","timestamp":"2026-07-11T00:00:01Z","entrypoint":"sdk-cli","message":{"role":"assistant","content":[{"type":"text","text":"r"}],"usage":{"input_tokens":1,"output_tokens":1}}}'
} > "$sdkcli"
{
  printf '%s\n' '{"type":"user","timestamp":"2026-07-11T00:00:00Z","entrypoint":"cli","message":{"role":"user","content":"x"}}'
  printf '%s\n' '{"type":"assistant","timestamp":"2026-07-11T00:00:01Z","entrypoint":"cli","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"r"}],"usage":{"input_tokens":1,"output_tokens":1}}}'
} > "$syn"
fire "$sb" SessionEnd SC1 "$sdkcli" >/dev/null 2>&1
fire "$sb" SessionEnd SY1 "$syn" >/dev/null 2>&1
if [ ! -f "$(metrics_json "$sb" SC1)" ] && [ ! -f "$(metrics_json "$sb" SY1)" ]; then
  _ok "population filter: sdk-cli + <synthetic>-model sessions dropped"
else _no "population filter: sdk-cli or synthetic not dropped"; fi
rm -rf "$sb"

# 5. fail-open: malformed lines are skipped, a record is still emitted, exit 0
sb="$(sandbox)"; enable_cfg "$sb"
fire "$sb" SessionEnd S3 "$FIX/session-malformed.transcript.jsonl"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$(metrics_json "$sb" S3)" ] && [ "$(mval "$(metrics_json "$sb" S3)" prompts)" = "1" ]; then
  _ok "fail-open: skips bad line, still emits metrics (1 prompt), exit 0"
else _no "fail-open: malformed transcript mishandled (rc=$rc)"; fi
rm -rf "$sb"

# 6. fail-open: absent transcript + gated-off => no crash, no files, exit 0
sb="$(sandbox)"; enable_cfg "$sb"
fire "$sb" SessionEnd S4 "$sb/nope.jsonl"; rc=$?
a=0; [ "$rc" -eq 0 ] && [ ! -f "$(metrics_json "$sb" S4)" ] && a=1
# gated off: no config at all
sb2="$(sandbox)"
fire "$sb2" SessionEnd S5 "$FIX/session-cli.transcript.jsonl"; rc2=$?
b=0; [ "$rc2" -eq 0 ] && [ ! -f "$(metrics_json "$sb2" S5)" ] && b=1
if [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then _ok "fail-open: absent transcript + gated-off => exit 0, no files"; else _no "fail-open: absent/gated mishandled (rc=$rc/$rc2)"; fi
rm -rf "$sb" "$sb2"

# 7. SessionStart event is a no-op in this phase (fingerprint is a later phase), exit 0
sb="$(sandbox)"; enable_cfg "$sb"
fire "$sb" SessionStart S6 "$FIX/session-cli.transcript.jsonl"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$(metrics_json "$sb" S6)" ]; then _ok "SessionStart: no rollup this phase, exit 0"; else _no "SessionStart mishandled (rc=$rc)"; fi
rm -rf "$sb"

# 8. type-drift resilience: a line with non-numeric tokens / non-string keys does
#    NOT drop the session — bad fields degrade to 0/"unknown", metrics still emit.
sb="$(sandbox)"; enable_cfg "$sb"; drift="$sb/drift.jsonl"
{
  printf '%s\n' '{"type":"user","timestamp":"2026-07-10T10:00:00Z","entrypoint":"cli","message":{"role":"user","content":"do a thing"}}'
  printf '%s\n' '{"type":"assistant","timestamp":"2026-07-10T10:00:05Z","entrypoint":"cli","message":{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Agent","input":{"subagent_type":["not","a","string"]}},{"type":"tool_use","id":"b","name":123,"input":{}}],"usage":{"input_tokens":"NaN","output_tokens":null}}}'
} > "$drift"
fire "$sb" SessionEnd S7 "$drift"; rc=$?
mj="$(metrics_json "$sb" S7)"
if [ "$rc" -eq 0 ] && [ -f "$mj" ] && [ "$(mval "$mj" prompts)" = "1" ] \
   && [ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["tokens"]["input"])' "$mj")" = "0" ]; then
  _ok "type-drift: bad token/key values degrade, metrics still emitted, exit 0"
else _no "type-drift: malformed fields dropped the session (rc=$rc)"; fi
rm -rf "$sb"

# 9. token attribution: auto by git branch, then manual ticket override
sb="$(sandbox)"; enable_cfg "$sb"
fire "$sb" SessionEnd A1 "$FIX/session-cli.transcript.jsonl" >/dev/null 2>&1
mj="$(metrics_json "$sb" A1)"
if [ "$(mval "$mj" task)" = "feat/telemetry" ] \
   && [ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["tokens_by_task"]["feat/telemetry"]["output"])' "$mj")" = "350" ]; then
  _ok "attribution (auto): tokens booked to the git branch"
else _no "attribution (auto): branch not used" "task=$(mval "$mj" task)"; fi
# manual ticket overrides the branch
printf 'TICKET-9\n' > "$sb/config/khub/telemetry-task"
fire "$sb" SessionEnd A2 "$FIX/session-cli.transcript.jsonl" >/dev/null 2>&1
mj="$(metrics_json "$sb" A2)"
if [ "$(mval "$mj" task)" = "TICKET-9" ] \
   && [ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["tokens_by_task"]["TICKET-9"]["output"])' "$mj")" = "350" ]; then
  _ok "attribution (manual): ticket tag overrides the branch, books whole session"
else _no "attribution (manual): ticket tag not honored" "task=$(mval "$mj" task)"; fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
