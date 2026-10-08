#!/usr/bin/env bash
# Build the download the web installer fetches, into a static site folder:
#   ./release.sh ../larmor/site     -> site/larmor.tar.gz + site/install.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE="${1:?usage: release.sh <site dir>}"
git -C "$DIR" diff --quiet HEAD || { echo "commit first: release.sh ships HEAD"; exit 1; }
git -C "$DIR" archive --format=tar.gz -o "$SITE/larmor.tar.gz" HEAD
cp "$DIR/web-install.sh" "$SITE/install.sh"
echo "released $(git -C "$DIR" rev-parse --short HEAD) -> $SITE ($(du -h "$SITE/larmor.tar.gz" | cut -f1))"
