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
# Channels — RELEASE_CHANNEL selects how release assets are fetched:
#   anonymous  public repo: plain curl against github.com (this repo's default)
#   gh         private repo: every fetch goes through the authenticated GitHub
#              CLI. Builds delivered from a private org substitute this default;
#              their engineers bootstrap with a gh-download one-liner instead of
#              anonymous curl.
#
# Integrity (both channels): the download is checksum-verified BEFORE it
# replaces any existing binary. A mismatch, or a release with no SHA256SUMS,
# fails closed and installs nothing — a pre-existing khub is left untouched.
# =============================================================================

REPO="blueblazedev/khub"
BIN_NAME="khub"                  # release asset name == installed command name
RELEASE_CHANNEL="anonymous"      # anonymous | gh (a build for a private org substitutes this)
API_BASE="${KHUB_API_BASE:-https://api.github.com}"
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
if [ "$RELEASE_CHANNEL" = "gh" ]; then
  command -v gh >/dev/null 2>&1 || { echo "error: the GitHub CLI 'gh' is required to install from a private release — https://cli.github.com" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated — run 'gh auth login' first" >&2; exit 1; }
fi

if [ -z "$VERSION" ]; then
  # Resolve the latest RELEASE tag (a release object — not the main branch).
  # Probes are `|| true`-guarded so a failure reaches the friendly error below
  # instead of dying silently under set -e + pipefail.
  if [ "$RELEASE_CHANNEL" = "gh" ]; then
    VERSION="$(gh api "repos/${REPO}/releases/latest" -q .tag_name 2>/dev/null | head -1 || true)"
  else
    VERSION="$(curl -sfL "${API_BASE}/repos/${REPO}/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  fi
  [ -n "$VERSION" ] || { echo "error: could not resolve the latest release; set KHUB_INSTALL_VERSION=vX.Y.Z" >&2; exit 1; }
fi

mkdir -p "$BIN_DIR"

# Download into temp files ON THE SAME FILESYSTEM as the final path, so the
# install completes as an atomic rename. The trap guarantees an interrupted or
# failed run leaves no stray download behind, and the existing binary is only
# ever replaced by the final `mv` after verification succeeds.
tmp="$(mktemp "$BIN_DIR/.${BIN_NAME}-download.XXXXXX")"
sums_tmp="$(mktemp "$BIN_DIR/.${BIN_NAME}-sums.XXXXXX")"
trap 'rm -f "$tmp" "$sums_tmp"' EXIT

# Fetch one asset of the PINNED tag via the active channel. Never mix a pinned
# binary with a 'latest' SHA256SUMS: a release landing mid-install would make
# them disagree — both fetches below name the same $VERSION.
fetch_asset() {  # <asset-name> <dest>
  if [ "$RELEASE_CHANNEL" = "gh" ]; then
    gh release download "$VERSION" -R "$REPO" -p "$1" -O "$2" --clobber 2>/dev/null
  else
    curl -sfL "https://github.com/${REPO}/releases/download/${VERSION}/$1" -o "$2"
  fi
}

printf '%s>%s Installing %s %s %s %s\n' "$c_cyan" "$c_reset" "$BIN_NAME" "$VERSION" "$g_arrow" "$BIN_DIR/$BIN_NAME"
fetch_asset "$BIN_NAME" "$tmp" || { echo "error: download failed: ${REPO}@${VERSION} asset ${BIN_NAME}" >&2; exit 1; }

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
  if ! fetch_asset SHA256SUMS "$sums_tmp" || [ ! -s "$sums_tmp" ]; then
    echo "error: this release (${VERSION}) publishes no SHA256SUMS — refusing an unverified install." >&2
    echo "  fix: pin a release that ships checksums, or retry." >&2
    echo "  installing an older release on purpose: see the README legacy section." >&2
    exit 1
  fi
  # SHA256SUMS lists every release asset — take the hash for the CLI's entry.
  expected="$(awk -v a="$BIN_NAME" '$2 == a { print $1 }' "$sums_tmp")"
  [ -n "$expected" ] || { echo "error: SHA256SUMS has no entry for '${BIN_NAME}' — refusing to install" >&2; exit 1; }
  if [ "$actual" != "$expected" ]; then
    echo "error: checksum mismatch — the download does not match the published SHA256SUMS." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    echo "  nothing was installed. retry; if it persists, do not use this download." >&2
    exit 1
  fi
fi

chmod +x "$tmp"
mv "$tmp" "$BIN_DIR/$BIN_NAME"   # atomic, final step — an existing binary is replaced only now

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
printf '  %s%s version   # confirm it runs%s\n' "$c_dim" "$BIN_NAME" "$c_reset"
echo ""
if [ "$RELEASE_CHANNEL" = "anonymous" ]; then
  printf '%sOptional — verify build provenance after '\''gh auth login'\'':%s\n' "$c_dim" "$c_reset"
  printf '  %sgh attestation verify "%s/%s" --repo %s --signer-workflow %s/.github/workflows/release.yml%s\n' "$c_dim" "$BIN_DIR" "$BIN_NAME" "$REPO" "$REPO" "$c_reset"
else
  printf '%sIntegrity: this install was checksum-verified against %s'\''s release SHA256SUMS.%s\n' "$c_dim" "$REPO" "$c_reset"
fi
