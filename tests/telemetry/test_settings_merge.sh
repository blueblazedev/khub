#!/usr/bin/env bash
# Characterization tests for lib/telemetry/settings_merge.py — the settings.json
# merge/unmerge/status helper that `khub track` drives. Every case asserts EXACT
# merge + NON-destruction across the config states khub must survive in the wild.
#
# khub's own entries are identified by the stable hook-path token in their command
# (schema-clean — the settings schema forbids extra keys in a hook-matcher object),
# so the tests assert on that, not on any marker key.
#
# Tests-first origin: authored red before the helper existed, then greened.
# NOTE: -e is intentionally OFF — several cases assert on non-zero exits.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
MERGE="$repo_root/lib/telemetry/settings_merge.py"
FIX="$here/fixtures"
PY="$(command -v python3 || true)"

# A representative registered command: absolute interpreter + hook path (which carries
# the khub identity token), guarded `|| exit 0` (the shape khub writes).
CMD="/usr/bin/python3 /home/tester/.local/share/khub-telemetry/capture_hook.py || exit 0"

pass=0; fail=0
_ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
_no() { printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }

work() { mktemp -d "${TMPDIR:-/tmp}/khub-merge.XXXXXX"; }
run()  { "$PY" "$MERGE" "$@"; }

# assert a python boolean expression over the parsed settings file `d`
pyq() { # <file> <expr>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if (eval(sys.argv[2])) else 1)' "$1" "$2" >/dev/null 2>&1
}
# count of khub entries (command contains the token) in an event array
khub_count() { # <file> <event>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1])); tok="khub-telemetry/capture_hook.py"
arr=d.get("hooks",{}).get(sys.argv[2],[])
def isk(e): return isinstance(e,dict) and any(tok in (h.get("command","") if isinstance(h,dict) else "") for h in e.get("hooks",[]) )
print(sum(1 for e in arr if isk(e)))' "$1" "$2"
}
# assert the file, after stripping khub entries, deep-equals the original (proves
# enable is PURELY ADDITIVE / disable is a clean inverse). orig '-' means "was {}".
addl_only() { # <orig-or-dash> <result>
  "$PY" -c 'import json,sys
tok="khub-telemetry/capture_hook.py"
orig = {} if sys.argv[1]=="-" else json.load(open(sys.argv[1]))
res  = json.load(open(sys.argv[2]))
def isk(e): return isinstance(e,dict) and any(tok in (h.get("command","") if isinstance(h,dict) else "") for h in e.get("hooks",[]))
def strip(cfg):
    cfg=json.loads(json.dumps(cfg)); h=cfg.get("hooks")
    if isinstance(h,dict):
        for ev in list(h.keys()):
            if isinstance(h[ev],list): h[ev]=[e for e in h[ev] if not isk(e)]
    return cfg
s=strip(res)
oh=orig.get("hooks",{}) if isinstance(orig,dict) else {}
sh=s.get("hooks",{})
if isinstance(sh,dict):
    for ev in list(sh.keys()):
        if sh[ev]==[] and ev not in oh: del sh[ev]
    if s.get("hooks")=={} and "hooks" not in orig: del s["hooks"]
sys.exit(0 if s==orig else 1)' "$1" "$2" >/dev/null 2>&1
}
sha_of() { "$PY" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
mode_of() { "$PY" -c 'import os,stat,sys;print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[-3:])' "$1"; }

[ -n "$PY" ] || { echo "python3 required to run these tests"; exit 1; }

# ---------------------------------------------------------------------------
# 1. absent file -> enable creates it with ONLY khub's block, no extra keys
w="$(work)"; s="$w/settings.json"
run enable "$s" --command "$CMD" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$s" ] \
   && [ "$(khub_count "$s" SessionStart)" = "1" ] && [ "$(khub_count "$s" SessionEnd)" = "1" ] \
   && pyq "$s" 'set(d["hooks"]["SessionStart"][0].keys())=={"hooks"}' \
   && pyq "$s" 'd["hooks"]["SessionStart"][0]["hooks"][0]["command"].endswith("capture_hook.py || exit 0")'; then
  _ok "absent: creates file with one khub block per event, schema-clean (no extra keys)"
else _no "absent: enable did not create a clean file (rc=$rc)"; fi
rm -rf "$w"

# 2. empty {} -> enable adds hooks with khub's block
w="$(work)"; s="$w/settings.json"; printf '{}\n' > "$s"
run enable "$s" --command "$CMD" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && pyq "$s" '"SessionStart" in d["hooks"] and "SessionEnd" in d["hooks"]'; then
  _ok "empty {}: adds hooks with khub blocks"
else _no "empty {}: khub blocks not added"; fi
rm -rf "$w"

# 3. existing non-khub hooks -> enable is additive, existing intact; disable inverse
w="$(work)"; s="$w/settings.json"; cp "$FIX/existing-claudekit.settings.json" "$s"
orig="$w/orig.json"; cp "$s" "$orig"
run enable "$s" --command "$CMD" >/dev/null 2>&1; rc=$?
add_ok=1
addl_only "$orig" "$s" || add_ok=0
pyq "$s" 'len(d["hooks"]["SessionStart"])==2' || add_ok=0
pyq "$s" 'any(e.get("hooks",[{}])[0].get("command","").endswith("session-start.cjs") for e in d["hooks"]["SessionStart"])' || add_ok=0
pyq "$s" 'd["hooks"]["PreToolUse"][0]["matcher"]=="Bash"' || add_ok=0
pyq "$s" 'd["model"]=="claude-opus-4-8" and d["permissions"]["allow"]==["Bash(git:*)"]' || add_ok=0
if [ "$rc" -eq 0 ] && [ "$add_ok" -eq 1 ]; then _ok "existing: enable additive, existing entries preserved"
else _no "existing: enable altered or dropped non-khub state"; fi
run disable "$s" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && addl_only "$orig" "$s" && [ "$(khub_count "$s" SessionStart)" = "0" ]; then
  _ok "existing: disable removes only khub's, original intact"
else _no "existing: disable damaged non-khub state"; fi
rm -rf "$w"

# 4. already-installed -> enable idempotent; status=present/no-drift
w="$(work)"; s="$w/settings.json"; printf '{}\n' > "$s"
run enable "$s" --command "$CMD" >/dev/null 2>&1
run enable "$s" --command "$CMD" >/dev/null 2>&1
if [ "$(khub_count "$s" SessionStart)" = "1" ] && [ "$(khub_count "$s" SessionEnd)" = "1" ]; then
  _ok "idempotent: N enables => exactly one khub block per event"
else _no "idempotent: duplicate khub blocks after re-enable"; fi
st="$(run status "$s" --command "$CMD" 2>/dev/null)"
case "$st" in *start=present*end=present*drift=none*) _ok "status: registered + no drift" ;;
  *) _no "status: expected present/present/none" "got: $st" ;; esac
