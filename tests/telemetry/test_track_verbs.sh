#!/usr/bin/env bash
# End-to-end tests for `khub track {enable,disable,status,repair}` — the opt-in
# telemetry install framework — driven through the real khub CLI in a fully
# sandboxed HOME + XDG so the developer's own ~/.claude is never touched.
#
# Covers the consequences the merge-helper unit tests can't: the transactional
# enable (no half-state), python3-absent HARD-FAIL, hook-file integrity + repair,
# and that the no-op hook actually fires on the registered stdin contract.
#
# NOTE: -e is intentionally OFF — several cases assert on non-zero exits.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
KHUB="$repo_root/khub"
BASH_BIN="$(command -v bash || echo /bin/bash)"
PY="$(command -v python3 || true)"

pass=0; fail=0
_ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
_no() { printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

[ -n "$PY" ] || { echo "python3 required to run these tests"; exit 1; }

# A fresh sandbox per case: isolated HOME + XDG dirs, helper resolved from the repo.
new_sandbox() { mktemp -d "${TMPDIR:-/tmp}/khub-track.XXXXXX"; }
run_track() { # <sandbox> <args...>
  local sb="$1"; shift
  NO_COLOR=1 HOME="$sb/home" \
    XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" XDG_STATE_HOME="$sb/state" \
    KHUB_LIB_DIR="$repo_root/lib" \
    "$BASH_BIN" "$KHUB" track "$@"
}
run_khub() { # <sandbox> <verb...>   — any khub verb in the same sandbox
  local sb="$1"; shift
  NO_COLOR=1 HOME="$sb/home" \
    XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" XDG_STATE_HOME="$sb/state" \
    KHUB_LIB_DIR="$repo_root/lib" \
    "$BASH_BIN" "$KHUB" "$@"
}
settings_of() { printf '%s/home/.claude/settings.json' "$1"; }
config_of()   { printf '%s/config/khub/telemetry.conf' "$1"; }
hookfile_of() { printf '%s/data/khub-telemetry/capture_hook.py' "$1"; }
# khub's entries are identified by the hook-path token in their command (schema-clean)
no_khub_marks() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1])); h=d.get("hooks",{}); tok="khub-telemetry/capture_hook.py"
def isk(e): return isinstance(e,dict) and any(tok in (hh.get("command","") if isinstance(hh,dict) else "") for hh in e.get("hooks",[]))
bad=any(isk(e) for arr in h.values() if isinstance(arr,list) for e in arr)
sys.exit(1 if bad else 0)' "$1"; }
mode_of() { "$PY" -c 'import os,stat,sys;print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[-3:])' "$1"; }

# ---------------------------------------------------------------------------
# 1. enable (user scope): settings registered, config written, hook installed 0500
sb="$(new_sandbox)"; s="$(settings_of "$sb")"; c="$(config_of "$sb")"; hk="$(hookfile_of "$sb")"
run_track "$sb" enable >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$s" ] && [ -f "$c" ] && [ -f "$hk" ]; then
  ent_ok=1
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1])); h=d["hooks"]; tok="khub-telemetry/capture_hook.py"
def isk(e): return any(tok in hh.get("command","") for hh in e.get("hooks",[]))
assert any(isk(e) for e in h["SessionStart"]); assert any(isk(e) for e in h["SessionEnd"])
assert all(set(e.keys())<= {"matcher","hooks"} for e in h["SessionStart"] if isk(e))' "$s" 2>/dev/null || ent_ok=0
  grep -q '^enabled=1$' "$c" || ent_ok=0
  [ "$(mode_of "$hk")" = "500" ] || ent_ok=0
  # sha recorded == sha of the installed hook
  rec="$(sed -n 's/^hook_sha256=//p' "$c")"
  actual="$(shasum -a 256 "$hk" 2>/dev/null | awk '{print $1}')"; [ -n "$actual" ] || actual="$(sha256sum "$hk" | awk '{print $1}')"
  [ -n "$rec" ] && [ "$rec" = "$actual" ] || ent_ok=0
  if [ "$ent_ok" -eq 1 ]; then _ok "enable: registers hooks, writes enabled config, installs 0500 hook w/ matching sha"
  else _no "enable: some post-condition missing"; fi
else _no "enable: did not produce settings/config/hook (rc=$rc)"; fi
rm -rf "$sb"

# 2. status after enable: enabled + registered + integrity verified
sb="$(new_sandbox)"
run_track "$sb" enable >/dev/null 2>&1
out="$(run_track "$sb" status 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'enabled' \
   && printf '%s' "$out" | grep -q 'registered' \
   && printf '%s' "$out" | grep -qi 'integrity verified'; then
  _ok "status: reports enabled + registered + integrity verified"
