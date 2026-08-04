# AnnotView

AnnotView is a lightweight native macOS PDF reader for reviewing Adobe Acrobat annotations.

![AnnotView displaying a selectable Acrobat highlight and its review comment](docs/images/annot_preview.png)

## Why I built it

I built AnnotView for my own workflow: my advisor reviews papers in Adobe Acrobat, while I only need a fast way to read the annotations and work through the comments. Acrobat feels too heavy for that, and Preview does not always render Acrobat text markup correctly. AnnotView is a small, focused reader—not a full PDF editor.

Built with SwiftUI, AppKit, and PDFKit, AnnotView focuses on reading papers and processing review comments. It uses MuPDF to handle Acrobat annotations more reliably, including text markup positioned with `QuadPoints`.

## Features

- Renders highlights, underlines, strikeouts, and text notes.
- Shows annotation authors, dates, comments, replies, and colors.
- Supports Acrobat review states: Accepted, Rejected, Cancelled, and Completed.
- Provides comment copying, annotation navigation, and document search.

Ink annotations can be parsed but are not yet rendered.

## Requirements

- macOS 26 or later
- Xcode with the macOS 26 SDK or later
- MuPDF `mutool`

Install MuPDF with Homebrew:

```sh
brew install mupdf
```

AnnotView looks for `mutool` in `MUTOOL_PATH`, the app bundle, common Homebrew locations, and `PATH`.

## Run and build

Run from source:

```sh
swift run AnnotView
```

Build the release executable:

```sh
swift build -c release --product AnnotView
```

Use `swift build -c release --show-bin-path` to locate the executable.

## License

AnnotView is licensed under the [GNU Affero General Public License v3](LICENSE).