rm -rf "$w"

# 4b. enable -> disable -> enable round-trip returns to exactly one block per event
w="$(work)"; s="$w/settings.json"; cp "$FIX/existing-claudekit.settings.json" "$s"
orig="$w/orig.json"; cp "$s" "$orig"
run enable  "$s" --command "$CMD" >/dev/null 2>&1
run disable "$s" >/dev/null 2>&1
run enable  "$s" --command "$CMD" >/dev/null 2>&1
if [ "$(khub_count "$s" SessionStart)" = "1" ] && [ "$(khub_count "$s" SessionEnd)" = "1" ] && addl_only "$orig" "$s"; then
  _ok "round-trip: enable->disable->enable => one block/event, non-khub intact"
else _no "round-trip: state drifted after enable/disable/enable"; fi
rm -rf "$w"

# 5. malformed JSON -> enable fails closed (no write, clear error, original untouched)
w="$(work)"; s="$w/settings.json"; printf '{ this is : not json ' > "$s"
before="$(sha_of "$s")"
err="$(run enable "$s" --command "$CMD" 2>&1 >/dev/null)"; rc=$?
after="$(sha_of "$s")"
if [ "$rc" -ne 0 ] && [ "$before" = "$after" ] && [ -n "$err" ]; then
  _ok "malformed: enable fails closed, original byte-identical, error emitted"
else _no "malformed: mutated or exited 0 (rc=$rc)"; fi
rm -rf "$w"

