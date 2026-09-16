#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Govoner Studio"
BUNDLE_ID="com.gnaservices.GovonerStudio"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist/development"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$CONTENTS/MacOS/$APP_NAME"
COMPONENT_VERSION=$(/usr/bin/sed -n 's/^public let governorVersion = "\([^"]*\)"$/\1/p' "$ROOT_DIR/Sources/GovernorCore/Models.swift")

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
/usr/bin/xcrun swift build
BIN_DIR=$(/usr/bin/xcrun swift build --show-bin-path)

rm -rf -- "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Components/bin" "$CONTENTS/Components/share/versions" "$CONTENTS/Resources"
cp "$BIN_DIR/govoner-studio" "$APP_BINARY"
chmod +x "$APP_BINARY"
for helper in uig uigd uig-renderer ui-display ui-choice ui-entry ui-confirm ui-file ui-media; do
  cp "$BIN_DIR/$helper" "$CONTENTS/Components/bin/$helper"
  chmod +x "$CONTENTS/Components/bin/$helper"
  printf '%s\n' "$COMPONENT_VERSION" >"$CONTENTS/Components/share/versions/$helper.version"
done
cp "$ROOT_DIR/Components/govoner-runtime.sh" "$CONTENTS/Components/share/govoner-runtime.sh"
printf '%s\n' "$COMPONENT_VERSION" >"$CONTENTS/Components/share/versions/govoner-runtime.version"
cp "$ROOT_DIR/GovonerStudio/Assets/GovonerStudio.icns" "$CONTENTS/Resources/"

cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>GovonerStudio</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign - "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
