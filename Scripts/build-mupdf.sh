#!/usr/bin/env bash
# Build a minimal MuPDF toolchain from source and stage ready-to-ship artifacts
# into .build/mupdf-dist/. Idempotent: reuses the downloaded tarball and the
# compiled build directory when they are up to date.
#
# Why not Homebrew's mupdf? Its libmupdf.dylib is ~50 MB (the entire Noto font
# collection is compiled into the library as static data) and it drags in a
# ~15 MB closure of optional-feature dylibs (tesseract OCR, leptonica, glib,
# libcrypto, ...). AnnotView only needs the fz_* JSON helpers used by the C
# bridge, none of which use embedded fonts or OCR. The minimal build below
# produces a single ~6 MB libmupdf.dylib that depends only on libSystem.
#
# Artifacts:
#   .build/mupdf-dist/lib/libmupdf.dylib  id: @rpath/libmupdf.dylib
# Public headers are vendored in Sources/CMuPDF/include/mupdf (checked into git).
#
# Requirements: Xcode Command Line Tools (clang + make). No Homebrew needed.
set -euo pipefail

MUPDF_VERSION="1.28.5"
MUPDF_SHA256="98a5c10cda20c3992cdf76ff6b2a1149c32bd79cc796d3f703230b1185b7e934"
MUPDF_URL="https://mupdf.com/downloads/archive/mupdf-${MUPDF_VERSION}-source.tar.gz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Heavy cache (tarball + extracted source + build tree) lives OUTSIDE .build so
# `swift package clean` / Xcode clean doesn't force a re-download + full recompile.
CACHE="$ROOT/.mupdf-cache"
DIST="$ROOT/.build/mupdf-dist"
SRC="$CACHE/mupdf-${MUPDF_VERSION}-source"
# Flags that shape the build (also part of the cache key):
#   tofu*        drop embedded Noto/SIL/CJK fallback fonts (AnnotView renders via PDFKit)
#   html/extract/xps/svg/brotli=no  drop engines unused by the C bridge
# Keep the bundled library compatible with the app on newer build hosts.
export MACOSX_DEPLOYMENT_TARGET=26.0
MUPDF_FLAGS="shared=yes build=release tofu=yes tofu_cjk=yes tofu_cjk_ext=yes tofu_cjk_lang=yes html=no extract=no xps=no svg=no brotli=no"
STAMP="$CACHE/.built-$(echo "$MUPDF_VERSION $MUPDF_FLAGS $MACOSX_DEPLOYMENT_TARGET" | shasum -a 256 | cut -d' ' -f1)"

mkdir -p "$CACHE"

# Fail fast if the vendored headers don't match the version we're about to
# build — otherwise the C bridge compiles against different headers than the
# dylib was built with.
HEADER_VERSION="$(sed -n 's/^#define FZ_VERSION "\([^"]*\)"/\1/p' \
  "$ROOT/Sources/CMuPDF/include/mupdf/fitz/version.h" | head -1)"
if [[ "$HEADER_VERSION" != "$MUPDF_VERSION" ]]; then
  echo "ERROR: vendored headers are MuPDF $HEADER_VERSION but this script builds $MUPDF_VERSION." >&2
  echo "       Update Sources/CMuPDF/include/mupdf from the new tarball's include/ dir." >&2
  exit 1
fi

if [[ ! -f "$STAMP" ]]; then
  TARBALL="$CACHE/mupdf-${MUPDF_VERSION}-source.tar.gz"
  if [[ ! -f "$TARBALL" ]]; then
    echo "==> Downloading MuPDF ${MUPDF_VERSION} source"
    curl -fSL --retry 3 -o "$TARBALL" "$MUPDF_URL"
  fi
  echo "==> Verifying tarball checksum"
  echo "$MUPDF_SHA256  $TARBALL" | shasum -a 256 --check --status

  echo "==> Extracting"
  rm -rf "$SRC"
  tar -xzf "$TARBALL" -C "$CACHE"

  echo "==> Building minimal libmupdf.dylib (release, no fonts/OCR)"
  # `libs` only: the C bridge links libmupdf.dylib directly. Never build the
  # default `all` target: it includes the OpenGL GUI (freeglut), which fails
  # to compile on stock macOS SDKs.
  (cd "$SRC" && make $MUPDF_FLAGS libs -j"$(sysctl -n hw.ncpu)")

  touch "$STAMP"
else
  echo "==> MuPDF ${MUPDF_VERSION} minimal build cached in $CACHE"
fi

# Locate the build output dir (name carries the feature suffix).
OUT_DIR="$(printf '%s\n' "$SRC"/build/shared-release-tofu*/ | head -1)"
if [[ ! -f "$OUT_DIR/libmupdf.dylib" ]]; then
  echo "ERROR: expected build outputs missing under $OUT_DIR" >&2
  exit 1
fi

echo "==> Staging artifacts to $DIST"
rm -rf "$DIST"
mkdir -p "$DIST/lib"

cp "$OUT_DIR/libmupdf.dylib" "$DIST/lib/libmupdf.dylib"
chmod +w "$DIST/lib/libmupdf.dylib"
# Canonical install name so anything linking against it records @rpath directly.
install_name_tool -id @rpath/libmupdf.dylib "$DIST/lib/libmupdf.dylib"

# Public headers were checked against MUPDF_VERSION above; nothing else to copy.

# The dylib's install name is @rpath/libmupdf.dylib, so `swift run`/`swift test`
# need to resolve it next to the built products. Drop symlinks in every layout
# SwiftPM may use (classic .build/{debug,release} and xcodebuild-backed
# .build/out/Products/{Debug,Release}); the test target already carries rpath
# @loader_path/../../.., and executables carry rpath @executable_path.
for d in \
  "$ROOT/.build/debug" \
  "$ROOT/.build/release" \
  "$ROOT/.build/out/Products/Debug" \
  "$ROOT/.build/out/Products/Release"; do
  mkdir -p "$d"
  ln -sf "$(cd "$ROOT" && pwd)/.build/mupdf-dist/lib/libmupdf.dylib" "$d/libmupdf.dylib"
done

codesign --force --sign - "$DIST/lib/libmupdf.dylib" >/dev/null 2>&1 || true

echo "==> mupdf-dist ready:"
ls -la "$DIST/lib"
