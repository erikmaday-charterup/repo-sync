#!/bin/bash
# Builds "Repo Sync.app" and installs it to ~/Applications (or the folder passed as a bare argument).
# Usage: build-app.sh [--universal] [--version X.Y.Z] [--no-install] [dest-folder]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications"
APP="$ROOT/.build/Repo Sync.app"
UNIVERSAL=0
INSTALL=1
SHORT_VERSION="1.0"
BUNDLE_VERSION="1"

while [ $# -gt 0 ]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --no-install) INSTALL=0 ;;
    --version)
      [ $# -ge 2 ] || { echo "--version needs a value like 1.2.3" >&2; exit 2; }
      shift
      if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Version must look like 1.2.3, got: $1" >&2
        exit 2
      fi
      SHORT_VERSION="$1"
      BUNDLE_VERSION="$1"
      ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) DEST="$1" ;;
  esac
  shift
done

# Liquid Glass needs the macOS 26+ SDK, which ships with Xcode rather than older command line tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
echo "Building with SDK $(xcrun --show-sdk-version)"

BUILD_ARGS=(-c release --package-path "$ROOT")
if [ "$UNIVERSAL" -eq 1 ]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RepoSync" "$APP/Contents/MacOS/RepoSync"

# SwiftPM records the deployment target as the SDK version, and macOS only gives apps the
# current system look when the recorded SDK is new enough.
SDK_VERSION="$(xcrun --show-sdk-version)"
xcrun vtool -set-build-version macos 13.0 "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/RepoSync" "$APP/Contents/MacOS/RepoSync"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.erikmaday.RepoSync</string>
    <key>CFBundleName</key><string>Repo Sync</string>
    <key>CFBundleDisplayName</key><string>Repo Sync</string>
    <key>CFBundleExecutable</key><string>RepoSync</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier com.erikmaday.RepoSync "$APP"

if [ "$INSTALL" -eq 0 ]; then
  ZIP="$ROOT/.build/RepoSync-$SHORT_VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Built $APP"
  echo "Zipped $ZIP"
  exit 0
fi

mkdir -p "$DEST"
pkill -x RepoSync 2>/dev/null || true
rm -rf "$DEST/Repo Sync.app"
cp -R "$APP" "$DEST/"
echo "Installed $DEST/Repo Sync.app"