else _no "status: missing expected lines" "$out"; fi
rm -rf "$sb"

# 3. idempotent: two enables => exactly one khub block per event
sb="$(new_sandbox)"; s="$(settings_of "$sb")"
run_track "$sb" enable >/dev/null 2>&1
run_track "$sb" enable >/dev/null 2>&1
if "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1])); h=d["hooks"]; tok="khub-telemetry/capture_hook.py"
def isk(e): return any(tok in hh.get("command","") for hh in e.get("hooks",[]))
sys.exit(0 if sum(isk(e) for e in h["SessionStart"])==1 and sum(isk(e) for e in h["SessionEnd"])==1 else 1)' "$s"; then
  _ok "idempotent: re-enable keeps exactly one khub block per event"
else _no "idempotent: duplicate blocks after re-enable"; fi
rm -rf "$sb"

# 3b. round-trip enable -> disable -> enable via the CLI: exactly one block per event
sb="$(new_sandbox)"; s="$(settings_of "$sb")"
run_track "$sb" enable  >/dev/null 2>&1
run_track "$sb" disable >/dev/null 2>&1
run_track "$sb" enable  >/dev/null 2>&1
if "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1])); h=d["hooks"]; tok="khub-telemetry/capture_hook.py"
def isk(e): return any(tok in hh.get("command","") for hh in e.get("hooks",[]))
sys.exit(0 if sum(isk(e) for e in h["SessionStart"])==1 and sum(isk(e) for e in h["SessionEnd"])==1 else 1)' "$s"; then
  _ok "round-trip: enable->disable->enable leaves one block per event"
else _no "round-trip: duplicate/missing blocks after cycle"; fi
rm -rf "$sb"

# 4. disable: settings unregistered, hook + config removed
sb="$(new_sandbox)"; s="$(settings_of "$sb")"; c="$(config_of "$sb")"; hk="$(hookfile_of "$sb")"
run_track "$sb" enable >/dev/null 2>&1
run_track "$sb" disable >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && no_khub_marks "$s" && [ ! -f "$hk" ] && [ ! -f "$c" ]; then
  _ok "disable: unregisters khub entries, removes hook + config"
else _no "disable: residue left (rc=$rc)"; fi
rm -rf "$sb"

# 5. python3 absent -> HARD-FAIL: non-zero, NO settings, NO config, actionable msg
sb="$(new_sandbox)"; s="$(settings_of "$sb")"; c="$(config_of "$sb")"
err="$(PATH="" NO_COLOR=1 HOME="$sb/home" \
  XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" XDG_STATE_HOME="$sb/state" \
  KHUB_LIB_DIR="$repo_root/lib" "$BASH_BIN" "$KHUB" track enable 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$s" ] && [ ! -f "$c" ] && printf '%s' "$err" | grep -qi 'python3'; then
  _ok "python3-absent: hard-fails, nothing written, message names python3"
else _no "python3-absent: mutated state or wrong exit (rc=$rc)" "$err"; fi
rm -rf "$sb"

# 6. not-writable user settings -> abort + steer to --project (skipped as root)
if [ "$(id -u)" != "0" ]; then
  sb="$(new_sandbox)"; s="$(settings_of "$sb")"; c="$(config_of "$sb")"; hk="$(hookfile_of "$sb")"
  mkdir -p "$(dirname "$s")"; printf '{}\n' > "$s"; chmod 400 "$s"
  err="$(run_track "$sb" enable 2>&1 >/dev/null)"; rc=$?
  # transactional: abort with NO config, hook file ROLLED BACK, and a --project hint
  if [ "$rc" -ne 0 ] && [ ! -f "$c" ] && [ ! -f "$hk" ] && printf '%s' "$err" | grep -q 'project'; then
    _ok "not-writable: aborts, no config, hook rolled back, suggests --project"
  else _no "not-writable: incomplete rollback or wrong steer (rc=$rc, hook=$([ -f "$hk" ] && echo present || echo gone))" "$err"; fi
  chmod 600 "$s" 2>/dev/null || true; rm -rf "$sb"
else
  printf '  skip not-writable case (running as root)\n'
fi

