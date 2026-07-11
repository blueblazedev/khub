#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# khub installer. Fetches the `khub` CLI from a GitHub *Release* (never from a
# mutable branch), verifies it against that release's SHA256SUMS, and installs
# it atomically to ~/.local/bin.
#
#   curl -sfL https://github.com/blueblazedev/khub/releases/latest/download/install.sh | bash
#
# Override the target dir with KHUB_BIN_DIR, or pin a version with
# KHUB_INSTALL_VERSION=vX.Y.Z (default: the latest published release).
#
# Integrity: the download is checksum-verified BEFORE it replaces any existing
# binary. A mismatch, or a release with no SHA256SUMS, fails closed and installs
# nothing — a pre-existing khub is left untouched.
# =============================================================================

REPO="blueblazedev/khub"
BIN_DIR="${KHUB_BIN_DIR:-$HOME/.local/bin}"
VERSION="${KHUB_INSTALL_VERSION:-}"

# Style: 16-color + glyphs, only on an interactive TTY with NO_COLOR unset. The
# common `curl | bash` pipe is non-TTY, so output stays plain. Presentation only
# — the verification logic below is exactly as shipped.
c_reset=''; c_grn=''; c_ylw=''; c_cyan=''; c_dim=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_reset=$'\033[0m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_cyan=$'\033[36m'; c_dim=$'\033[2m'
fi
_loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
case "$_loc" in *UTF-8*|*utf-8*|*UTF8*|*utf8*) g_ok='✓'; g_warn='⚠'; g_arrow='→' ;; *) g_ok='OK'; g_warn='!!'; g_arrow='->' ;; esac

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }

if [ -z "$VERSION" ]; then
  # Resolve the latest RELEASE tag (a release object — not the main branch).
  VERSION="$(curl -sfL "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$VERSION" ] || { echo "error: could not resolve the latest release; set KHUB_INSTALL_VERSION=vX.Y.Z" >&2; exit 1; }
fi

# Resolve the binary AND its checksums from the SAME pinned tag. Never mix a
# pinned binary with a 'latest' SHA256SUMS: a release landing mid-install would
# make them disagree.
url="https://github.com/${REPO}/releases/download/${VERSION}/khub"
sums_url="https://github.com/${REPO}/releases/download/${VERSION}/SHA256SUMS"

mkdir -p "$BIN_DIR"

# Download into a temp file ON THE SAME FILESYSTEM as the final path, so the
# install completes as an atomic rename. The trap guarantees an interrupted or
# failed run leaves no stray download behind, and the existing binary is only
# ever replaced by the final `mv` after verification succeeds.
tmp="$(mktemp "$BIN_DIR/.khub-download.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

printf '%s>%s Installing khub %s %s %s\n' "$c_cyan" "$c_reset" "$VERSION" "$g_arrow" "$BIN_DIR/khub"
curl -sfL "$url" -o "$tmp" || { echo "error: download failed: $url" >&2; exit 1; }

# sha256 of a file via whichever tool exists (both preinstalled on macOS/Linux).
# Portable string compare later — avoids `shasum -c` / `sha256sum -c` divergence.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else return 1; fi
}

if [ "${KHUB_SKIP_VERIFY:-}" = "1" ]; then
  printf '%s%s%s WARNING: KHUB_SKIP_VERIFY=1 — installing WITHOUT checksum verification.\n' "$c_ylw" "$g_warn" "$c_reset" >&2
  printf '   Use this only to install a legacy release that predates SHA256SUMS.\n' >&2
  actual="$(sha256_of "$tmp" || true)"
else
  actual="$(sha256_of "$tmp")" || { echo "error: no sha256 tool (shasum/sha256sum) available — cannot verify" >&2; exit 1; }
  # Fetch the checksums for THIS tag. The binary already downloaded, so a failure
  # here means the SHA256SUMS asset is simply absent for this release.
  if ! sums="$(curl -sfL "$sums_url" 2>/dev/null)"; then
    echo "error: this release (${VERSION}) predates checksum publication." >&2
    echo "  fix: pin KHUB_INSTALL_VERSION=v0.1.2 or later, or retry." >&2
    echo "  installing an older release on purpose: see the README legacy section." >&2
    exit 1
  fi
  # SHA256SUMS lists both khub and install.sh — take the hash for the khub entry.
  expected="$(printf '%s\n' "$sums" | awk '$2 == "khub" { print $1 }')"
  [ -n "$expected" ] || { echo "error: SHA256SUMS has no entry for 'khub' — refusing to install" >&2; exit 1; }
  if [ "$actual" != "$expected" ]; then
    echo "error: checksum mismatch — the download does not match the published SHA256SUMS." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    echo "  nothing was installed. retry; if it persists, do not use this download." >&2
    exit 1
  fi
fi

chmod +x "$tmp"
mv "$tmp" "$BIN_DIR/khub"   # atomic, final step — an existing binary is replaced only now

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) echo "NOTE: $BIN_DIR is not on your PATH. Add it, e.g.:"
     echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && exec \$SHELL" ;;
esac

if [ "${KHUB_SKIP_VERIFY:-}" = "1" ]; then
  printf '%s%s%s installed (unverified). sha256: %s\n' "$c_ylw" "$g_warn" "$c_reset" "${actual:-unknown}"
else
  printf '%s%s%s verified sha256: %s\n' "$c_grn" "$g_ok" "$c_reset" "$actual"
fi
printf '  %skhub version   # confirm it runs%s\n' "$c_dim" "$c_reset"
echo ""
printf '%sOptional — verify build provenance after '\''gh auth login'\'':%s\n' "$c_dim" "$c_reset"
printf '  %sgh attestation verify "%s/khub" --repo %s --signer-workflow %s/.github/workflows/release.yml%s\n' "$c_dim" "$BIN_DIR" "$REPO" "$REPO" "$c_reset"
