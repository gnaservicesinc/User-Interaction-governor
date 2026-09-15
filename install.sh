#!/bin/bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
PREFIX=${1:-"$HOME/.local"}
SOURCE_DIR="$REPO_DIR/dist/User-Interaction-Governor-macos-arm64/bin"
BINARIES=(uig uigd uig-renderer ui-display ui-choice ui-entry ui-confirm ui-file ui-media)

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Distribution not found. Run ./build.sh first." >&2
  exit 1
fi

/bin/mkdir -p "$PREFIX/bin"
for binary in "${BINARIES[@]}"; do
  /usr/bin/install -m 755 "$SOURCE_DIR/$binary" "$PREFIX/bin/$binary"
done

echo "Installed User Interaction Governor in $PREFIX/bin"
echo "Add $PREFIX/bin to PATH if it is not already present."
