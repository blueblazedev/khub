#!/usr/bin/env bash
# brand-verify — prove a compiled branded tree BEHAVES, not just reads clean.
#
#   scripts/brand-verify.sh <branded-tree>
#
# Runs the full gate stack inside the tree, in order: identity zero-grep
# (contents + filenames) -> bash -n -> shellcheck (where available) ->
# py_compile -> mode bits -> embedded-helpers drift check -> every telemetry
# suite -> smoke tests for the verbs branding rewrites (version / doctor /
# init / upgrade --check against a local file:// API fixture) -> private-channel
# behavior (the branded installer downloads through an AUTHENTICATED gh and
# still fails closed on checksum mismatch / missing SHA256SUMS / mixed-tag
# fixtures) -> reference consistency -> branding-toolchain exclusion.
#
# Self-contained: needs only the tree, bash, python3, git — no engine access.
# Any miss exits non-zero naming its gate:  brand-verify: FAIL [gate] ...
# The CLI is detected as the single executable at the tree root, so a lost
# exec bit fails [modebits] before anything else can run.
#
# NOTE: -e intentionally OFF — every step's rc is handled explicitly.
set -uo pipefail

tree="${1:-}"
[ -n "$tree" ] && [ -d "$tree" ] || { echo "usage: brand-verify.sh <branded-tree>" >&2; exit 2; }
tree="$(cd "$tree" && pwd)"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "brand-verify: python3 is required" >&2; exit 2; }

ok()   { printf '  ok [%s] %s\n' "$1" "$2"; }
fail() { printf 'brand-verify: FAIL [%s] %s\n' "$1" "$2" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/brand-verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# ---- CLI detection (a lost exec bit must fail loudly, named) -------------------
cli=""
n_exec=0
for f in "$tree"/* "$tree"/.[!.]*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  n_exec=$((n_exec+1)); cli="$f"
done
[ "$n_exec" -eq 1 ] || fail modebits "expected exactly 1 executable at the tree root, found $n_exec (the CLI must keep 0755)"
slug="$(basename "$cli")"

# ---- gate: zerogrep -------------------------------------------------------------
leaks="$(grep -rniE 'khub|blueblazedev|knowledge-hub' "$tree" 2>/dev/null | head -5 || true)"
[ -z "$leaks" ] || fail zerogrep "identity residue in contents: $leaks"
# scan RELATIVE names — an identity string in the tree's own parent path (e.g.
# a checkout under .../khub-brands/) must not false-fail the filename gate
fleaks="$( (cd "$tree" && find . | grep -iE 'khub|blueblazedev|knowledge-hub') | head -5 || true)"
[ -z "$fleaks" ] || fail zerogrep "identity residue in filenames: $fleaks"
ok zerogrep "no khub/blueblazedev/knowledge-hub in contents or filenames"

# ---- gate: bashparse --------------------------------------------------------------
/bin/bash -n "$cli" 2>"$work/parse.err" || fail bashparse "$slug: $(head -1 "$work/parse.err")"
while IFS= read -r -d '' sh; do
  /bin/bash -n "$sh" 2>"$work/parse.err" || fail bashparse "$sh: $(head -1 "$work/parse.err")"
done < <(find "$tree" -name '*.sh' -print0)
ok bashparse "CLI + every .sh parses under /bin/bash -n"

# ---- gate: shellcheck (where available — the ubuntu CI leg provides coverage) ----
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2046  # the find output is a whitespace-safe repo file list
  if ! shellcheck "$cli" "$tree/install.sh" "$tree"/tests/telemetry/*.sh \
       "$tree/scripts/check-embedded-telemetry.sh" >"$work/sc.log" 2>&1; then
    fail shellcheck "$(head -3 "$work/sc.log")"
  fi
  ok shellcheck "static analysis clean"
else
  ok shellcheck "skipped (not installed here; the ubuntu CI leg covers it)"
fi

# ---- gate: pycompile ---------------------------------------------------------------
while IFS= read -r -d '' pyf; do
  "$PY" -m py_compile "$pyf" 2>"$work/py.err" || fail pycompile "$pyf: $(head -1 "$work/py.err")"
done < <(find "$tree" -name '*.py' -print0)
find "$tree" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
ok pycompile "every .py compiles (no hyphen-corrupted identifiers)"

# ---- gate: modebits ----------------------------------------------------------------
[ -x "$cli" ] || fail modebits "$slug lost its executable bit"
ok modebits "exactly one root executable ($slug, mode preserved)"

# ---- gate: embed -------------------------------------------------------------------
if ! (cd "$tree" && bash scripts/check-embedded-telemetry.sh) >"$work/embed.log" 2>&1; then
  fail embed "embedded helpers drift from lib/ inside the branded tree: $(tail -1 "$work/embed.log")"
fi
ok embed "embedded telemetry helpers in sync with lib/"

# ---- gate: suites (the tree's own tests run against the tree's own CLI) ------------
for t in "$tree"/tests/telemetry/test_*.sh; do
  [ -e "$t" ] || fail suites "no telemetry suites found in the tree"
  if ! bash "$t" >"$work/suite.log" 2>&1; then
    fail suites "$(basename "$t") failed: $(tail -3 "$work/suite.log")"
  fi
  ok suites "$(basename "$t"): $(tail -1 "$work/suite.log")"
done

# ---- smoke setup: sandboxed HOME/XDG + an offline file:// API fixture ---------------
sb="$work/sandbox"; mkdir -p "$sb/home" "$sb/cfg" "$sb/data" "$sb/state" "$sb/cache" "$sb/dir"
prefix="$(sed -n 's/^\([A-Z][A-Z0-9_]*\)_API_BASE=.*/\1/p' "$cli" | head -1)"
[ -n "$prefix" ] || fail smoke-version "cannot derive the env prefix from ${slug}'s API_BASE default"
version="$(sed -n "s/^${prefix}_VERSION=\"\(.*\)\"/\1/p" "$cli" | head -1)"
[ -n "$version" ] || fail smoke-version "cannot read ${prefix}_VERSION from $slug"
# repo identity: install.sh's REPO= is the independent truth the CLI must agree with
inst_repo="$(sed -n 's/^REPO="\(.*\)"/\1/p' "$tree/install.sh" | head -1)"
org_line="$(grep -m1 '^ORG=' "$cli" || true)"
repo_line="$(grep -m1 "^${prefix}_REPO=" "$cli" || true)"
# shellcheck disable=SC2016  # the $VAR must reach the inner bash unexpanded
cli_repo="$(bash -c "$(printf '%s\n%s\nprintf "%%s" "$%s_REPO"\n' "$org_line" "$repo_line" "$prefix")" 2>/dev/null || true)"
fix="$work/api"
mkdir -p "$fix/repos/${inst_repo}/releases"
printf '{"tag_name": "v%s"}\n' "$version" > "$fix/repos/${inst_repo}/releases/latest"
run_cli() {  # <args...> — sandboxed, offline API base
  env "HOME=$sb/home" "XDG_CONFIG_HOME=$sb/cfg" "XDG_DATA_HOME=$sb/data" \
      "XDG_STATE_HOME=$sb/state" "XDG_CACHE_HOME=$sb/cache" NO_COLOR=1 \
      "${prefix}_API_BASE=file://$fix" bash "$cli" "$@"
}

