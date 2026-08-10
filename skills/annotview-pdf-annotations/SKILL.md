---
name: annotview-pdf-annotations
description: >-
  Extract, understand, and write Acrobat PDF annotations (highlights,
  underlines, strikethroughs, sticky notes, Insert-Text carets) in PDFs,
  using AnnotView's annotool CLI. Use whenever the user mentions PDF
  annotations, review comments, reviewer feedback, marginalia, or PDF markup
  - even if they don't name the tool. Examples: "what did the reviewer
  comment on in this PDF", "summarize the annotations in response.pdf",
  "turn these reviewer comments into a task list", "where did the professor
  mark things", "add an annotation / insert-text mark to this PDF". Also
  use when the user wants AI-generated review feedback written back into a
  PDF as Acrobat-compatible annotations, or wants the annotation object
  structure itself inspected (rects, quads, state, appearance).
---

# PDF Annotations

Read Acrobat annotations from PDFs and write new ones back, in the format
Acrobat itself produces. Everything goes through the `annotool` command line
tool, installed by the AnnotView app (Settings → Command Line Tool). Use
`annotool` for all annotation work — it handles every coordinate and format
pitfall, so do not shell out to `mutool`/the JS directly.

## Prerequisites

- `annotool` on PATH (install from AnnotView → Settings → Command Line Tool).
  Requires `mutool` (`brew install mupdf`) and Python 3.
- If `annotool` is not on PATH, use
  `/Applications/AnnotView.app/Contents/Resources/annotool` instead, or ask the
  user to install it from the app's Settings.

## Quick start (AI workflow)

The single most useful command — annotations plus the text they cover, ready
for summarization/triage:

```sh
annotool show paper.pdf
```

Output groups each annotation with its comment text and the covered text, e.g.:

```
--- Page 4  obj441  strikeout  rjin  [completed]
    comment: realize
    covered: "finite blocklength for the polar code. Would using more powerful decoders (like SC list)"
```

For machine consumption use `--json`; `show --json` enriches each annotation
with `coveredText` — the exact text the markup or comment is attached to. This
is the field an AI should base its analysis on.

## Coordinate conventions

- **All coordinates are PDF user space**: origin bottom-left, y up; page size
  reported per page in `read --json` (`pageWidth`/`pageHeight`).
- `--rect` arguments are `x0,y0,x1,y1` in that space.
- `add-caret` snaps `--y` to the text baseline automatically (Acrobat behavior).

## Reading

| Command | Purpose |
|---|---|
| `read <pdf>` | One line per annotation (page, kind, author, rect, comment). |
| `read <pdf> --json` | Structured: pages with `pageWidth/Height`, annotations with `sourceID`, `kind`, `bounds`, `quadPoints`, `contents`, `author`, `createdDate`, `color` (RGBA), `status`, `inReplyToSourceID`, `statusTargetSourceID`. |
| `show <pdf> [--page N] [--author X] [--kind Y]` | Annotations merged with covered text — the primary command. |
| `show <pdf> --json` | Structured version with `coveredText` per annotation. |
| `text <pdf> [--page N] [--json]` | Page text lines with user-space boxes. |
| `baseline <pdf> --page N --x X --y Y` | Baseline (y) of the text line near a position. |

`--page` is 1-based. `--kind` values: `highlight|underline|strikeout|note|ink|caret`.

## Writing (modifies the PDF in place — copy first when experimenting)

| Command | Purpose |
|---|---|
| `add-markup <pdf> --kind highlight\|underline\|strikeout --page N --rect x0,y0,x1,y1 [--contents "…"] [--author X] [--color C] [--opacity O]` | Mark up a region. |
| `add-note <pdf> --page N --x X --y Y [--contents "…"]` | Sticky note at a point. |
| `add-caret <pdf> --page N --x X --y Y [--contents "…"]` | Acrobat Insert-Text caret (baseline-snapped). |
| `update <pdf> --id OBJ --contents "…" [--author X] [--color C]` | Edit contents/author/color. |
| `move <pdf> --id OBJ --rect x0,y0,x1,y1 [--output out.pdf]` | Move a sticky note or caret to a new rect. |
| `delete <pdf> --id OBJ` | Remove an annotation. |
| `status <pdf> --id OBJ --status accepted\|rejected\|cancelled\|completed\|marked\|unmarked\|none` | Set Acrobat review state. |

- `--id` is the object number (`objNNN`) shown by `read`/`show`.
- `--color` presets: `highlight`, `underline`, `strikeout`, `red`, `green`,
  `yellow`, `blue`, `purple`, `caret-red`, `caret-purple`, or `r,g,b` floats.
- `--output out.pdf` writes to a new file instead of in place.

## Worked examples

Summarize reviewer comments (group by author/page/status, use `coveredText` +
`comment`):

```sh
annotool show review.pdf --json
```

Draft a reply checklist:

```sh
annotool show review.pdf | grep "comment:"
```

Insert an AI review comment as an Acrobat caret, baseline-snapped:

```sh
annotool add-caret response.pdf \
  --page 3 --x 300 --y 600 \
  --contents "The latency analysis should compare against arithmetic coding." \
  --author "AI Reviewer"
```

## What annotool handles for you (don't re-derive)

- Coordinates are normalized to PDF user space with per-page sizes.
- MuPDF normalizes Caret annotations to a fixed 20x14 box and its `getBounds`
  ignores the real `/Rect`; annotool reads/writes Acrobat's compact 8.85x7.2
  rect with the standard leaf appearance, centered on the text baseline —
  identical to Acrobat's own output.
- Acrobat "replace" edits (Caret parent + IRT StrikeOut child) are merged into
  one annotation; the duplicate caret is skipped.
- `status` writes Acrobat's `/StateModel`/`/State`; `update` on a caret
  preserves its rect.
- Covered-text matching (`show`) already transforms text coordinates correctly.
