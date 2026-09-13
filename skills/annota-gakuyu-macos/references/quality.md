# Quality checks for an app foundation

The goal is to prove both the SwiftPM executable and the packaged `.app` are
usable. A successful compile alone is not enough.

## Focused checks

```sh
swift build
swift test
swift build -c release
./Scripts/package.sh --stage
```

For Gakuyu-style repositories, add Rust checks only when the app shell includes
Rust helpers:

```sh
cargo check --manifest-path Rust/Cargo.toml
cargo test --manifest-path Rust/Cargo.toml --workspace
```

## What to test

- Appearance values load from injected `UserDefaults` and persist changes.
- Menu actions route to the intended root state or command handler.
- `swift run` activates as a regular app and closes according to the intended
  last-window policy.
- The staged app contains the executable, Info.plist, icon, resource bundles,
  frameworks, and optional helpers at the paths used by runtime lookup.
- Missing resources produce a clear packaging failure instead of a launch-time
  crash.
- If an optional subprocess bridge exists, its lookup and cancellation behavior
  are tested independently from product commands.

## Release sanity

Inspect the staged bundle with `codesign --display --verbose=2` and verify the
bundle identifier, executable, minimum OS, icon, URL/document declarations,
resource paths, and update metadata. Keep signing credentials and private update
keys out of the repository and out of the skill.