# ---- gate: smoke-version --------------------------------------------------------------
out="$(run_cli version 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "$slug $version"; } \
  || fail smoke-version "rc=$rc, output: $(printf '%s' "$out" | head -2)"
ok smoke-version "$slug $version runs"

# ---- gate: smoke-doctor (offline-tolerant: a failing CHECK is fine, a crash is not) ----
out="$(run_cli doctor 2>&1)"; rc=$?
[ "$rc" -le 1 ] || fail smoke-doctor "rc=$rc (crash, not a diagnosis): $(printf '%s' "$out" | tail -2)"
printf '%s' "$out" | grep -q "$slug doctor" || fail smoke-doctor "unbranded/missing doctor output"
printf '%s' "$out" | grep -qiE 'unbound variable|syntax error' && fail smoke-doctor "shell error in doctor output"
ok smoke-doctor "doctor runs end-to-end (rc=$rc)"

# ---- gate: smoke-init (offline-tolerant: a clean branded die counts) -------------------
out="$(run_cli init "$sb/dir" 2>&1)"; rc=$?
[ "$rc" -le 1 ] || fail smoke-init "rc=$rc (crash): $(printf '%s' "$out" | tail -2)"
printf '%s' "$out" | grep -qiE 'unbound variable|syntax error' && fail smoke-init "shell error in init output"
if [ "$rc" -eq 1 ]; then
  printf '%s' "$out" | grep -q 'error:' || fail smoke-init "died without a branded error message"
fi
ok smoke-init "init runs its preflight path cleanly (rc=$rc)"

# ---- gate: smoke-upgrade (local fixture via the API_BASE override) ---------------------
[ "$cli_repo" = "$inst_repo" ] \
  || fail smoke-upgrade "repo identity split-brain: CLI composes '$cli_repo' but install.sh pins '$inst_repo'"
out="$(run_cli upgrade --check 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "up to date"; } \
  || fail smoke-upgrade "upgrade --check against the local fixture broke (rc=$rc): $(printf '%s' "$out" | tail -2)"
ok smoke-upgrade "upgrade --check resolves the branded repo against a local fixture"

