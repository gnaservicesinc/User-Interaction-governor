#!/bin/bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
DEVELOPER_DIR_VALUE=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}
CONFIGURATION=release
BUILD_LABEL=""

case "${1:-}" in
  "") ;;
  --enable-debugging)
    CONFIGURATION=debug
    BUILD_LABEL=-debug
    ;;
  --help|-h)
    echo "usage: ./build.sh [--enable-debugging]"
    echo "Builds optimized release archives by default; the flag creates separate debug archives."
    exit 0
    ;;
  *)
    echo "usage: ./build.sh [--enable-debugging]" >&2
    exit 2
    ;;
esac

BUILD_DIR="$REPO_DIR/.build/controlled-arm64-$CONFIGURATION"
TEST_DIR="$REPO_DIR/.build/controlled-tests-$CONFIGURATION"
CONTROLLED_HOME="$REPO_DIR/.build/controlled-home"
DIST_ROOT="$REPO_DIR/dist"
PACKAGE_NAME="User-Interaction-Governor-macos-arm64$BUILD_LABEL"
PACKAGE_DIR="$DIST_ROOT/$PACKAGE_NAME"
ARCHIVE="$DIST_ROOT/$PACKAGE_NAME.zip"
STUDIO_PACKAGE_NAME="Govoner-Studio-macos-arm64$BUILD_LABEL"
STUDIO_PACKAGE_DIR="$DIST_ROOT/$STUDIO_PACKAGE_NAME"
STUDIO_APP="$STUDIO_PACKAGE_DIR/Govoner Studio.app"
STUDIO_CONTENTS="$STUDIO_APP/Contents"
STUDIO_ARCHIVE="$DIST_ROOT/$STUDIO_PACKAGE_NAME.zip"
BINARIES=(uig uigd uig-renderer ui-display ui-choice ui-entry ui-confirm ui-file ui-media)
COMPONENT_VERSION=$(/usr/bin/sed -n 's/^public let governorVersion = "\([^"]*\)"$/\1/p' "$REPO_DIR/Sources/GovernorCore/Models.swift")
RUNTIME_VERSION=$(/usr/bin/sed -n 's/^GOVONER_BASH_RUNTIME_VERSION=//p' "$REPO_DIR/Components/govoner-runtime.sh")
if [ -z "$COMPONENT_VERSION" ] || [ "$COMPONENT_VERSION" != "$RUNTIME_VERSION" ]; then
  echo "GovernorCore and Bash runtime component versions do not match." >&2
  exit 1
fi

mkdir -p "$CONTROLLED_HOME" "$DIST_ROOT"
chmod 700 "$CONTROLLED_HOME"

CONTROLLED_ENV=(
  HOME="$CONTROLLED_HOME"
  TMPDIR=/tmp
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  DEVELOPER_DIR="$DEVELOPER_DIR_VALUE"
  MACOSX_DEPLOYMENT_TARGET=13.0
)

env -i "${CONTROLLED_ENV[@]}" /usr/bin/xcrun swift test --configuration "$CONFIGURATION" --scratch-path "$TEST_DIR"
env -i "${CONTROLLED_ENV[@]}" /usr/bin/xcrun swift build --configuration "$CONFIGURATION" --arch arm64 --scratch-path "$BUILD_DIR"

rm -rf -- "$PACKAGE_DIR" "$STUDIO_PACKAGE_DIR"
rm -f -- "$ARCHIVE" "$STUDIO_ARCHIVE" "$DIST_ROOT/SHA256SUMS.txt"
mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/lib/ugl/versions" "$PACKAGE_DIR/share/doc/UserInteractionGovernor"

release_binary() {
  binary_name=$1
  binary_path="$BUILD_DIR/arm64-apple-macosx/$CONFIGURATION/$binary_name"
  if [ ! -x "$binary_path" ]; then
    binary_path="$BUILD_DIR/$CONFIGURATION/$binary_name"
  fi
  printf '%s\n' "$binary_path"
}

for binary in "${BINARIES[@]}"; do
  source_path=$(release_binary "$binary")
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

