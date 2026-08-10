#!/usr/bin/env bash
# Build, package, sign, and install AnnotView.app from a single source of truth.
#
#   ./Scripts/package.sh          # build + stage in dist/ + install to /Applications + launch
#   ./Scripts/package.sh --stage  # build + stage in dist/ only (no install/launch)
#
# Sources of truth:
#   - Swift sources        Sources/AnnotView
#   - MuPDF JS scripts     Sources/AnnotView/Resources/MuPDF/*.js   (bundled via SwiftPM resources)
#   - App shell assets     AppBundle/Info.plist, AppBundle/AnnotView.icns
#   - CLI tool             annotool/annotool
set -euo pipefail

APP_NAME="AnnotView"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAGE_ONLY=0
if [[ "${1:-}" == "--stage" ]]; then STAGE_ONLY=1; fi

STAGING="$ROOT/dist/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

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
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$STAGING/Contents/MacOS/$APP_NAME"
cp "AppBundle/Info.plist" "$STAGING/Contents/Info.plist"
cp "AppBundle/$APP_NAME.icns" "$STAGING/Contents/Resources/$APP_NAME.icns"
cp -R "$BUNDLE_SRC" "$STAGING/Contents/Resources/$BUNDLE_NAME"
cp "annotool/annotool" "$STAGING/Contents/Resources/annotool"
chmod +x "$STAGING/Contents/Resources/annotool"

echo "==> Signing (ad hoc)"
codesign --force --sign - --timestamp=none "$STAGING"

if [[ "$STAGE_ONLY" -eq 1 ]]; then
  echo "Staged: $STAGING"
  exit 0
fi

echo "==> Installing to $DEST"
pkill -f "$APP_NAME.app" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$STAGING" "$DEST"
codesign --force --sign - --timestamp=none "$DEST"

echo "==> Launching"
open "$DEST"
echo "Done: $DEST"
