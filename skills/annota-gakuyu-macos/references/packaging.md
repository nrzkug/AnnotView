# Generic `.app` packaging and updates

Sources: `AnnotView/Scripts/package.sh`, `AnnotView/AppBundle/Info.plist`,
`Gakuyu/Scripts/run-dev.sh`, `Gakuyu/Scripts/build-app.sh`, and
`Gakuyu/Packaging/`.

The app shell should have one packaging entry point with explicit stages:

```text
swift build -c release
  → stage Example.app/Contents/{MacOS,Resources,Frameworks}
  → copy binary, Info.plist, icon, resource bundles, optional helpers
  → verify expected resources and paths
  → ad-hoc sign or Developer ID sign
  → optionally install and launch
```

## Stage-only switch

Keep staging separate from installation so CI and local inspection do not need
to overwrite `/Applications`:

```sh
STAGE_ONLY=0
if [[ "${1:-}" == "--stage" ]]; then STAGE_ONLY=1; fi

STAGING="$ROOT/dist/$APP_NAME.app"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$STAGING/Contents/MacOS/$APP_NAME"
cp "Packaging/Info.plist" "$STAGING/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$STAGING"

if [[ "$STAGE_ONLY" -eq 1 ]]; then
    echo "Staged: $STAGING"
    exit 0
fi

cp -R "$STAGING" "/Applications/$APP_NAME.app"
open "/Applications/$APP_NAME.app"
```

The real script must use the app's actual icon/resource names and should fail
fast on missing inputs. Avoid broad destructive targets; remove only the
known staging destination.

## Info.plist essentials

Use a project-owned `Info.plist` as the source of truth for:

- `CFBundleIdentifier`, `CFBundleExecutable`, display/name/version values.
- `LSMinimumSystemVersion` and document/URL type declarations when needed.
- `CFBundleIconFile` or the modern icon asset arrangement.
- Sparkle feed/public-key metadata only when Sparkle is actually included.

Do not copy product-specific document handlers, URL schemes, bridge names, or
update URLs into a generic template without renaming them.

## Resource and framework verification

Package complete SwiftPM resource bundles and frameworks before signing. Add a
small verification loop for resources whose drift would make the app fail at
runtime. The check should compare generated bundle inputs against source inputs
and report the exact missing/stale path.
