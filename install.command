#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
DEST="$HOME/Applications/M1120 Scanner.app"
SCANNER="$HOME/m1120-sane-test/install/bin/scanimage"

print ""
print "=== M1120 Scanner v1.3.2 — source installer ==="
print ""

if [[ ! -x "$SCANNER" ]]; then
  print "ERROR: Missing patched SANE scanner executable: $SCANNER" >&2
  print "Build it first: zsh scripts/build-patched-sane.command" >&2
  exit 1
fi
if [[ ! -x /opt/homebrew/bin/magick && ! -x /usr/local/bin/magick ]]; then
  print 'ERROR: ImageMagick missing; run brew install imagemagick' >&2
  exit 1
fi
SWIFTC="$(xcrun --sdk macosx --find swiftc 2>/dev/null || true)"
SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [[ -z "$SWIFTC" || -z "$SDK" || ! -d "$SDK" ]]; then
  print 'ERROR: Install Apple Command Line Tools: xcode-select --install' >&2
  exit 1
fi
TARGET="$(uname -m)-apple-macosx13.0"
BUILD_DIR="$(mktemp -d /tmp/m1120-appkit-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
BUNDLE="$BUILD_DIR/M1120 Scanner.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

print "Compiling AppKit scanner for $TARGET..."
if ! "$SWIFTC" -sdk "$SDK" -target "$TARGET" -swift-version 5 -parse-as-library -Onone \
  -framework AppKit -framework CoreGraphics -framework ImageIO -framework CoreText -framework Vision \
  "$ROOT/M1120Scanner.swift" -o "$BUNDLE/Contents/MacOS/M1120Scanner" \
  2>"$BUILD_DIR/compile.log"; then
  print 'ERROR: App compilation failed:' >&2
  cat "$BUILD_DIR/compile.log" >&2
  exit 1
fi

print 'Creating application icon locally...'
if ! "$SWIFTC" -sdk "$SDK" -target "$TARGET" -framework AppKit \
   "$ROOT/scripts/generate-icon.swift" -o "$BUILD_DIR/generate-icon" \
   2>"$BUILD_DIR/icon-compile.log"; then
  print 'ERROR: Icon generator failed:' >&2
  cat "$BUILD_DIR/icon-compile.log" >&2
  exit 1
fi
"$BUILD_DIR/generate-icon" "$BUILD_DIR/source-icon.png"
ICONSET="$BUILD_DIR/M1120Scanner.iconset"
mkdir -p "$ICONSET"
for entry in '16x16:16' '16x16@2x:32' '32x32:32' '32x32@2x:64' \
             '128x128:128' '128x128@2x:256' '256x256:256' '256x256@2x:512' \
             '512x512:512' '512x512@2x:1024'; do
  part="${entry%%:*}"
  pixels="${entry##*:}"
  sips -s format png -z "$pixels" "$pixels" "$BUILD_DIR/source-icon.png" \
     --out "$ICONSET/icon_${part}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/M1120Scanner.icns"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>M1120 Scanner</string>
  <key>CFBundleDisplayName</key><string>M1120 Scanner</string>
  <key>CFBundleExecutable</key><string>M1120Scanner</string>
  <key>CFBundleIdentifier</key><string>local.m1120.scanner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>M1120Scanner.icns</string>
  <key>CFBundleShortVersionString</key><string>1.3.2</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"
mkdir -p "$HOME/Applications"
BACKUP=""
if [[ -e "$DEST" ]]; then
  ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$ID" != "local.m1120.scanner" ]]; then
    print 'ERROR: Another app already exists at the destination.' >&2
    exit 1
  fi
  BACKUP="$BUILD_DIR/M1120 Scanner (previous).app"
  /bin/mv "$DEST" "$BACKUP"
fi
if ! /usr/bin/ditto "$BUNDLE" "$DEST"; then
  print 'ERROR: Copy failed; restoring previous app.' >&2
  /bin/rm -rf "$DEST"
  if [[ -n "$BACKUP" ]]; then /bin/mv "$BACKUP" "$DEST"; fi
  exit 1
fi
print "Installed: $DEST"
print 'No printer drivers or Homebrew packages were modified.'
open "$DEST"