/usr/bin/install -m 644 "$REPO_DIR/Components/govoner-runtime.sh" "$PACKAGE_DIR/lib/ugl/govoner-runtime.sh"
for component in "${BINARIES[@]}" govoner-runtime; do
  /usr/bin/printf '%s\n' "$COMPONENT_VERSION" >"$PACKAGE_DIR/lib/ugl/versions/$component.version"
done
/usr/bin/printf '%s\n' "${BINARIES[@]}" govoner-runtime >"$PACKAGE_DIR/lib/ugl/components.manifest"

/bin/cp "$REPO_DIR/LICENSE" "$REPO_DIR/README.md" "$PACKAGE_DIR/share/doc/UserInteractionGovernor/"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ARCHIVE"

mkdir -p "$STUDIO_CONTENTS/MacOS" "$STUDIO_CONTENTS/Components/bin" "$STUDIO_CONTENTS/Components/share/versions" "$STUDIO_CONTENTS/Resources/Documentation"
/usr/bin/install -m 755 "$(release_binary govoner-studio)" "$STUDIO_CONTENTS/MacOS/Govoner Studio"
for binary in "${BINARIES[@]}"; do
  /usr/bin/install -m 755 "$(release_binary "$binary")" "$STUDIO_CONTENTS/Components/bin/$binary"
  /usr/bin/printf '%s\n' "$COMPONENT_VERSION" >"$STUDIO_CONTENTS/Components/share/versions/$binary.version"
done
/usr/bin/install -m 644 "$REPO_DIR/Components/govoner-runtime.sh" "$STUDIO_CONTENTS/Components/share/govoner-runtime.sh"
/usr/bin/printf '%s\n' "$COMPONENT_VERSION" >"$STUDIO_CONTENTS/Components/share/versions/govoner-runtime.version"
/usr/bin/printf '%s\n' "${BINARIES[@]}" govoner-runtime >"$STUDIO_CONTENTS/Components/share/components.manifest"
/bin/cp "$REPO_DIR/GovonerStudio/Assets/GovonerStudio.icns" "$STUDIO_CONTENTS/Resources/"
/bin/cp "$REPO_DIR/LICENSE" "$REPO_DIR/README.md" "$STUDIO_CONTENTS/Resources/Documentation/"

/bin/cat >"$STUDIO_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Govoner Studio</string>
  <key>CFBundleExecutable</key>
  <string>Govoner Studio</string>
  <key>CFBundleIconFile</key>
  <string>GovonerStudio</string>
  <key>CFBundleIdentifier</key>
  <string>com.gnaservices.GovonerStudio</string>
  <key>CFBundleName</key>
  <string>Govoner Studio</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$COMPONENT_VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array><string>public.json</string></array>
      <key>UTTypeDescription</key>
      <string>Govoner Studio Project</string>
      <key>UTTypeIdentifier</key>
      <string>com.gnaservices.govoner-studio.project</string>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>govonerstudio</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

STUDIO_EXECUTABLES=("$STUDIO_CONTENTS/MacOS/Govoner Studio")
for binary in "${BINARIES[@]}"; do
  STUDIO_EXECUTABLES+=("$STUDIO_CONTENTS/Components/bin/$binary")
done
for executable in "${STUDIO_EXECUTABLES[@]}"; do
  /usr/bin/codesign --force --sign - "$executable"
  archs=$(/usr/bin/lipo -archs "$executable")
  if [ "$archs" != "arm64" ]; then
    echo "Unexpected Studio architecture for $executable: $archs" >&2
    exit 1
  fi
  if /usr/bin/otool -L "$executable" | /usr/bin/grep -q '/usr/local'; then
    echo "Ambient /usr/local dependency in $executable" >&2
    exit 1
  fi
done
/usr/bin/codesign --force --sign - "$STUDIO_APP"
/usr/bin/codesign --verify --strict --deep "$STUDIO_APP"
/usr/bin/plutil -lint "$STUDIO_CONTENTS/Info.plist"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STUDIO_PACKAGE_DIR" "$STUDIO_ARCHIVE"

(
  cd "$DIST_ROOT"
  /usr/bin/shasum -a 256 "$(basename "$ARCHIVE")" "$(basename "$STUDIO_ARCHIVE")" > SHA256SUMS.txt
  /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)

echo "Built $ARCHIVE"
echo "Built $STUDIO_ARCHIVE"
echo "Configuration: $CONFIGURATION"
