#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# khub installer. Fetches the `khub` CLI from a GitHub *Release* (never from a
# mutable branch) and installs it to ~/.local/bin. Verify integrity against the
# SHA256 published in the release notes (printed at the end).
#
#   curl -sfL https://github.com/blueblazedev/khub/releases/latest/download/install.sh | bash
#
# Override the target dir with KHUB_BIN_DIR, or pin a version with
# KHUB_INSTALL_VERSION=vX.Y.Z (default: the latest published release).
# =============================================================================

REPO="blueblazedev/khub"
BIN_DIR="${KHUB_BIN_DIR:-$HOME/.local/bin}"
VERSION="${KHUB_INSTALL_VERSION:-}"

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }

if [ -z "$VERSION" ]; then
  # Resolve the latest RELEASE tag (a release object — not the main branch).
  VERSION="$(curl -sfL "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$VERSION" ] || { echo "error: could not resolve the latest release; set KHUB_INSTALL_VERSION=vX.Y.Z" >&2; exit 1; }
fi

url="https://github.com/${REPO}/releases/download/${VERSION}/khub"
mkdir -p "$BIN_DIR"
echo "Installing khub ${VERSION} -> ${BIN_DIR}/khub"
curl -sfL "$url" -o "$BIN_DIR/khub" || { echo "error: download failed: $url" >&2; exit 1; }
chmod +x "$BIN_DIR/khub"

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) echo "NOTE: $BIN_DIR is not on your PATH. Add it, e.g.:"
     echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && exec \$SHELL" ;;
esac

echo "Done. Verify with:  khub version"
echo "Integrity (compare against the SHA256 in the ${VERSION} release notes):"
if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$BIN_DIR/khub"
elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$BIN_DIR/khub"; fi
