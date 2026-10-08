#!/usr/bin/env bash
# Larmor web installer:  curl -fsSL <site>/install.sh | bash
# Downloads the latest Larmor into ~/.larmor/app and runs its installer.
# Pass installer options after "bash -s --", e.g.  ... | bash -s -- claude
set -euo pipefail
BASE="${LARMOR_BASE:-https://larmor.dev}"
DEST="${LARMOR_DIR:-$HOME/.larmor/app}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo "→ downloading Larmor"
curl -fsSL "$BASE/larmor.tar.gz" -o "$tmp/larmor.tar.gz"
mkdir -p "$DEST"
tar -xzf "$tmp/larmor.tar.gz" -C "$DEST"        # updates in place; keeps the Python env
exec "$DEST/install.sh" "$@"
