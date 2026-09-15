#!/bin/bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
DEVELOPER_DIR_VALUE=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
BUILD_DIR="$REPO_DIR/.build/controlled-arm64"
TEST_DIR="$REPO_DIR/.build/controlled-tests"
CONTROLLED_HOME="$REPO_DIR/.build/controlled-home"
DIST_ROOT="$REPO_DIR/dist"
PACKAGE_NAME="User-Interaction-Governor-macos-arm64"
PACKAGE_DIR="$DIST_ROOT/$PACKAGE_NAME"
ARCHIVE="$DIST_ROOT/$PACKAGE_NAME.zip"
BINARIES=(uig uigd uig-renderer ui-display ui-choice ui-entry ui-confirm ui-file ui-media)

mkdir -p "$CONTROLLED_HOME" "$DIST_ROOT"
chmod 700 "$CONTROLLED_HOME"

CONTROLLED_ENV=(
  HOME="$CONTROLLED_HOME"
  TMPDIR=/tmp
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  DEVELOPER_DIR="$DEVELOPER_DIR_VALUE"
  MACOSX_DEPLOYMENT_TARGET=13.0
)

env -i "${CONTROLLED_ENV[@]}" /usr/bin/xcrun swift test --scratch-path "$TEST_DIR"
env -i "${CONTROLLED_ENV[@]}" /usr/bin/xcrun swift build --configuration release --arch arm64 --scratch-path "$BUILD_DIR"

rm -rf -- "$PACKAGE_DIR"
rm -f -- "$ARCHIVE" "$DIST_ROOT/SHA256SUMS.txt"
mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/share/doc/UserInteractionGovernor"

for binary in "${BINARIES[@]}"; do
  source_path="$BUILD_DIR/arm64-apple-macosx/release/$binary"
  if [ ! -x "$source_path" ]; then
    source_path="$BUILD_DIR/release/$binary"
  fi
  /usr/bin/install -m 755 "$source_path" "$PACKAGE_DIR/bin/$binary"
  /usr/bin/codesign --force --sign - "$PACKAGE_DIR/bin/$binary"
  archs=$(/usr/bin/lipo -archs "$PACKAGE_DIR/bin/$binary")
  if [ "$archs" != "arm64" ]; then
    echo "Unexpected architecture for $binary: $archs" >&2
    exit 1
  fi
  if /usr/bin/otool -L "$PACKAGE_DIR/bin/$binary" | /usr/bin/grep -q '/usr/local'; then
    echo "Ambient /usr/local dependency in $binary" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --strict "$PACKAGE_DIR/bin/$binary"
done

/bin/cp "$REPO_DIR/LICENSE" "$REPO_DIR/README.md" "$PACKAGE_DIR/share/doc/UserInteractionGovernor/"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ARCHIVE"
(
  cd "$DIST_ROOT"
  /usr/bin/shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS.txt
  /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)

echo "Built $ARCHIVE"
