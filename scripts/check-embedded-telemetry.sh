#!/usr/bin/env bash
# CI guard: the telemetry helpers embedded in `khub` must match lib/telemetry/*.py.
# Regenerate from lib/ and fail if that changes `khub` — i.e. someone edited a helper
# without re-running scripts/embed-telemetry.py and committing the result.
# Commit-agnostic (no git needed): compares khub before/after a regenerate.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
tmp="$(mktemp "${TMPDIR:-/tmp}/khub-embed-check.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp "$root/khub" "$tmp"
python3 "$root/scripts/embed-telemetry.py" >/dev/null
if ! diff -q "$tmp" "$root/khub" >/dev/null; then
  echo "error: khub's embedded telemetry helpers are out of sync with lib/telemetry/*.py." >&2
  echo "  they have just been regenerated in place — review and commit khub." >&2
  exit 1
fi
echo "embedded telemetry helpers are in sync with lib/telemetry/*.py"
