import AppKit
import SwiftUI

struct AnnotationPopoverView: View {
    let annotation: Annotation
    let height: CGFloat
    let onEdit: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: annotation.popupSymbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(annotation.author?.nilIfEmpty ?? "Unknown author")
                        .font(.headline)
                    HStack(spacing: 5) {
                        Text(annotation.popupKindName)
                        if let date = annotation.createdDate {
                            Text("·")
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        }
                        Text("·")
                        Label(annotation.status.displayName, systemImage: annotation.status.symbolName)
                            .foregroundStyle(annotation.status.tint)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            ScrollView {
                Text(annotation.contents?.nilIfEmpty ?? "No comment text")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Spacer()
                Button("Edit", systemImage: "pencil") { onEdit() }
            }
        }
        .padding(14)
        .frame(width: 330, height: height, alignment: .topLeading)
    }
}

struct AnnotationEditorView: View {
    let annotation: Annotation
    let onSave: @MainActor (String, Annotation.Color) async -> Bool
    let onDelete: @MainActor () async -> Bool
    let onCancel: @MainActor () -> Void

    @State private var contents: String
    @State private var color: SwiftUI.Color
    @State private var isSaving = false
    @FocusState private var commentIsFocused: Bool

    init(
        annotation: Annotation,
        onSave: @escaping @MainActor (String, Annotation.Color) async -> Bool,
        onDelete: @escaping @MainActor () async -> Bool,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.annotation = annotation
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _contents = State(initialValue: annotation.contents ?? "")
        _color = State(
            initialValue: SwiftUI.Color(
                red: annotation.color.red,
                green: annotation.color.green,
                blue: annotation.color.blue,
                opacity: annotation.color.alpha
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: annotation.popupSymbolName)
                    .foregroundStyle(color)
                Text("Edit \(annotation.popupKindName)")
                    .font(.headline)
                Spacer()
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Comment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $contents)
                    .focused($commentIsFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    }
            }
            .frame(minHeight: 150)

            HStack {
                Button("Delete", role: .destructive) {
                    isSaving = true
                    Task {
                        _ = await onDelete()
                        isSaving = false
                    }
                }
                .disabled(isSaving)

                Spacer()

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)

                Button("Save") {
                    isSaving = true
                    Task {
                        _ = await onSave(contents, pdfColor)
                        isSaving = false
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSaving)
            }
        }
        .padding(14)
        .frame(width: 360, height: 286)
        .onAppear { commentIsFocused = true }
    }

    private var pdfColor: Annotation.Color {
        guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else {
            return annotation.color
        }
        return annotation.color.replacingRGB(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Annotation {
    var popupKindName: String {
        switch kind {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeout: "Strikeout"
        case .note: "Note"
        case .ink: "Ink"
        case .caret: "Insertion"
        }
    }

    var popupSymbolName: String {
        switch kind {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .note: "note.text"
        case .ink: "scribble"
        case .caret: "text.cursor"
        }
    }
}
