#!/usr/bin/env bash
# Tests for scripts/brand-compile.py — the whole-tree brand compiler.
#
# Compiles the engine into the fictional fixture brand `epsilon-hub` and proves the
# nine Phase-1 gates: census self-check (dead rules + residue), identity zero-grep
# over contents AND filenames, parse/compile of every emitted script, determinism,
# branding-toolchain exclusion, composed-repo-identity behavior, cohort=external
# provisioning with the export DPA block, spot contracts (hook token / LICENSE /
# bot identity / mode bits), and the .build-manifest (HMAC'd source_rev).
#
# NOTE: -e intentionally OFF — each gate reports pass/fail and the suite continues.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
COMPILE="$repo_root/scripts/brand-compile.py"
CONF="$here/fixtures/epsilon-hub.conf"
KEY="$here/fixtures/hmac-test-key.txt"
PY="$(command -v python3 || true)"

pass=0; fail=0
_ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
_no() { printf '  FAIL %s\n' "$1"; [ $# -ge 2 ] && printf '       %s\n' "$2"; fail=$((fail+1)); }
[ -n "$PY" ] || { echo "python3 required"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/brand-compile-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
out1="$work/out1"; out2="$work/out2"

run_compile() {  # <conf> <out> [source]
  local src="${3:-$repo_root}"
  "$PY" "$COMPILE" "$1" "$2" --source "$src" --hmac-key-file "$KEY"
}

# a source copy for tamper tests (no .git — exercises the non-git enumeration path)
mk_src_copy() {
  local d="$work/src-$1"
  mkdir -p "$d"
  (cd "$repo_root" && git ls-files -z | while IFS= read -r -d '' f; do
    mkdir -p "$d/$(dirname "$f")"
    cp -p "$f" "$d/$f"
  done)
  printf '%s' "$d"
}

# ---- the two real compiles every later gate inspects -------------------------
if run_compile "$CONF" "$out1" >/dev/null 2>&1 && [ -f "$out1/epsilon-hub" ]; then
  _ok "compile: engine -> branded tree (epsilon-hub emitted)"
else
  _no "compile: brand-compile.py failed or emitted no branded CLI" "$("$PY" "$COMPILE" "$CONF" "$work/out-dbg" --source "$repo_root" --hmac-key-file "$KEY" 2>&1 | tail -5)"
fi
run_compile "$CONF" "$out2" >/dev/null 2>&1

# ---- gate 1: census self-check fails loudly ---------------------------------
# 1a. an unclassified mixed-case identity shape in the source -> compile refuses
src_a="$(mk_src_copy residue)"
printf '\n<!-- KhUb sneaky residue -->\n' >> "$src_a/README.md"
if run_compile "$CONF" "$work/out-residue" "$src_a" >"$work/residue.log" 2>&1; then
  _no "gate1a census: mixed-case planted token compiled clean (must fail)"
else
  if grep -qi 'README.md' "$work/residue.log"; then
    _ok "gate1a census: planted KhUb residue fails the compile, naming the file"
  else
    _no "gate1a census: failed but did not name the leaking file" "$(tail -3 "$work/residue.log")"
  fi
fi
# 1b. a vanished anchor (census drift / dead rule) -> compile refuses
src_b="$(mk_src_copy deadrule)"
sed -i '' '/^BOT_SUBJECT_PREFIX=/d' "$src_b/khub" 2>/dev/null || sed -i '/^BOT_SUBJECT_PREFIX=/d' "$src_b/khub"
if run_compile "$CONF" "$work/out-deadrule" "$src_b" >"$work/deadrule.log" 2>&1; then
  _no "gate1b census: deleted BOT_SUBJECT_PREFIX anchor compiled clean (must fail)"
else
  if grep -q 'BOT_SUBJECT_PREFIX' "$work/deadrule.log"; then
    _ok "gate1b census: vanished anchor fails the compile as census drift"
  else
    _no "gate1b census: failed but without naming the dead anchor" "$(tail -3 "$work/deadrule.log")"
  fi
fi

# ---- gate 2: identity zero-grep (contents + filenames, case-insensitive) ----
leaks="$(grep -rniE 'khub|blueblazedev|knowledge-hub' "$out1" 2>/dev/null || true)"
fleaks="$(find "$out1" 2>/dev/null | grep -iE 'khub|blueblazedev|knowledge-hub' || true)"
if [ -f "$out1/epsilon-hub" ] && [ -z "$leaks" ] && [ -z "$fleaks" ]; then
  _ok "gate2 zero-grep: no identity residue in contents or filenames"
else
  _no "gate2 zero-grep: identity residue found" "$(printf '%s\n%s' "$leaks" "$fleaks" | head -5)"
fi

# ---- gate 3: branded tree parses + compiles ----------------------------------
g3=0
bash -n "$out1/epsilon-hub" 2>/dev/null || g3=1
while IFS= read -r -d '' sh; do bash -n "$sh" 2>/dev/null || g3=1; done \
  < <(find "$out1" -name '*.sh' -print0)
while IFS= read -r -d '' pyf; do "$PY" -m py_compile "$pyf" 2>/dev/null || g3=1; done \
  < <(find "$out1" -name '*.py' -print0)
if [ "$g3" -eq 0 ]; then
  _ok "gate3 parse: bash -n all shell + py_compile all python green"
else
  _no "gate3 parse: a branded script no longer parses/compiles"
fi
# embedded helpers must regenerate to an identical branded CLI (drift check runs IN the tree)
if (cd "$out1" && bash scripts/check-embedded-telemetry.sh >/dev/null 2>&1); then
  _ok "gate3 embed: branded embedded helpers in sync with branded lib/"
else
  _no "gate3 embed: branded embed drift-check failed inside the output tree"
fi

# ---- gate 4: determinism ------------------------------------------------------
if [ -d "$out2" ] && diff -r "$out1" "$out2" >/dev/null 2>&1; then
  _ok "gate4 determinism: two compiles are byte-identical"
else
  _no "gate4 determinism: compiles differ" "$(diff -rq "$out1" "$out2" 2>&1 | head -3)"
fi

# ---- gate 5: branding toolchain excluded --------------------------------------
g5=""
[ -f "$out1/epsilon-hub" ] || g5="no branded tree to inspect"
[ -e "$out1/scripts/brand-compile.py" ] && g5="${g5} brand-compile.py present"
[ -e "$out1/scripts/brand-verify.sh" ] && g5="${g5} brand-verify.sh present"
[ -d "$out1/tests/branding" ] && g5="${g5} tests/branding present"
grep -q 'BEGIN branding job' "$out1/.github/workflows/ci.yml" 2>/dev/null && g5="${g5} branding CI job present"
if [ -z "$g5" ]; then
  _ok "gate5 exclusion: no self-rebrand kit in the branded tree"
else
  _no "gate5 exclusion: toolchain leaked into output" "$g5"
fi

# ---- gate 6: composed repo identity actually lands ----------------------------
org_line="$(grep -m1 '^ORG=' "$out1/epsilon-hub" || true)"
repo_line="$(grep -m1 '^EPSILON_HUB_REPO=' "$out1/epsilon-hub" || true)"
client_line="$(grep -m1 '^CLIENT_REPO=' "$out1/epsilon-hub" || true)"
# newline-joined: the shipped lines carry trailing comments, so ';' would not do.
# shellcheck disable=SC2016  # the $VARs must reach the inner bash -c unexpanded
script="$(printf '%s\n%s\n%s\nprintf "%%s|%%s" "$EPSILON_HUB_REPO" "$CLIENT_REPO"\n' "$org_line" "$repo_line" "$client_line")"
resolved="$(bash -c "$script" 2>/dev/null || true)"
if [ "$resolved" = "epsilon-labs/epsilon-hub-cli|epsilon-labs/epsilon-hub-content" ]; then
  _ok "gate6 composed: resolved EPSILON_HUB_REPO + CLIENT_REPO match the conf"
else
  _no "gate6 composed: shipped expressions resolve wrong" "got: $resolved"
fi
# shellcheck disable=SC2016  # same: literal $CLIENT_REPO for the inner shell
script2="$(printf '%s\n%s\nprintf "%%s" "$CLIENT_REPO"\n' "$org_line" "$client_line")"
overridden="$(EPSILON_HUB_CLIENT_REPO=custom/other bash -c "$script2" 2>/dev/null || true)"
if [ "$overridden" = "custom/other" ]; then
  _ok "gate6 composed: branded CLIENT_REPO env override still works"
else
  _no "gate6 composed: EPSILON_HUB_CLIENT_REPO override broken" "got: $overridden"
fi
if NO_COLOR=1 bash "$out1/epsilon-hub" help 2>/dev/null | grep -q 'epsilon-hub init'; then
  _ok "gate6 smoke: branded CLI runs (help names epsilon-hub verbs)"
else
  _no "gate6 smoke: 'epsilon-hub help' failed or is unbranded"
fi

# ---- gate 7: cohort=external provisioned on enable; export DPA-blocked --------
sb="$work/sandbox"; mkdir -p "$sb/home" "$sb/config" "$sb/data" "$sb/state" "$sb/proj"
run_branded() {
  (cd "$sb/proj" && NO_COLOR=1 HOME="$sb/home" XDG_CONFIG_HOME="$sb/config" \
    XDG_DATA_HOME="$sb/data" XDG_STATE_HOME="$sb/state" bash "$out1/epsilon-hub" "$@")
}
run_branded track enable --project >/dev/null 2>&1
cohort_file="$sb/config/epsilon-hub/telemetry-cohort"
if [ -s "$cohort_file" ] && [ "$(head -1 "$cohort_file")" = "external" ]; then
  _ok "gate7 cohort: track enable provisioned cohort=external out of the box"
else
  _no "gate7 cohort: sidecar missing or wrong" "got: $(head -1 "$cohort_file" 2>/dev/null || echo '<absent>')"
fi
mkdir -p "$sb/state/epsilon-hub-telemetry/metrics"
run_branded export >"$work/export.log" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && grep -qi 'BLOCKED' "$work/export.log"; then
  _ok "gate7 export: external export exits blocked without a DPA token"
else
  _no "gate7 export: expected DPA hard-block" "rc=$rc: $(tail -2 "$work/export.log")"
fi

# ---- gate 8: spot contracts ----------------------------------------------------
if grep -q 'HOOK_TOKEN = "epsilon-hub-telemetry/capture_hook.py"' "$out1/lib/telemetry/settings_merge.py"; then
  _ok "gate8 hook token: branded HOOK_TOKEN is epsilon-hub-telemetry/capture_hook.py"
else
  _no "gate8 hook token: wrong HOOK_TOKEN" "$(grep -m1 'HOOK_TOKEN' "$out1/lib/telemetry/settings_merge.py" 2>/dev/null)"
fi
if grep -q 'Epsilon Labs Pty Ltd' "$out1/LICENSE" && ! grep -qi 'MIT License' "$out1/LICENSE"; then
  _ok "gate8 license: LICENSE replaced wholesale from license_text"
else
  _no "gate8 license: LICENSE not the conf text" "$(head -2 "$out1/LICENSE" 2>/dev/null)"
fi
if grep -q '^BOT_AUTHOR="epsilon-hub-bot"$' "$out1/epsilon-hub" \
   && grep -q '^BOT_SUBJECT_PREFIX="publish: epsilon snapshot"$' "$out1/epsilon-hub" \
   && grep -q '^HUB_DIRNAME="epsilon-knowledge"$' "$out1/epsilon-hub"; then
  _ok "gate8 content identity: bot author, subject prefix, hub dirname branded"
else
  _no "gate8 content identity: a content-repo identity default is wrong"
fi
if grep -q '^TRACK_DEFAULT_COHORT="external"$' "$out1/epsilon-hub"; then
  _ok "gate8 cohort default: TRACK_DEFAULT_COHORT substituted to external"
else
  _no "gate8 cohort default: censused engine default not substituted"
fi
if [ -x "$out1/epsilon-hub" ]; then
  _ok "gate8 mode bits: branded CLI kept its executable bit"
else
  _no "gate8 mode bits: epsilon-hub is not executable"
fi

# ---- gate 9: build manifest -----------------------------------------------------
mf="$out1/.build-manifest"
if [ -f "$mf" ]; then
  src_rev="$(sed -n 's/^source_rev=//p' "$mf")"
  conf_rev="$(sed -n 's/^conf_rev=//p' "$mf")"
  comp_rev="$(sed -n 's/^compiler_rev=//p' "$mf")"
  head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  g9=0
  case "$src_rev" in *[!0-9a-f]*|'') g9=1 ;; esac
  [ "${#src_rev}" -eq 64 ] || g9=1
  [ -n "$head_sha" ] && [ "$src_rev" = "$head_sha" ] && g9=1
  [ -n "$conf_rev" ] && [ -n "$comp_rev" ] || g9=1
  if [ "$g9" -eq 0 ]; then
    _ok "gate9 manifest: source_rev HMAC'd (64-hex, not the raw SHA); conf_rev + compiler_rev present"
  else
    _no "gate9 manifest: rev fields wrong" "source_rev=$src_rev"
  fi
  want_conf="$(shasum -a 256 "$CONF" 2>/dev/null | awk '{print $1}' || sha256sum "$CONF" | awk '{print $1}')"
  want_comp="$(shasum -a 256 "$COMPILE" 2>/dev/null | awk '{print $1}' || sha256sum "$COMPILE" | awk '{print $1}')"
  if [ "$conf_rev" = "$want_conf" ] && [ "$comp_rev" = "$want_comp" ]; then
    _ok "gate9 manifest: conf_rev + compiler_rev are the exact content hashes"
  else
    _no "gate9 manifest: rev hashes do not match conf/compiler bytes"
  fi
else
  _no "gate9 manifest: .build-manifest missing from the branded tree"
  _no "gate9 manifest: rev checks skipped (no manifest)"
fi

# ---- verdict --------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
