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

# Bundle the full MuPDF stack: the mutool executable plus the transitive
# closure of all Homebrew dylibs it (and libmupdf) depend on, rewritten to
# @rpath so the app runs on machines without Homebrew or mupdf installed.
MUPDF_PREFIX="/opt/homebrew/opt/mupdf"
MUPDF_DYLIB="$MUPDF_PREFIX/lib/libmupdf.dylib"
MUTOOL_BIN="$MUPDF_PREFIX/bin/mutool"
if [[ ! -f "$MUTOOL_BIN" || ! -f "$MUPDF_DYLIB" ]]; then
  echo "ERROR: mupdf not found at $MUPDF_PREFIX (needed at build time: brew install mupdf)" >&2
  exit 1
fi

echo "==> Bundling mutool and its dylib dependencies"
FRAMEWORKS="$STAGING/Contents/Frameworks"
cp "$MUTOOL_BIN" "$STAGING/Contents/MacOS/mutool"
chmod +w "$STAGING/Contents/MacOS/mutool"

# Recursive dependency collector: queue starts with the two binaries that get
# @rpath links; every Homebrew dylib they reference (transitively, whether by
# absolute path or already-@rpath, as homebrew's brotli does) is copied into
# Frameworks/ and all references are rewritten to @rpath/<name>.
resolve_homebrew_lib() {
  # Find a dylib by basename under /opt/homebrew/opt/*/lib
  local name="$1" candidate
  for candidate in /opt/homebrew/opt/*/lib/"$name"; do
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

rewrite_and_collect() {
  local target="$1" dep_ref dep_path dep_name copied
  while IFS= read -r dep_ref; do
    case "$dep_ref" in
      /opt/homebrew/*) dep_path="$dep_ref" ;;
      @rpath/*)
        dep_name="$(basename "$dep_ref")"
        # Skip if we already bundle it or it resolves inside the app staging.
        [[ -f "$FRAMEWORKS/$dep_name" ]] && continue
        dep_path="$(resolve_homebrew_lib "$dep_name")" || {
          echo "ERROR: cannot resolve @rpath dependency $dep_ref of $target" >&2; exit 1;
        }
        ;;
      *) continue ;;
    esac
    dep_name="$(basename "$dep_path")"
    copied="$FRAMEWORKS/$dep_name"
    install_name_tool -change "$dep_ref" "@rpath/$dep_name" "$target"
    if [[ ! -f "$copied" ]]; then
      cp "$dep_path" "$copied"
      chmod +w "$copied"
      install_name_tool -id "@rpath/$dep_name" "$copied"
      rewrite_and_collect "$copied"
    fi
  done < <(otool -L "$target" | awk '/^\t(\/opt\/homebrew\/|@rpath\/)/ {print $1}')
}

cp "$MUPDF_DYLIB" "$FRAMEWORKS/libmupdf.dylib"
chmod +w "$FRAMEWORKS/libmupdf.dylib"
install_name_tool -id @rpath/libmupdf.dylib "$FRAMEWORKS/libmupdf.dylib"

install_name_tool -change "$MUPDF_DYLIB" @rpath/libmupdf.dylib "$STAGING/Contents/MacOS/$APP_NAME"
install_name_tool -change "$MUPDF_DYLIB" @rpath/libmupdf.dylib "$STAGING/Contents/MacOS/mutool"
install_name_tool -add_rpath @executable_path/../Frameworks "$STAGING/Contents/MacOS/mutool"

rewrite_and_collect "$FRAMEWORKS/libmupdf.dylib"
rewrite_and_collect "$STAGING/Contents/MacOS/mutool"

echo "    bundled $(ls "$FRAMEWORKS"/*.dylib | wc -l | tr -d ' ') dylibs + mutool"

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
