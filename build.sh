#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="DSNK Wall"
APP_DIR="$ROOT/${APP_NAME}.app"
BIN_NAME="DSNKWall"

echo "==> Building release binary…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/${BIN_NAME}"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling ${APP_NAME}.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/${BIN_NAME}"

# SPM Bundle.module looks for <target>_<target>.bundle next to the executable.
# Give it a minimal Info.plist so codesign --deep accepts it.
BUNDLE_NAME="${BIN_NAME}_${BIN_NAME}.bundle"
BUNDLE_SRC="$(dirname "$BIN")/${BUNDLE_NAME}"
BUNDLE_DST="$APP_DIR/Contents/MacOS/${BUNDLE_NAME}"
if [[ -d "$BUNDLE_SRC" ]]; then
  cp -R "$BUNDLE_SRC" "$BUNDLE_DST"
  if [[ ! -f "$BUNDLE_DST/Info.plist" ]]; then
    cat > "$BUNDLE_DST/Info.plist" <<'BUNDLEPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>party.dmack.DSNKWall.resources</string>
    <key>CFBundleName</key>
    <string>DSNKWall</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
BUNDLEPLIST
  fi
fi
# Fallback paths used by Renderer via Bundle.main
cp "$ROOT/Sources/DSNKWall/Resources/Shaders.metal" "$APP_DIR/Contents/Resources/Shaders.metal"
cp "$ROOT/assets/vhs-test-screen.mp4" "$APP_DIR/Contents/Resources/vhs-test-screen.mp4"
# Y2K GIF sticker pack for VHS overlays
rm -rf "$APP_DIR/Contents/Resources/gifs"
mkdir -p "$APP_DIR/Contents/Resources/gifs"
cp "$ROOT/assets/gifs/"*.gif "$APP_DIR/Contents/Resources/gifs/" 2>/dev/null || true
cp "$ROOT/assets/gifs/SOURCES.md" "$APP_DIR/Contents/Resources/gifs/" 2>/dev/null || true

# App icon from DSNK cover art
ICON_SRC="$ROOT/assets/DSNK cover.png"
ICON_ICNS="$APP_DIR/Contents/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
  TMPICON="$(mktemp -d)"
  ICONSET="$TMPICON/AppIcon.iconset"
  mkdir -p "$ICONSET"
  sips -z 1024 1024 "$ICON_SRC" --out "$TMPICON/base.png" >/dev/null
  # sips dislikes @2x in --out paths; write temp then rename.
  while IFS= read -r spec; do
    size="${spec%%:*}"
    name="${spec#*:}"
    sips -z "$size" "$size" "$TMPICON/base.png" --out "$TMPICON/resized.png" >/dev/null
    cp "$TMPICON/resized.png" "$ICONSET/$name"
  done <<'SPECS'
16:icon_16x16.png
32:diana.k@example.org
32:icon_32x32.png
64:ivan.p@example.net
128:icon_128x128.png
256:wendy.h@example.net
256:icon_256x256.png
512:wendy.h@example.net
512:icon_512x512.png
1024:walt.e@example.net
SPECS
  iconutil -c icns "$ICONSET" -o "$ICON_ICNS"
  rm -rf "$TMPICON"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DSNKWall</string>
    <key>CFBundleIdentifier</key>
    <string>party.dmack.DSNKWall</string>
    <key>CFBundleName</key>
    <string>DSNK Wall</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>DSNK Wall listens to the microphone so the visuals can react to the beat.</string>
    <key>NSCameraUsageDescription</key>
    <string>DSNK Wall uses a camera (including Continuity Camera / iPhone) as a layer in Liquid Metal mode.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesigning (required for mic permission prompt)…"
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "Done. Launch with:"
echo "  open \"${APP_DIR}\""
echo "or:"
echo "  \"${APP_DIR}/Contents/MacOS/${BIN_NAME}\""
