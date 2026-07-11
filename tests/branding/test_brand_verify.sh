#!/usr/bin/env bash
# Tests for scripts/brand-verify.sh — the branded-tree verification harness.
#
# TDD contract: the harness must be proven able to FAIL before it is trusted.
# Cases: (1) planted leaks/corruption/mode-loss/toolchain-leak each fail loudly
# with the right gate name, (2) a fresh compile passes end-to-end, (3) an
# installer tampered back to the anonymous channel fails the channel gate,
# (4) a corrupted repo composition fails the upgrade smoke (the exact class the
# 67 engine tests can never see), (5) an installer with verification weakened
# fails the channel gate — written BEFORE the private-channel rework so the
# rewrite cannot silently drop the fail-closed contract.
#
# NOTE: -e intentionally OFF.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
COMPILE="$repo_root/scripts/brand-compile.py"
VERIFY="$repo_root/scripts/brand-verify.sh"
CONF="$here/fixtures/epsilon-hub.conf"
KEY="$here/fixtures/hmac-test-key.txt"
PY="$(command -v python3 || true)"

pass=0; fail=0
_ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
_no() { printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
[ -n "$PY" ] || { echo "python3 required"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/brand-verify-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

base="$work/base"
if ! "$PY" "$COMPILE" "$CONF" "$base" --source "$repo_root" --hmac-key-file "$KEY" >/dev/null 2>&1; then
  echo "cannot compile the fixture tree — run tests/branding/test_brand_compile.sh first"; exit 1
fi

# tree copy preserving modes; tampered per case
clone_tree() { local d="$work/$1"; rm -rf "$d"; cp -Rp "$base" "$d"; printf '%s' "$d"; }
# run the verifier, capturing output; echoes rc
run_verify() { bash "$VERIFY" "$1" >"$work/verify.log" 2>&1; echo $?; }
gate_named() { grep -q "FAIL \[$1\]" "$work/verify.log"; }

# ---- 1a. planted identity leak -> zerogrep ------------------------------------
t="$(clone_tree t-leak)"
printf '# khub leftover\n' >> "$t/README.md"
rc="$(run_verify "$t")"
if [ "$rc" -ne 0 ] && gate_named zerogrep; then
  _ok "harness fails a planted khub string, naming gate zerogrep"
else
  _no "planted identity leak not caught (rc=$rc)" "$(tail -3 "$work/verify.log" 2>/dev/null)"
fi

# ---- 1b. hyphen-corrupted identifier -> pycompile ------------------------------
t="$(clone_tree t-ident)"
sed -i '' 's/def is_epsilon_hub_entry/def is_epsilon-hub_entry/' "$t/lib/telemetry/settings_merge.py" 2>/dev/null \
  || sed -i 's/def is_epsilon_hub_entry/def is_epsilon-hub_entry/' "$t/lib/telemetry/settings_merge.py"
rc="$(run_verify "$t")"
if [ "$rc" -ne 0 ] && gate_named pycompile; then
  _ok "harness fails a hyphen-corrupted python identifier, naming gate pycompile"
else
  _no "identifier corruption not caught (rc=$rc)" "$(tail -3 "$work/verify.log" 2>/dev/null)"
fi

# ---- 1c. stripped exec bit -> modebits ------------------------------------------
t="$(clone_tree t-mode)"
chmod -x "$t/epsilon-hub"
rc="$(run_verify "$t")"
if [ "$rc" -ne 0 ] && gate_named modebits; then
  _ok "harness fails a stripped executable bit, naming gate modebits"
else
  _no "mode-bit loss not caught (rc=$rc)" "$(tail -3 "$work/verify.log" 2>/dev/null)"
fi

# ---- 1d. leftover branding toolchain -> exclusion --------------------------------
t="$(clone_tree t-excl)"
mkdir -p "$t/tests/branding"
printf ': leftover\n' > "$t/tests/branding/leftover.sh"
rc="$(run_verify "$t")"
if [ "$rc" -ne 0 ] && gate_named exclusion; then
  _ok "harness fails a leaked tests/branding/ file, naming gate exclusion"
else
  _no "toolchain leak not caught (rc=$rc)" "$(tail -3 "$work/verify.log" 2>/dev/null)"
fi

# ---- 2. clean tree passes end-to-end ----------------------------------------------
rc="$(run_verify "$base")"
if [ "$rc" -eq 0 ]; then
  _ok "clean compile passes the full gate stack (suites + smoke + channel)"
else
  _no "clean tree failed verification (rc=$rc)" "$(tail -6 "$work/verify.log" 2>/dev/null)"
fi

# ---- 3. installer tampered to the anonymous channel -> channel -------------------
t="$(clone_tree t-anon)"
sed -i '' 's/^RELEASE_CHANNEL="gh"/RELEASE_CHANNEL="anonymous"/' "$t/install.sh" 2>/dev/null \
  || sed -i 's/^RELEASE_CHANNEL="gh"/RELEASE_CHANNEL="anonymous"/' "$t/install.sh"
rc="$(run_verify "$t")"
if [ "$rc" -ne 0 ] && gate_named channel; then
  _ok "harness fails an installer flipped to anonymous curl, naming gate channel"
else
  _no "anonymous-channel tamper not caught (rc=$rc)" "$(tail -3 "$work/verify.log" 2>/dev/null)"
fi

# ---- 4. corrupted repo composition -> smoke-upgrade -------------------------------
t="$(clone_tree t-repo)"
# shellcheck disable=SC2016  # ${ORG} is a literal token in the tree, not for expansion here
sed -i '' 's|_REPO="${ORG}/epsilon-hub-cli"|_REPO="${ORG}/wrong-repo"|' "$t/epsilon-hub" 2>/dev/null \
  || sed -i 's|_REPO="${ORG}/epsilon-hub-cli"|_REPO="${ORG}/wrong-repo"|' "$t/epsilon-hub"
rc="$(run_verify "$t")"
if [ "$rc" -ne 0 ] && gate_named smoke-upgrade; then
  _ok "harness fails a corrupted branded-repo composition, naming gate smoke-upgrade"
else
  _no "branded-URL breakage not caught (rc=$rc)" "$(tail -3 "$work/verify.log" 2>/dev/null)"
fi

# ---- 5. weakened installer verification -> channel (fail-closed, red-first) -------
t="$(clone_tree t-weak)"
sed -i '' 's/_SKIP_VERIFY:-}/_SKIP_VERIFY:-1}/' "$t/install.sh" 2>/dev/null \
  || sed -i 's/_SKIP_VERIFY:-}/_SKIP_VERIFY:-1}/' "$t/install.sh"
rc="$(run_verify "$t")"
if [ "$rc" -ne 0 ] && gate_named channel; then
  _ok "harness fails an installer that skips verification, naming gate channel"
else
  _no "weakened fail-closed contract not caught (rc=$rc)" "$(tail -3 "$work/verify.log" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
