---
name: annota-gakuyu-macos
description: >-
  Create, review, or refactor reusable native macOS app foundations using the
  packaging and app-shell patterns from AnnotView (annota) and Gakuyu. Use this
  skill whenever a task involves a SwiftPM macOS app template, @main scene,
  AppDelegate activation, windows, menus, Settings, appearance/preferences,
  AppKit bridges, bundled resources, Sparkle/update wiring, app-bundle scripts,
  or build/test packaging—even if the user only asks for a small shell change.
  Do not use it for domain features such as PDF annotations, paper catalogs,
  academic search, or Agent behavior unless the app foundation itself changes.
compatibility: Swift 6.x, SwiftPM, macOS 15+; exact APIs depend on the deployment target.
---

# AnnotView + Gakuyu macOS App Foundation Skill

Use this as a project-specific pattern library, not as a replacement for
reading the current source. The bundled references contain compact excerpts
from the two repositories; when the checkout is available, the source files
listed in each reference remain authoritative.

## Scope

This skill extracts app-making and app-packaging code, not product behavior. It
covers the reusable shell around a feature:

- SwiftPM executable entry point and `.app` activation behavior.
- Window scenes, titlebar/toolbar configuration, menus, commands, and Settings.
- Appearance selection and lightweight preference persistence.
- SwiftUI composition with narrowly scoped AppKit bridges.
- Resource bundles, icons, Info.plist, update metadata, staging, signing, and
  install/launch scripts.
- Unit/integration/build checks that prove a packaged app is runnable.

Do not load or reproduce PDF annotation, paper/catalog, academic-provider,
Markdown-editor, BYOK, or Agent Skill implementation details for a shell task.
Those are application features and belong in their own skills.

## Start by locating the boundary

Before editing, identify which product and layer the request touches:

| Request | Read first |
|---|---|
| App entry, window, menu, Settings, appearance | `references/app-shell.md` |
| SwiftUI/AppKit boundary or native window behavior | `references/appkit-bridges.md` |
| Resource bundle, Info.plist, updates, staging, signing | `references/packaging.md` |
| Build/test/release verification | `references/quality.md` |

If more than one boundary changes, read all relevant references before editing.
Only add a process bridge when the new app actually needs one; it is optional
in a generic shell.

## Core architecture

- Keep the app shell independent of product models and services. A new feature
  should plug into the shell rather than redefine its own entry point,
  settings, appearance store, or packaging script.
- Prefer native SwiftUI first. Bridge to AppKit only for activation policy,
  window configuration, native controls, or a platform behavior SwiftUI cannot
  provide reliably.
- Keep app-wide state owned at the app/root level and inject it into scenes or
  feature views. Persist only stable preference values, not view objects or
  transient tasks.
- Keep resource names, executable names, bundle identifiers, URL schemes, and
  release metadata centralized. A build that succeeds but cannot find its
  resources is not a successful app build.
- Keep packaging deterministic and recoverable: stage a complete bundle,
  validate it, sign it, and only then install or launch it.

## Working workflow

1. Read the target module and its nearest tests. Confirm the existing protocol,
   model, and executable names before inventing new ones.
2. Choose the smallest shell surface: scene, root view, command group, setting,
   preference model, resource, or packaging script.
3. Keep platform glue behind a small type and expose testable inputs/outputs.
4. Run the narrow tests first, then the complete build/package checks in
   `references/quality.md`.
5. Report changed files, bundle assumptions, validation commands, and any
   unavailable signing/update dependency.

## Common pitfalls to avoid

- Do not use a passed object as `@State`, unstable `ForEach` identity, or
  un-gated version-specific APIs. Keep preview data self-contained.
- Do not duplicate app-wide menus, Settings, appearance persistence, or bundle
  assembly in individual features.
- Do not assume `swift run` behaves like a launched `.app`: activation policy,
  Dock presence, document handlers, and update services may differ.
- Do not copy a whole source file into a skill reference. Extract the smallest
  canonical pattern and point back to the source-of-truth path.

## Completion checklist

- [ ] The shell is independent of domain-specific feature code.
- [ ] Window, menu, Settings, and preference ownership are explicit.
- [ ] User-visible failure and missing-resource cases are handled.
- [ ] The app bundle contains the resources, icon, and metadata it expects.
- [ ] Tests cover the changed shell or packaging contract.
- [ ] The final response names validation results and any remaining limitation.

## Reference router

- `references/app-shell.md` — app entry, scenes, menus, Settings, state, and
  appearance samples.
- `references/appkit-bridges.md` — activation policy, AppKit hosting, and window
  integration patterns.
- `references/packaging.md` — Info.plist, resource bundles, staging, signing,
  Sparkle/update metadata, and install scripts.
- `references/quality.md` — focused tests, build commands, and release sanity.

The excerpts are derived from the local AnnotView and Gakuyu repositories for
app-foundation guidance. Preserve the original repositories' licenses when
redistributing source-derived material.