# ---- gate: channel (authenticated download + fail-closed contract) ---------------------
grep -q '^RELEASE_CHANNEL="gh"' "$tree/install.sh" \
  || fail channel "branded install.sh is not on the gh channel (anonymous curl for a private repo)"
grep -q '^RELEASE_CHANNEL="gh"' "$cli" \
  || fail channel "branded CLI is not on the gh channel"
grep -q 'gh release download' "$tree/install.sh" \
  || fail channel "branded install.sh has no authenticated download path"

stub="$work/stub"; ghfix="$work/ghfix/v9.9.9"; mkdir -p "$stub" "$ghfix"
cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
# gh stub for channel-behavior tests: serves fixture release assets, logs calls.
printf '%s\n' "$*" >> "$GH_STUB_LOG"
case "${1:-}:${2:-}" in
  auth:status) exit 0 ;;
  auth:token)  printf 'stub-token\n' ;;
  release:download)
    shift 2; tag=""; out=""; pat=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -R) shift 2 ;;
        -p) pat="$2"; shift 2 ;;
        -O) out="$2"; shift 2 ;;
        --clobber) shift ;;
        *) tag="$1"; shift ;;
      esac
    done
    src="$GH_STUB_FIX/$tag/$pat"
    [ -f "$src" ] || { echo "stub: no asset $pat in release $tag" >&2; exit 1; }
    cp "$src" "$out" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

sums_of() {  # <file> — one SHA256SUMS line naming the CLI asset
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk -v a="$slug" '{print $1 "  " a}'
  else sha256sum "$1" | awk -v a="$slug" '{print $1 "  " a}'; fi
}
run_installer() {  # <scenario-name> — fresh BIN_DIR each run; echoes rc
  local dst="$work/bin-$1"; rm -rf "$dst"; mkdir -p "$dst"
  env "PATH=$stub:$PATH" "GH_STUB_LOG=$work/gh-$1.log" "GH_STUB_FIX=$work/ghfix" \
      "${prefix}_INSTALL_VERSION=v9.9.9" "${prefix}_BIN_DIR=$dst" NO_COLOR=1 \
      bash "$tree/install.sh" >"$work/inst-$1.log" 2>&1
  echo $?
}

cp "$cli" "$ghfix/$slug"
sums_of "$ghfix/$slug" > "$ghfix/SHA256SUMS"
rc="$(run_installer happy)"
[ "$rc" -eq 0 ] || fail channel "happy-path gh install failed (rc=$rc): $(tail -2 "$work/inst-happy.log")"
cmp -s "$work/bin-happy/$slug" "$cli" || fail channel "installed binary differs from the released asset"
grep -q "release download v9.9.9" "$work/gh-happy.log" \
  || fail channel "install did not go through an authenticated gh download"

printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$slug" > "$ghfix/SHA256SUMS"
rc="$(run_installer mismatch)"
{ [ "$rc" -ne 0 ] && [ ! -e "$work/bin-mismatch/$slug" ]; } \
  || fail channel "checksum MISMATCH did not abort the install (fail-closed contract broken)"

rm -f "$ghfix/SHA256SUMS"
rc="$(run_installer nosums)"
{ [ "$rc" -ne 0 ] && [ ! -e "$work/bin-nosums/$slug" ]; } \
  || fail channel "missing SHA256SUMS did not abort the install (fail-closed contract broken)"

printf 'other-release-bytes\n' > "$work/other-asset"
sums_of "$work/other-asset" > "$ghfix/SHA256SUMS"
rc="$(run_installer mixedtag)"
{ [ "$rc" -ne 0 ] && [ ! -e "$work/bin-mixedtag/$slug" ]; } \
  || fail channel "mixed-tag SHA256SUMS did not abort the install (fail-closed contract broken)"
ok channel "authenticated download proven; mismatch/missing/mixed-tag all abort with nothing installed"

# ---- gate: exclusion ---------------------------------------------------------------------
excl=""
[ -e "$tree/scripts/brand-compile.py" ] && excl="scripts/brand-compile.py"
[ -e "$tree/scripts/brand-verify.sh" ] && excl="$excl scripts/brand-verify.sh"
[ -d "$tree/tests/branding" ] && excl="$excl tests/branding/"
[ -e "$tree/docs/white-label.md" ] && excl="$excl docs/white-label.md"
grep -q 'BEGIN branding job' "$tree/.github/workflows/ci.yml" 2>/dev/null && excl="$excl ci.yml-branding-job"
[ -z "$excl" ] || fail exclusion "branding toolchain leaked into the tree:$excl"
ok exclusion "no self-rebrand kit present"

printf 'brand-verify: PASS — %s verified (%s)\n' "$slug" "$tree"
