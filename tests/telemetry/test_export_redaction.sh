#!/usr/bin/env bash
# Tests for lib/telemetry/export_redact.py — the export bundler + redactor. Proves the
# default bundle is grep-proof (no raw text / $HOME / login / secret / mcp name / raw
# repo id), that opt-in snippets are scrubbed, and that the EXTERNAL cohort is
# hard-blocked without a DPA token. Uses the REAL $HOME so a client-home shape
# can't slip through just because CI's $HOME differs.
#
# NOTE: -e intentionally OFF.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
EXPORT="$repo_root/lib/telemetry/export_redact.py"
PY="$(command -v python3 || true)"

pass=0; fail=0
_ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
_no() { printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
[ -n "$PY" ] || { echo "python3 required"; exit 1; }

SALT="deadbeefdeadbeefdeadbeefdeadbeef"
LOGIN="khanhtestlogin"

# build a state dir with one metrics record (mcp tool + branch label + salted setup)
# and one raw capture turn carrying planted secrets incl. the REAL $HOME.
mk_state() {
  local sd; sd="$(mktemp -d "${TMPDIR:-/tmp}/khub-exp.XXXXXX")"
  mkdir -p "$sd/metrics" "$sd/capture"
  cat > "$sd/metrics/s1.json" <<JSON
{"schema_version":1,"session_id":"s1","entrypoint":"cli","duration_seconds":120,
 "prompts":3,"turns":3,"model":"claude-opus-4-8","tool_calls_total":5,
 "tool_calls":{"Bash":3,"mcp__plugin_acme_billing":2},
 "tokens":{"input":700,"output":350,"cache_read":70,"cache_creation":35},
 "edits":{"total":0,"distinct_files":0,"reworked_files":0},
 "error_retries":0,"subagents":{"total":0,"types":{}},"slash_commands":0,
 "user_corrections":0,"task":"feat/secret-branch",
 "tokens_by_task":{"feat/secret-branch":{"output":350,"input":700,"cache_read":70,"cache_creation":35}},
 "setup":{"harness":"claudekit","repo_id":"0a4b904e2855efe8","skills_hash":"11c5e9277b45","cohort":"unset"}}
JSON
  # raw capture turn with planted secrets: gh token, email, sk- key, real $HOME, a
  # foreign client-home shape, and a URL credential.
  "$PY" - "$sd/capture/s1.jsonl" "$HOME" <<'PY'
import json, sys
path, home = sys.argv[1], sys.argv[2]
# Assemble the FAKE secrets at runtime from split parts so no complete secret literal
# is committed (GitHub push-protection would block it) — the redactor still sees the
# full string. These are synthetic test data, not real credentials.
J = lambda *p: "".join(p)
ghp   = J("gh", "p_", "ABCDEFGHIJKLMNOPQRSTUVWX")
slack = J("xox", "b-", "1111111111-222222222222-abcdefghijklmnop")
skp   = J("sk-", "proj-", "ABCDEFGHIJKLMNOPQRSTUVWX")
gpat  = J("github", "_pat_", "ABCDEFGHIJKLMNOPQRST1234")
goog  = J("AI", "za", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
pem   = J("-----BEGIN ", "RSA PRIVATE KEY-----\n", "MIIEpemBODYSECRET1234567890\n", "-----END ", "RSA PRIVATE KEY-----")
turn = {
  "ts": "2026-07-11T00:00:00Z",
  "prompt": "deploy %s, email bob@acme.com, slack %s" % (ghp, slack),
  "response": ("wrote " + home + "/secret.py and /Users/alice/clientwork/app.py; "
               "openai %s; github %s; google %s; url https://user:pass@git.acme.com/r; %s"
               % (skp, gpat, goog, pem)),
  "tools": ["Bash", "mcp__acme_secret_server"],
}
open(path, "w").write(json.dumps(turn) + "\n")
PY
  printf '%s' "$sd"
}
run() { "$PY" "$EXPORT" "$@"; }

# ---------------------------------------------------------------------------
# 1. default (internal) export: metrics.ndjson + manifest, NO snippets, grep-proof
sd="$(mk_state)"; out="$sd/export"
run --state "$sd" --out "$out" --cohort internal --salt "$SALT" --home "$HOME" --login "$LOGIN"; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$out/metrics.ndjson" ] && [ -f "$out/manifest.json" ] && [ ! -f "$out/snippets.redacted.ndjson" ]; then
  leak=0
  for n in "mcp__plugin_acme_billing" "$HOME" "sk-ABCDEFG" "ghp_ABCDEFG" "bob@acme.com" "/Users/alice"; do
    grep -qF "$n" "$out/metrics.ndjson" && { leak=1; echo "       leaked in metrics: $n"; }
  done
  grep -q 'mcp:' "$out/metrics.ndjson" || { leak=1; echo "       mcp tool not hashed to mcp:"; }
  if [ "$leak" -eq 0 ]; then _ok "default export: metrics-only, mcp name hashed, grep-proof (no secret/HOME/name)"
  else _no "default export: leaked"; fi
else _no "default export: wrong bundle shape (rc=$rc)"; fi
rm -rf "$sd"

# 2. --with-snippets: snippets file exists and planted secrets are ALL redacted
sd="$(mk_state)"; out="$sd/export"
run --state "$sd" --out "$out" --cohort internal --salt "$SALT" --home "$HOME" --login "$LOGIN" --with-snippets >/dev/null 2>&1
snip="$out/snippets.redacted.ndjson"
if [ -f "$snip" ]; then
  leak=0
  for n in "ghp_ABCDEFG" "bob@acme.com" "sk-proj-ABC" "github_pat_ABC" "xoxb-1111" "AIzaABC" \
           "$HOME" "/Users/alice" "user:pass@" "MIIEpemBODYSECRET" "mcp__acme_secret_server"; do
    grep -qF "$n" "$snip" && { leak=1; echo "       leaked in snippets: $n"; }
  done
  # and the redaction markers are present (proves scrub ran, not just dropped text)
  grep -q '<redacted:gh-token>' "$snip" && grep -q '<redacted:email>' "$snip" || leak=1
  if [ "$leak" -eq 0 ]; then _ok "snippets: gh/openai(sk-proj)/github-pat/slack/google/PEM-body/url/HOME/mcp-name all redacted"
  else _no "snippets: a planted secret survived"; fi
else _no "snippets: file not produced"; fi
rm -rf "$sd"

# 3. external cohort WITHOUT a DPA token -> hard-blocked (exit 6, no bundle)
sd="$(mk_state)"; out="$sd/export"
err="$(run --state "$sd" --out "$out" --cohort external --salt "$SALT" --home "$HOME" 2>&1)"; rc=$?
if [ "$rc" -eq 6 ] && [ ! -f "$out/metrics.ndjson" ] && printf '%s' "$err" | grep -qi 'DPA'; then
  _ok "external: hard-blocked without a DPA token (exit 6, nothing written)"
else _no "external: not blocked (rc=$rc)" "$err"; fi
rm -rf "$sd"

# 4. external WITH a DPA token -> allowed; task/branch labels are hashed
sd="$(mk_state)"; out="$sd/export"; tok="$sd/dpa.token"; printf 'org-consent\n' > "$tok"
run --state "$sd" --out "$out" --cohort external --dpa-token "$tok" --salt "$SALT" --home "$HOME" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$out/metrics.ndjson" ] \
   && ! grep -qF "feat/secret-branch" "$out/metrics.ndjson" && grep -q 'task:' "$out/metrics.ndjson"; then
  _ok "external+token: allowed; task/branch labels hashed (raw branch absent)"
else _no "external+token: label not hashed or blocked (rc=$rc)"; fi
rm -rf "$sd"

# 5. manifest records the consent + session count
sd="$(mk_state)"; out="$sd/export"
run --state "$sd" --out "$out" --cohort internal --salt "$SALT" --home "$HOME" >/dev/null 2>&1
if "$PY" -c 'import json,sys;m=json.load(open(sys.argv[1]));sys.exit(0 if m["session_count"]==1 and m["cohort"]=="internal" and m["consent"]["opt_in"] else 1)' "$out/manifest.json"; then
  _ok "manifest: records session count + cohort + consent"
else _no "manifest: wrong contents"; fi
rm -rf "$sd"

# 6. KEY-POSITION leaks: a secret/path in a dict KEY (tool name), or client identity
#    in a subagent-type name, must not pass through verbatim.
sd="$(mktemp -d "${TMPDIR:-/tmp}/khub-exp.XXXXXX")"; mkdir -p "$sd/metrics"; tok="$sd/tok"; printf 'x\n' > "$tok"
cat > "$sd/metrics/k1.json" <<JSON
{"schema_version":1,"session_id":"k1","prompts":1,"turns":1,"tool_calls_total":1,
 "tool_calls":{"wt_/Users/alice/clientwork":1,"Bash":2},
 "subagents":{"total":1,"types":{"acme-billing-migration":1}},
 "tokens":{"input":1,"output":1,"cache_read":0,"cache_creation":0},
 "task":"feat/x","tokens_by_task":{"feat/x":{"output":1,"input":1}},
 "setup":{"harness":"vanilla"}}
JSON
kk=1
# internal: a PATH in a key is scrubbed (Bash stays readable)
run --state "$sd" --out "$sd/ei" --cohort internal --salt "$SALT" --home "$HOME" >/dev/null 2>&1
grep -qF "/Users/alice" "$sd/ei/metrics.ndjson" && { kk=0; echo "       internal leaked /Users/alice in a tool-name key"; }
grep -q '"Bash"' "$sd/ei/metrics.ndjson" || { kk=0; echo "       internal dropped the generic Bash key"; }
# external: client identity in subagent/tool names is hashed; path still scrubbed
run --state "$sd" --out "$sd/ee" --cohort external --dpa-token "$tok" --salt "$SALT" --home "$HOME" >/dev/null 2>&1
for n in "acme-billing-migration" "/Users/alice"; do
  grep -qF "$n" "$sd/ee/metrics.ndjson" && { kk=0; echo "       external leaked in a key: $n"; }
done
if [ "$kk" -eq 1 ]; then _ok "keys: path-in-key scrubbed (both cohorts); external hashes subagent/tool identity"
else _no "keys: a key-position leak survived"; fi
rm -rf "$sd"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
