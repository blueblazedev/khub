#!/usr/bin/env bash
# Tests for the SessionStart setup fingerprint in lib/telemetry/capture_hook.py.
# The fingerprint is the independent variable for "which way of working wins" — it
# must distinguish a ClaudeKit setup from a vanilla one, be PORTABLE (work with no
# ClaudeKit present), and store identity as SALTED HASHES / COUNTS, never raw names
# or paths (a skill name or repo path would identify a client).
#
# NOTE: -e intentionally OFF.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
HOOK="$repo_root/lib/telemetry/capture_hook.py"
FIX="$here/fixtures"
PY="$(command -v python3 || true)"

pass=0; fail=0
_ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
_no() { printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
[ -n "$PY" ] || { echo "python3 required"; exit 1; }

sandbox() { mktemp -d "${TMPDIR:-/tmp}/khub-fp.XXXXXX"; }
enable_cfg() {  # <sandbox> [cohort]
  mkdir -p "$1/config/khub"
  printf 'enabled=1\nschema_version=1\n' > "$1/config/khub/telemetry.conf"
  printf 'deadbeefcafebabe0011223344556677\n' > "$1/config/khub/telemetry-salt"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$1/config/khub/telemetry-cohort"
  return 0
}
# fire SessionStart with a given cwd
fp_fire() { # <sandbox> <session_id> <cwd> [entrypoint]
  printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s","entrypoint":"%s"}' "$2" "$3" "${4:-cli}" | \
    XDG_CONFIG_HOME="$1/config" XDG_STATE_HOME="$1/state" "$PY" "$HOOK"
}
fp_json() { printf '%s/state/khub-telemetry/fingerprint/%s.json' "$1" "$2"; }
fval() { "$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2" 2>/dev/null; }

# fixtures: a ClaudeKit-shaped project vs a vanilla one
mk_claudekit() { local d; d="$(mktemp -d "${TMPDIR:-/tmp}/ck-proj.XXXXXX")"
  mkdir -p "$d/.claude/rules" "$d/.claude/skills/acme-billing-reconciler" "$d/.claude/skills/deploy"
  printf '# rules\n' > "$d/.claude/rules/CLAUDE.md"; printf '# project\n' > "$d/CLAUDE.md"; printf '%s' "$d"; }
mk_vanilla() { mktemp -d "${TMPDIR:-/tmp}/vanilla-proj.XXXXXX"; }

# ---------------------------------------------------------------------------
# 1. ClaudeKit project -> harness=claudekit, skills + rules detected
sb="$(sandbox)"; enable_cfg "$sb"; ck="$(mk_claudekit)"
fp_fire "$sb" F1 "$ck"; rc=$?
fj="$(fp_json "$sb" F1)"
if [ "$rc" -eq 0 ] && [ -f "$fj" ] && [ "$(fval "$fj" harness)" = "claudekit" ] \
   && [ "$(fval "$fj" skills_count)" = "2" ] && [ "$(fval "$fj" rules_present)" = "True" ]; then
  _ok "claudekit: harness detected, skills counted, rules present"
else _no "claudekit: fingerprint wrong (rc=$rc harness=$(fval "$fj" harness))"; fi
rm -rf "$ck"

# 2. vanilla project -> harness=vanilla, portable (no ClaudeKit), valid fingerprint
va="$(mk_vanilla)"
fp_fire "$sb" F2 "$va"; rc=$?
fj="$(fp_json "$sb" F2)"
if [ "$rc" -eq 0 ] && [ -f "$fj" ] && [ "$(fval "$fj" harness)" = "vanilla" ] \
   && [ "$(fval "$fj" skills_count)" = "0" ]; then
  _ok "vanilla: harness=vanilla, portable, valid fingerprint"
else _no "vanilla: fingerprint wrong (rc=$rc harness=$(fval "$fj" harness))"; fi
rm -rf "$va"

# 3. identity is HASHED — no raw repo path, no raw skill names in the fingerprint
sb="$(sandbox)"; enable_cfg "$sb"; ck="$(mk_claudekit)"
fp_fire "$sb" F3 "$ck" >/dev/null 2>&1
fj="$(fp_json "$sb" F3)"
leak=0
grep -qF "$ck" "$fj" && { leak=1; echo "       leaked cwd path"; }
grep -qF "acme-billing-reconciler" "$fj" && { leak=1; echo "       leaked skill name"; }
has_repo=0; [ -n "$(fval "$fj" repo_id)" ] && [ "$(fval "$fj" repo_id)" != "None" ] && has_repo=1
has_skhash=0; [ "$(fval "$fj" skills_hash)" != "None" ] && has_skhash=1
if [ "$leak" -eq 0 ] && [ "$has_repo" -eq 1 ] && [ "$has_skhash" -eq 1 ]; then
  _ok "identity: repo id + skill names are salted hashes, no raw path/name leaked"
else _no "identity: leaked raw identifiers or missing hashes"; fi
rm -rf "$ck"

# 4. cohort flows from the config; default is unset
sb="$(sandbox)"; enable_cfg "$sb" internal; va="$(mk_vanilla)"
fp_fire "$sb" F4 "$va" >/dev/null 2>&1
if [ "$(fval "$(fp_json "$sb" F4)" cohort)" = "internal" ]; then _ok "cohort: honored from config"; else _no "cohort: not internal"; fi
rm -rf "$va"
sb2="$(sandbox)"; enable_cfg "$sb2"; va2="$(mk_vanilla)"   # no cohort file
fp_fire "$sb2" F4b "$va2" >/dev/null 2>&1
if [ "$(fval "$(fp_json "$sb2" F4b)" cohort)" = "unset" ]; then _ok "cohort: defaults to unset"; else _no "cohort: default wrong"; fi
rm -rf "$va2" "$sb2"

# 5. SessionEnd rollup JOINS the fingerprint into the metrics record (same session id)
sb="$(sandbox)"; enable_cfg "$sb"; ck="$(mk_claudekit)"
fp_fire "$sb" F5 "$ck" >/dev/null 2>&1
printf '{"hook_event_name":"SessionEnd","session_id":"F5","transcript_path":"%s"}' \
  "$FIX/session-cli.transcript.jsonl" | XDG_CONFIG_HOME="$sb/config" XDG_STATE_HOME="$sb/state" "$PY" "$HOOK" >/dev/null 2>&1
mj="$sb/state/khub-telemetry/metrics/F5.json"
if [ -f "$mj" ] && [ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["setup"]["harness"])' "$mj" 2>/dev/null)" = "claudekit" ]; then
  _ok "join: metrics record carries its session's setup fingerprint"
else _no "join: fingerprint not embedded in metrics"; fi
# and the metrics record still leaks no raw skill name / path
if ! grep -qF "acme-billing-reconciler" "$mj" && ! grep -qF "$ck" "$mj"; then
  _ok "join: merged setup still leaks no raw identifiers"
else _no "join: merged setup leaked raw identifiers"; fi
rm -rf "$ck"

# 6. fail-open: SessionStart with no cwd / gated-off -> exit 0, no crash
sb="$(sandbox)"; enable_cfg "$sb"
printf '{"hook_event_name":"SessionStart","session_id":"F6"}' | XDG_CONFIG_HOME="$sb/config" XDG_STATE_HOME="$sb/state" "$PY" "$HOOK"; rc=$?
if [ "$rc" -eq 0 ]; then _ok "fail-open: SessionStart without cwd exits 0"; else _no "fail-open: crashed (rc=$rc)"; fi
sb2="$(sandbox)"   # gated off (no config)
printf '{"hook_event_name":"SessionStart","session_id":"F7","cwd":"/tmp"}' | XDG_CONFIG_HOME="$sb2/config" XDG_STATE_HOME="$sb2/state" "$PY" "$HOOK"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$(fp_json "$sb2" F7)" ]; then _ok "fail-open: gated-off writes no fingerprint, exit 0"; else _no "fail-open: gated fingerprint wrong (rc=$rc)"; fi
rm -rf "$sb" "$sb2"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
