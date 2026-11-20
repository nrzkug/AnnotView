#!/usr/bin/env bash
# Build a debug app bundle and run it against a PDF, for local UI work.
#
#   ./Scripts/run-dev.sh                     # build + run with the bundled sample
#   ./Scripts/run-dev.sh path/to/file.pdf    # build + run with your own PDF
#   ./Scripts/run-dev.sh --stage             # build the dev bundle only
#   ./Scripts/run-dev.sh --no-build          # relaunch the staged bundle
#   ./Scripts/run-dev.sh --open              # launch through LaunchServices
#
# Unlike Scripts/package.sh this keeps everything in dist-dev/, builds debug,
# never touches /Applications, and runs the binary in the foreground so
# stdout/stderr (SwiftUI warnings, print statements) stay in the terminal.
set -euo pipefail

APP_NAME="AnnotView"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD=1
STAGE_ONLY=0
LAUNCH_VIA_OPEN=0
PDF=""
DEFAULT_PDF="$ROOT/docs/samples/annotview-review-demo.pdf"

for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --stage) STAGE_ONLY=1 ;;
    --no-build) BUILD=0 ;;
    --open) LAUNCH_VIA_OPEN=1 ;;
    -*)
      echo "Unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      PDF="$arg"
      ;;
  esac
done

if [[ -z "$PDF" && -f "$DEFAULT_PDF" ]]; then
  PDF="$DEFAULT_PDF"
fi

APP="$ROOT/dist-dev/$APP_NAME.app"

if [[ "$BUILD" -eq 1 ]]; then
  echo "==> Building debug binary"
  swift build --product "$APP_NAME"
  BIN_DIR="$(swift build --show-bin-path)"
else
  BIN_DIR="$(swift build --show-bin-path)"
  if [[ ! -d "$APP" ]]; then
    echo "No staged dev app at $APP; drop --no-build." >&2
    exit 1
  fi
fi

if [[ "$BUILD" -eq 1 ]]; then
  echo "==> Staging $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
  cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
  cp -R "$BIN_DIR/AnnotView_AnnotView.bundle" "$APP/Contents/Resources/"
  cp "$ROOT/AppBundle/Info.plist" "$APP/Contents/Info.plist"
  if [[ -f "$ROOT/AppBundle/$APP_NAME.icns" ]]; then
    cp "$ROOT/AppBundle/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"
  else
    cp "$ROOT/AppBundle/AppIcon.png" "$APP/Contents/Resources/$APP_NAME.png"
  fi
  if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
    cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  fi

  echo "==> Signing (ad hoc)"
  if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
    codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework"
  fi
  codesign --force --sign - --timestamp=none "$APP"
fi

if [[ "$STAGE_ONLY" -eq 1 ]]; then
  echo "Staged: $APP"
  exit 0
fi

if [[ -n "$PDF" && ! -f "$PDF" ]]; then
  echo "PDF not found: $PDF" >&2
  exit 1
fi

pkill -f "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

if [[ "$LAUNCH_VIA_OPEN" -eq 1 ]]; then
  if [[ -n "$PDF" ]]; then
    open -n "$APP" --args "$PDF"
  else
    open -n "$APP"
  fi
  echo "Launched: $APP"
  exit 0
fi

echo "==> Running (Ctrl+C to quit)"
if [[ -n "$PDF" ]]; then
  echo "    PDF: $PDF"
  exec "$APP/Contents/MacOS/$APP_NAME" "$PDF"
else
  exec "$APP/Contents/MacOS/$APP_NAME"
fi