# 6b. --project scope installs into ./.claude/settings.json (cwd)
sb="$(new_sandbox)"; proj="$sb/proj"; mkdir -p "$proj"
( cd "$proj" && NO_COLOR=1 HOME="$sb/home" \
  XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" XDG_STATE_HOME="$sb/state" \
  KHUB_LIB_DIR="$repo_root/lib" "$BASH_BIN" "$KHUB" track enable --project >/dev/null 2>&1 )
if [ -f "$proj/.claude/settings.json" ]; then _ok "--project: installs into cwd .claude/settings.json"
else _no "--project: did not create project settings.json"; fi
rm -rf "$sb"

# 7. tamper hook -> status flags integrity; repair restores it
sb="$(new_sandbox)"; hk="$(hookfile_of "$sb")"
run_track "$sb" enable >/dev/null 2>&1
chmod u+w "$hk"; printf '# tampered\n' >> "$hk"
out="$(run_track "$sb" status 2>&1)"
tampered_flagged=0; printf '%s' "$out" | grep -qi 'digest changed' && tampered_flagged=1
run_track "$sb" repair >/dev/null 2>&1
out2="$(run_track "$sb" status 2>&1)"
if [ "$tampered_flagged" -eq 1 ] && printf '%s' "$out2" | grep -qi 'integrity verified'; then
  _ok "integrity: tamper flagged, repair restores the canonical hook"
else _no "integrity: tamper/repair path broken" "$out"; fi
rm -rf "$sb"

# 8. END-TO-END wire: enable installs the hook; firing it on a transcript produces
#    metrics; `khub metrics` surfaces them; and it stays gated once disabled.
sb="$(new_sandbox)"; hk="$(hookfile_of "$sb")"
run_track "$sb" enable >/dev/null 2>&1
fixture="$repo_root/tests/telemetry/fixtures/session-cli.transcript.jsonl"
printf '{"hook_event_name":"SessionEnd","session_id":"wire","transcript_path":"%s"}' "$fixture" | \
  XDG_CONFIG_HOME="$sb/config" XDG_STATE_HOME="$sb/state" "$PY" "$hk"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$sb/state/khub-telemetry/metrics/wire.json" ]; then
  _ok "wire: the installed hook turns a transcript into metrics, exit 0"
else _no "wire: installed hook produced no metrics (rc=$rc)"; fi
out="$(run_khub "$sb" metrics 2>&1)"
if printf '%s' "$out" | grep -q 'prompts: 3'; then _ok "khub metrics: shows the latest session report"
else _no "khub metrics: did not surface the report" "$out"; fi
# gated: enabled flag gone => same hook writes nothing, still exit 0
rm -f "$(config_of "$sb")"
printf '{"hook_event_name":"SessionEnd","session_id":"gated","transcript_path":"%s"}' "$fixture" | \
  XDG_CONFIG_HOME="$sb/config" XDG_STATE_HOME="$sb/state" "$PY" "$hk" 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$sb/state/khub-telemetry/metrics/gated.json" ]; then
  _ok "hook gated: no enabled config => no metrics, exit 0"
else _no "hook gated: produced metrics while not enabled (rc=$rc)"; fi
rm -rf "$sb"

# 9. `khub track task` + `khub metrics --by-task`: token accounting per ticket
sb="$(new_sandbox)"; hk="$(hookfile_of "$sb")"; tf="$sb/config/khub/telemetry-task"
run_track "$sb" enable >/dev/null 2>&1
run_track "$sb" task "KHUB-1" >/dev/null 2>&1
set_ok=0; [ -s "$tf" ] && [ "$(head -1 "$tf")" = "KHUB-1" ] && set_ok=1
show="$(run_track "$sb" task 2>&1)"
fixture="$repo_root/tests/telemetry/fixtures/session-cli.transcript.jsonl"
printf '{"hook_event_name":"SessionEnd","session_id":"tk","transcript_path":"%s"}' "$fixture" | \
  XDG_CONFIG_HOME="$sb/config" XDG_STATE_HOME="$sb/state" "$PY" "$hk" >/dev/null 2>&1
tagged="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["task"])' "$sb/state/khub-telemetry/metrics/tk.json" 2>/dev/null)"
by="$(run_khub "$sb" metrics --by-task 2>&1)"
if [ "$set_ok" -eq 1 ] && printf '%s' "$show" | grep -q 'KHUB-1' \
   && [ "$tagged" = "KHUB-1" ] && printf '%s' "$by" | grep -q 'KHUB-1' && printf '%s' "$by" | grep -q 'out 350'; then
  _ok "track task: sets ticket, session books to it, metrics --by-task totals it"
else _no "track task: attribution flow broke (set=$set_ok tagged=$tagged)" "$by"; fi
# clear resets to branch attribution
run_track "$sb" task --clear >/dev/null 2>&1
if [ ! -f "$tf" ]; then _ok "track task --clear: removes the active ticket"
else _no "track task --clear: task file remained"; fi
rm -rf "$sb"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
