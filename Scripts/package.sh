#!/usr/bin/env bash
# Build, package, sign, and install AnnotView.app from a single source of truth.
#
#   ./Scripts/package.sh          # build + stage in dist/ + install to /Applications + launch
#   ./Scripts/package.sh --stage  # build + stage in dist/ only (no install/launch)
#
# Sources of truth:
#   - Swift sources        Sources/AnnotView
#   - App shell assets     AppBundle/Info.plist, AppBundle/AnnotView.icns
set -euo pipefail

APP_NAME="AnnotView"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAGE_ONLY=0
if [[ "${1:-}" == "--stage" ]]; then STAGE_ONLY=1; fi

STAGING="$ROOT/dist/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

echo "==> Preparing minimal MuPDF build (headers + lib for linking)"
"$ROOT/Scripts/build-mupdf.sh"

echo "==> Building release binary"
swift build -c release --product "$APP_NAME"

BIN_DIR="$(swift build -c release --show-bin-path)"
BUNDLE_SRC="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
BUNDLE_NAME="$(basename "$BUNDLE_SRC")"
JS_SRC_DIR="Sources/AnnotView/Resources/MuPDF"

echo "==> Verifying bundled MuPDF scripts match sources"
for script in annotations write_annotation update_annotation_status strip_annotations; do
  if ! diff -q "$JS_SRC_DIR/$script.js" "$BUNDLE_SRC/Contents/Resources/$script.js" >/dev/null; then
    echo "ERROR: $script.js in the built bundle differs from $JS_SRC_DIR/$script.js" >&2
    echo "       (SwiftPM resources are stale; delete .build and rebuild)" >&2
    exit 1
  fi
done
echo "    all 4 scripts in sync"

echo "==> Assembling $STAGING"
rm -rf "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources" "$STAGING/Contents/Frameworks"
cp "$BIN_DIR/$APP_NAME" "$STAGING/Contents/MacOS/$APP_NAME"
cp "AppBundle/Info.plist" "$STAGING/Contents/Info.plist"
if [[ -f "AppBundle/$APP_NAME.icns" ]]; then
  cp "AppBundle/$APP_NAME.icns" "$STAGING/Contents/Resources/$APP_NAME.icns"
else
  cp "AppBundle/AppIcon.png" "$STAGING/Contents/Resources/$APP_NAME.png"
fi
cp -R "$BUNDLE_SRC" "$STAGING/Contents/Resources/$BUNDLE_NAME"

# SwiftPM keeps Sparkle alongside the executable. Copy its complete framework
# (including the relaunch helper) into the app bundle before signing.
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
  cp -R "$BIN_DIR/Sparkle.framework" "$STAGING/Contents/Frameworks/Sparkle.framework"
fi

# Bundle the minimal source-built MuPDF stack (Scripts/build-mupdf.sh): a
# single libmupdf.dylib that depends only on libSystem, plus a small mutool
# linked against it via @rpath. No Homebrew dylibs are needed at runtime.
MUPDF_DIST="$ROOT/.build/mupdf-dist"
MUTOOL_BIN="$MUPDF_DIST/bin/mutool"
MUPDF_DYLIB="$MUPDF_DIST/lib/libmupdf.dylib"
if [[ ! -f "$MUTOOL_BIN" || ! -f "$MUPDF_DYLIB" ]]; then
  echo "ERROR: build-mupdf.sh did not produce $MUPDF_DIST artifacts" >&2
  exit 1
fi

echo "==> Bundling mutool and libmupdf.dylib"
FRAMEWORKS="$STAGING/Contents/Frameworks"
cp "$MUTOOL_BIN" "$STAGING/Contents/MacOS/mutool"
cp "$MUPDF_DYLIB" "$FRAMEWORKS/libmupdf.dylib"
# The staged artifacts already carry @rpath install names/refs from
# build-mupdf.sh; nothing to rewrite here.

echo "    bundled mutool + libmupdf.dylib"

echo "==> Signing (ad hoc)"
if [[ -d "$STAGING/Contents/Frameworks/Sparkle.framework" ]]; then
  codesign --force --sign - --timestamp=none "$STAGING/Contents/Frameworks/Sparkle.framework"
fi
for binary in "$STAGING/Contents/MacOS/mutool" "$FRAMEWORKS"/*.dylib; do
  codesign --force --sign - --timestamp=none "$binary"
done
codesign --force --sign - --timestamp=none "$STAGING"

if [[ "$STAGE_ONLY" -eq 1 ]]; then
  echo "Staged: $STAGING"
  exit 0
fi

echo "==> Installing to $DEST"
pkill -f "$APP_NAME.app" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST"
cp -R "$STAGING" "$DEST"
codesign --force --sign - --timestamp=none "$DEST"

echo "==> Launching"
open "$DEST"
echo "Done: $DEST"
