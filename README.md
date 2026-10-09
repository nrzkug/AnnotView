# AnnotView

AnnotView is a lightweight native macOS PDF reader for reviewing Adobe Acrobat annotations.

![AnnotView displaying a selectable Acrobat highlight and its review comment](docs/images/annot_preview.png)

## Why I built it

I built AnnotView for my own workflow: my advisor reviews papers in Adobe Acrobat, while I only need a fast way to read the annotations and work through the comments. Acrobat feels too heavy for that, and Preview does not always render Acrobat text markup correctly. AnnotView is a small, focused reader—not a full PDF editor.

## Features

- Renders highlights, underlines, strikeouts, text notes, and Insert-Text carets.
- Creates and edits Acrobat-compatible highlights, underlines, strikethroughs, sticky notes, and insert-text markers.
- Supports Acrobat review states: Accepted, Rejected, Cancelled, and Completed.

## Requirements

- macOS 26 or later

## Install a release

Download the macOS ZIP from Releases, unzip it, and move `AnnotView.app` to Applications. The app is ad-hoc signed, so macOS may block its first launch. Control-click the app and choose **Open**, or allow it in **System Settings → Privacy & Security**.

## Run and build

Building from source requires `brew install mupdf` (build-time only — `Scripts/package.sh` bundles `mutool` and all its libraries into the app, so installed copies do **not** need mupdf or Homebrew).

Build from source:

```sh
swift build -c release --product AnnotView
```

## License

AnnotView is licensed under the [GNU Affero General Public License v3](LICENSE).
