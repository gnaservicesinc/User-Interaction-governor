#!/bin/bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
PREFIX=${1:-"$HOME/.local"}
SOURCE_DIR="$REPO_DIR/dist/User-Interaction-Governor-macos-arm64/bin"
SOURCE_LIBRARY="$REPO_DIR/dist/User-Interaction-Governor-macos-arm64/lib/ugl"
BINARIES=(uig uigd uig-renderer ui-display ui-choice ui-entry ui-confirm ui-file ui-media)

if [ ! -d "$SOURCE_DIR" ] || [ ! -f "$SOURCE_LIBRARY/govoner-runtime.sh" ]; then
  echo "Distribution not found. Run ./build.sh first." >&2
  exit 1
fi

/bin/mkdir -p "$PREFIX/bin"
/bin/mkdir -p "$PREFIX/lib/ugl/versions"
for binary in "${BINARIES[@]}"; do
  /usr/bin/install -m 755 "$SOURCE_DIR/$binary" "$PREFIX/bin/$binary"
done
/usr/bin/install -m 644 "$SOURCE_LIBRARY/govoner-runtime.sh" "$PREFIX/lib/ugl/govoner-runtime.sh"
for component in "${BINARIES[@]}" govoner-runtime; do
  /usr/bin/install -m 644 "$SOURCE_LIBRARY/versions/$component.version" "$PREFIX/lib/ugl/versions/$component.version"
done
/usr/bin/install -m 644 "$SOURCE_LIBRARY/components.manifest" "$PREFIX/lib/ugl/components.manifest"

echo "Installed User Interaction Governor in $PREFIX"
echo "Add $PREFIX/bin to PATH if it is not already present."
echo "Govoner Studio exports should source $PREFIX/lib/ugl/govoner-runtime.sh"