# 6a. drift (entry missing) -> status=drift; repair (re-enable) re-adds
w="$(work)"; s="$w/settings.json"; printf '{}\n' > "$s"
run enable "$s" --command "$CMD" >/dev/null 2>&1
"$PY" -c 'import json,sys
d=json.load(open(sys.argv[1])); d["hooks"]["SessionEnd"]=[]
json.dump(d,open(sys.argv[1],"w"))' "$s"
st="$(run status "$s" --command "$CMD" 2>/dev/null)"
case "$st" in *end=missing*drift=yes*) _ok "drift: missing entry reported as drift" ;;
  *) _no "drift: expected end=missing drift=yes" "got: $st" ;; esac
run enable "$s" --command "$CMD" >/dev/null 2>&1
st2="$(run status "$s" --command "$CMD" 2>/dev/null)"
case "$st2" in *end=present*drift=none*) _ok "repair: re-enable restores the missing entry" ;;
  *) _no "repair: entry not restored" "got: $st2" ;; esac
rm -rf "$w"

# 6b. drift (command mismatch) -> status=drift
w="$(work)"; s="$w/settings.json"; printf '{}\n' > "$s"
run enable "$s" --command "$CMD" >/dev/null 2>&1
"$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
d["hooks"]["SessionStart"][0]["hooks"][0]["command"]="/usr/bin/python3 /elsewhere/khub-telemetry/capture_hook.py || exit 0"
json.dump(d,open(sys.argv[1],"w"))' "$s"
st="$(run status "$s" --command "$CMD" 2>/dev/null)"
case "$st" in *drift=yes*) _ok "drift: command mismatch reported as drift" ;;
  *) _no "drift: mismatched command not flagged" "got: $st" ;; esac
rm -rf "$w"

# 7. backup -> a 0600 settings.json.khub-bak-* exists after mutating an existing file
w="$(work)"; s="$w/settings.json"; cp "$FIX/existing-claudekit.settings.json" "$s"
run enable "$s" --command "$CMD" >/dev/null 2>&1
set -- "$s".khub-bak-*
if [ -e "$1" ]; then _ok "backup: settings.json.khub-bak-* written"
else _no "backup: no backup file after enable"; fi
bak=""; [ -e "$1" ] && bak="$1"
if [ -n "$bak" ]; then
  case "$(mode_of "$bak")" in 600) _ok "backup: mode is 0600" ;; *) _no "backup: mode not 0600" "got: $(mode_of "$bak")" ;; esac
fi
rm -rf "$w"

# 7b. backup hygiene -> never keeps more than 2 (older ones pruned)
w="$(work)"; s="$w/settings.json"; printf '{}\n' > "$s"
run enable "$s" --command "$CMD" >/dev/null 2>&1   # creates the file; no backup (was empty->first write path)
printf '{"model":"x"}\n' > "$s"
# plant three OLD backups, then a mutation must prune to <=2
: > "$s.khub-bak-100"; : > "$s.khub-bak-200"; : > "$s.khub-bak-300"
run enable "$s" --command "$CMD" >/dev/null 2>&1
n=0; for f in "$s".khub-bak-*; do [ -e "$f" ] && n=$((n+1)); done
if [ "$n" -le 2 ]; then _ok "backup hygiene: pruned to at most 2 backups (found $n)"
else _no "backup hygiene: too many backups kept" "found $n"; fi
rm -rf "$w"

# 9. mode preservation -> a 0600 settings.json stays 0600; a 0644 stays 0644
w="$(work)"; s="$w/settings.json"; printf '{}\n' > "$s"; chmod 600 "$s"
run enable "$s" --command "$CMD" >/dev/null 2>&1
case "$(mode_of "$s")" in 600) _ok "mode: 0600 preserved across enable" ;; *) _no "mode: widened from 0600" "got: $(mode_of "$s")" ;; esac
printf '{}\n' > "$s"; chmod 644 "$s"
run enable "$s" --command "$CMD" >/dev/null 2>&1
case "$(mode_of "$s")" in 644) _ok "mode: 0644 preserved across enable" ;; *) _no "mode: changed from 0644" "got: $(mode_of "$s")" ;; esac
rm -rf "$w"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
