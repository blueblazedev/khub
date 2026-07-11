#!/usr/bin/env bash
# Tests for the opt-in debug log + `khub track doctor` — the only visibility into an
# otherwise-silent fail-open hook, and a redacted, paste-ready diagnostic. Asserts the
# log records outcomes (never raw content), is off by default, and that doctor's output
# is redacted ($HOME->~) and leaks no skill name / cwd path.
#
# NOTE: -e intentionally OFF.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
KHUB="$repo_root/khub"
HOOK="$repo_root/lib/telemetry/capture_hook.py"
FIX="$here/fixtures"
BASH_BIN="$(command -v bash || echo /bin/bash)"
PY="$(command -v python3 || true)"

pass=0; fail=0
_ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
_no() { printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
[ -n "$PY" ] || { echo "python3 required"; exit 1; }

sb="$(mktemp -d "${TMPDIR:-/tmp}/khub-dbg.XXXXXX")"
run_khub() { NO_COLOR=1 HOME="$sb/home" XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" \
  XDG_STATE_HOME="$sb/state" KHUB_LIB_DIR="$repo_root/lib" "$BASH_BIN" "$KHUB" "$@"; }
fire() { printf '%s' "$1" | XDG_CONFIG_HOME="$sb/config" XDG_STATE_HOME="$sb/state" "$PY" "$HOOK"; }
dbglog="$sb/state/khub-telemetry/debug.log"

# a ClaudeKit project with a client-identifying skill name we must NEVER see logged
ck="$(mktemp -d "${TMPDIR:-/tmp}/ck.XXXXXX")"; mkdir -p "$ck/.claude/rules" "$ck/.claude/skills/acme-secret-skill"

run_khub track enable >/dev/null 2>&1

# 1. debug OFF by default -> firing writes no debug log
fire "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"off1\",\"transcript_path\":\"$FIX/session-cli.transcript.jsonl\"}"
if [ ! -f "$dbglog" ]; then _ok "debug: OFF by default — no debug log written"
else _no "debug: log written while debug off"; fi

# 2. debug ON -> outcomes recorded (ok / dropped-sdk / gated-off)
run_khub track debug on >/dev/null 2>&1
fire "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"dbgABCDE\",\"cwd\":\"$ck\",\"entrypoint\":\"cli\"}"
fire "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"dbgABCDE\",\"transcript_path\":\"$FIX/session-cli.transcript.jsonl\"}"
fire "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"sdkX\",\"transcript_path\":\"$FIX/session-sdk.transcript.jsonl\"}"
if [ -f "$dbglog" ] && grep -q 'SessionStart dbgABCDE ok' "$dbglog" \
   && grep -q 'SessionEnd .* ok .*prompts=3' "$dbglog" && grep -q 'dropped-sdk' "$dbglog"; then
  _ok "debug: ON — records SessionStart/SessionEnd ok + dropped-sdk outcomes"
else _no "debug: outcomes missing" "$(cat "$dbglog" 2>/dev/null)"; fi

# 3. the debug log leaks NO raw content (skill name, cwd path, prompt text)
leak=0
for n in "acme-secret-skill" "$ck" "how do I add a hook" "/repo/"; do grep -qF "$n" "$dbglog" && { leak=1; echo "       leaked: $n"; }; done
if [ "$leak" -eq 0 ]; then _ok "debug: log is redacted by construction (no names/paths/prompts)"
else _no "debug: log leaked raw content"; fi

# 4. gated-off is visible in the log (debug on, telemetry flag flipped off).
#    Back up + restore the FULL config so the doctor test below still sees it.
cp "$sb/config/khub/telemetry.conf" "$sb/config/khub/telemetry.conf.keep"
printf 'enabled=0\n' > "$sb/config/khub/telemetry.conf"
fire "{\"hook_event_name\":\"SessionEnd\",\"session_id\":\"gate1\",\"transcript_path\":\"$FIX/session-cli.transcript.jsonl\"}"
if grep -q 'gate1 .*gated-off' "$dbglog"; then _ok "debug: gated-off state is logged (diagnoses 'enabled but silent')"
else _no "debug: gated-off not logged"; fi
mv "$sb/config/khub/telemetry.conf.keep" "$sb/config/khub/telemetry.conf"

# 5. `khub track doctor` -> redacted, paste-ready, no leak
out="$(run_khub track doctor 2>&1)"
red_ok=1
printf '%s' "$out" | grep -q 'telemetry doctor' || red_ok=0
printf '%s' "$out" | grep -q 'registration:' || red_ok=0
printf '%s' "$out" | grep -q 'hook integrity: ok' || red_ok=0
printf '%s' "$out" | grep -q '[~]/.claude/settings.json' || red_ok=0   # $HOME collapsed to ~
printf '%s' "$out" | grep -qF "$ck" && red_ok=0                        # no cwd path
printf '%s' "$out" | grep -qF "acme-secret-skill" && red_ok=0         # no skill name
printf '%s' "$out" | grep -qF "$sb/home" && red_ok=0                   # no real HOME
if [ "$red_ok" -eq 1 ]; then _ok "doctor: redacted diagnostic, registration + integrity + store, no leak"
else _no "doctor: missing content or leaked a path/name" "$out"; fi

# 6. doctor is safe when telemetry was never configured
sb2="$(mktemp -d "${TMPDIR:-/tmp}/khub-dbg2.XXXXXX")"
out2="$(NO_COLOR=1 HOME="$sb2/home" XDG_CONFIG_HOME="$sb2/config" XDG_DATA_HOME="$sb2/data" XDG_STATE_HOME="$sb2/state" KHUB_LIB_DIR="$repo_root/lib" "$BASH_BIN" "$KHUB" track doctor 2>&1)"
if printf '%s' "$out2" | grep -q 'enabled: NO'; then _ok "doctor: clean output when never configured"
else _no "doctor: mishandled unconfigured state" "$out2"; fi
rm -rf "$sb2"

rm -rf "$sb" "$ck"
# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
