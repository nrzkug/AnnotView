import AppKit
import SwiftUI

/// Everything a preview popover needs to render and report back for one
/// annotation. Kept as a value so a visible popover can swap previews in place.
struct AnnotationPreviewConfiguration {
    let annotation: Annotation
    /// Opens the card with its comment editor already active.
    let startEditing: Bool
    let onSave: @MainActor (String) async -> Bool
    let onUpdateStatus: @MainActor (Annotation.Status) async -> Bool
    let onHeightChange: @MainActor (CGFloat) -> Void
    /// The user interacted with the card; keep it open as a pinned preview.
    let onPin: @MainActor () -> Void
    /// Temporary popover behaviour override while a status menu is tracking.
    let onStatusMenuTracking: @MainActor (Bool) -> Void
}

@MainActor
final class AnnotationPreviewModel: ObservableObject {
    @Published var configuration: AnnotationPreviewConfiguration

    init(configuration: AnnotationPreviewConfiguration) {
        self.configuration = configuration
    }
}

/// Hosts a single preview card and crossfades whenever the presented
/// annotation changes. Hovering from one annotation to a neighbour therefore
/// never closes the window and reopens it elsewhere; the card melts into the
/// next one while the popover itself just repositions.
struct AnnotationPreviewSwapView: View {
    @ObservedObject var model: AnnotationPreviewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            AnnotationPopoverView(
                annotation: model.configuration.annotation,
                startEditing: model.configuration.startEditing,
                onSave: model.configuration.onSave,
                onUpdateStatus: model.configuration.onUpdateStatus,
                onHeightChange: model.configuration.onHeightChange,
                onPin: model.configuration.onPin,
                onStatusMenuTracking: model.configuration.onStatusMenuTracking
            )
            .id(model.configuration.annotation.id)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.09), value: model.configuration.annotation.id)
    }
}

struct AnnotationPopoverView: View {
    let annotation: Annotation
    let onSave: @MainActor (String) async -> Bool
    let onUpdateStatus: @MainActor (Annotation.Status) async -> Bool
    let onHeightChange: @MainActor (CGFloat) -> Void
    let onPin: @MainActor () -> Void
    let onStatusMenuTracking: @MainActor (Bool) -> Void

    @State private var commentText: String
    @State private var status: Annotation.Status
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaving = false
    @State private var copied = false
    @State private var fullTextHeight: CGFloat?
    @State private var hoveringCopy = false
    @State private var hoveringStatus = false
    @State private var menuTarget = AnnotationStatusMenuTarget()
    @State private var statusAnchorView: NSView?
    @Environment(\.colorScheme) private var colorScheme

    static let width: CGFloat = 368
    private static let textWidth: CGFloat = 340
    private static let textFontSize: CGFloat = 13.3
    private static let textLineSpacing: CGFloat = 4
    private static let maxCommentHeight: CGFloat = 480

    init(
        annotation: Annotation,
        startEditing: Bool = false,
        onSave: @escaping @MainActor (String) async -> Bool,
        onUpdateStatus: @escaping @MainActor (Annotation.Status) async -> Bool,
        onHeightChange: @escaping @MainActor (CGFloat) -> Void,
        onPin: @escaping @MainActor () -> Void,
        onStatusMenuTracking: @escaping @MainActor (Bool) -> Void
    ) {
        self.annotation = annotation
        self.onSave = onSave
        self.onUpdateStatus = onUpdateStatus
        self.onHeightChange = onHeightChange
        self.onPin = onPin
        self.onStatusMenuTracking = onStatusMenuTracking
        let contents = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _commentText = State(initialValue: contents)
        _status = State(initialValue: annotation.status)
        _isEditing = State(initialValue: startEditing)
        _draft = State(initialValue: contents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isEditing {
                editorSection
            } else {
                commentSection
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            onHeightChange(height)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            kindIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(authorText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(dateText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if isEditing {
                HStack(spacing: 3) {
                    GhostIconButton(icon: "x", help: "Cancel editing", tint: .secondary) {
                        cancelEditing()
                    }
                    GhostIconButton(
                        icon: "check",
                        help: "Save comment",
                        tint: .accentColor,
                        enabled: !isSaving
                    ) {
                        commitEditing()
                    }
                }
            } else {
                HStack(spacing: 3) {
                    copyButton
                    GhostIconButton(icon: "pencil", help: "Edit comment", tint: .secondary) {
                        beginEditing()
                    }
                }
            }

            statusPill
        }
        .padding(.init(top: 12, leading: 14, bottom: 0, trailing: 12))
    }

    private var kindIcon: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(annotationTint.opacity(0.17))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(annotationInk.opacity(0.30), lineWidth: 1)
            }
            .overlay {
                Image(annotation.kind.iconName, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(annotationInk)
                    .frame(width: 15, height: 15)
            }
            .frame(width: 27, height: 27)
    }

    private var copyButton: some View {
        GhostIconButton(
            icon: copied ? "check" : "copy",
            help: copied ? "Copied" : "Copy comment",
            tint: copied ? .green : .secondary,
            background: copied ? Color.green.opacity(0.12) : nil,
            isHovering: $hoveringCopy
        ) {
            copyComment()
        }
    }

    private var statusPill: some View {
        Button {
            // Choosing a status is a deliberate interaction: pin the preview so
            // the hover dismiss monitor cannot close it while the menu is open.
            onPin()
            showStatusMenu()
        } label: {
            HStack(spacing: 4) {
                icon(status.iconName, size: 11)
                Text(status.displayName)
                    .font(.system(size: 11, weight: .medium))
                icon("chevron-down", size: 9)
                    .opacity(0.68)
            }
            .foregroundStyle(statusTint)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(statusTint.opacity(hoveringStatus ? 0.17 : 0.11))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(statusTint.opacity(hoveringStatus ? 0.36 : 0.26), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(MenuAnchorView(view: $statusAnchorView))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hoveringStatus = $0 }
        .help("\(status.displayName): \(status.help)")
    }

    private func showStatusMenu() {
        guard let anchor = statusAnchorView,
              let window = anchor.window else { return }
        let rectOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        menuTarget.onSelect = { next in
            if let next { applyStatus(next) }
        }
        // A semitransient popover closes when a menu item is clicked (the menu
        // is another window); switch to app-defined behaviour while tracking so
        // the status change does not also dismiss the preview.
        onStatusMenuTracking(true)
        defer { onStatusMenuTracking(false) }

        let menu = AnnotationStatusMenu.make(
            selection: status,
            includeAll: false,
            target: menuTarget
        )
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: max(rectOnScreen.maxX - menu.size.width, 8), y: rectOnScreen.minY - 6),
            in: nil
        )
    }

    private func icon(_ name: String, size: CGFloat) -> some View {
        Image(name, bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private var commentSection: some View {
        Group {
            if effectiveFullTextHeight > Self.maxCommentHeight + 0.5 {
                ScrollView(.vertical) {
                    commentText(for: displayText)
                }
                .frame(height: Self.maxCommentHeight)
            } else {
                commentText(for: displayText)
            }
        }
        .padding(.init(top: 10, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            measurableCommentText(for: displayText)
                .padding(.horizontal, 14)
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    fullTextHeight = $0
                }
        }
    }

    private func commentText(for text: String) -> some View {
        measurableCommentText(for: text)
            .textSelection(.enabled)
    }

    private func measurableCommentText(for text: String) -> some View {
        Text(text)
            .font(.system(size: Self.textFontSize))
            .foregroundStyle(.primary)
            .lineSpacing(Self.textLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorSection: some View {
        InlineCommentEditor(
            text: $draft,
            font: .systemFont(ofSize: Self.textFontSize),
            textColor: .labelColor,
            lineSpacing: Self.textLineSpacing,
            onCancel: { cancelEditing() },
            onSubmit: { commitEditing() }
        )
        .frame(height: editorHeight)
        .padding(.init(top: 10, leading: 14, bottom: 14, trailing: 14))
        .disabled(isSaving)
    }

    private var editorHeight: CGFloat {
        let measured = Self.measuredTextHeight(draft.isEmpty ? " " : draft)
        return min(Self.maxCommentHeight, max(21, ceil(measured)))
    }

    private var displayText: String {
        commentText.isEmpty ? "No comment text" : commentText
    }

    private var authorText: String {
        annotation.author?.nilIfEmpty ?? "Unknown author"
    }

    private var dateText: String {
        guard let date = annotation.createdDate else { return "No date" }
        return date.formatted(date: .abbreviated, time: .shortened)
            .replacingOccurrences(of: " at ", with: " · ")
    }

    private var annotationTint: Color {
        Color(
            red: annotation.color.red,
            green: annotation.color.green,
            blue: annotation.color.blue
        )
    }

    private var annotationInk: Color {
        annotationTint.mix(with: colorScheme == .dark ? .white : .black, by: colorScheme == .dark ? 0.35 : 0.34)
    }

    private var statusTint: Color {
        status.tint
    }

    private var effectiveFullTextHeight: CGFloat {
        fullTextHeight ?? Self.measuredTextHeight(displayText)
    }

    private func beginEditing() {
        guard !isEditing else { return }
        draft = commentText
        isEditing = true
    }

    private func cancelEditing() {
        guard !isSaving else { return }
        draft = commentText
        isEditing = false
    }

    private func commitEditing() {
        guard !isSaving else { return }
        let next = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        Task {
            let saved = await onSave(next)
            isSaving = false
            if saved {
                commentText = next
                isEditing = false
            }
        }
    }

    private func applyStatus(_ next: Annotation.Status) {
        guard next != status else { return }
        let previous = status
        status = next
        Task {
            let saved = await onUpdateStatus(next)
            if !saved { status = previous }
        }
    }

    private func copyComment() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commentText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
        }
    }

    /// Approximate card height used to size the popover before its first layout pass.
    static func preferredHeight(for comment: String) -> CGFloat {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let measured = measuredTextHeight(text.isEmpty ? " " : text)
        let clamped = min(measured, maxCommentHeight)
        return max(84, 63 + ceil(clamped))
    }

    static func measuredTextHeight(_ text: String) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = textLineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: textFontSize),
            .paragraphStyle: style
        ]
        return (text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).height
    }
}

private struct GhostIconButton: View {
    let icon: String
    let help: String
    var tint: Color = .secondary
    var background: Color?
    var enabled = true
    var isHovering: Binding<Bool>?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(icon, bundle: .module)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)
                .frame(width: 24, height: 24)
                .background(background ?? ((isHovering?.wrappedValue ?? hovering) ? Color.primary.opacity(0.06) : Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { value in
            if let isHovering {
                isHovering.wrappedValue = value
            } else {
                hovering = value
            }
        }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

private final class InlineCommentTextView: NSTextView {
    var onCancel: (() -> Void)?
    var onSubmit: (() -> Void)?
    private var didFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didFocus else { return }
        didFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: self.string.count, length: 0))
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.command) {
                onSubmit?()
                return
            }
            if event.modifierFlags.contains(.shift) {
                // Shift+Return inserts a newline instead of committing.
                insertNewlineIgnoringFieldEditor(nil)
                return
            }
        }
        super.keyDown(with: event)
    }
}

private struct InlineCommentEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    let lineSpacing: CGFloat
    let onCancel: () -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.contentView.drawsBackground = false

        let textView = InlineCommentTextView()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = textColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: AnnotationPopoverView.width - 28,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.onCancel = onCancel
        textView.onSubmit = onSubmit

        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        textView.defaultParagraphStyle = style
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: style
        ]

        textView.delegate = context.coordinator
        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? InlineCommentTextView else { return }
        context.coordinator.parent = self
        textView.onCancel = onCancel
        textView.onSubmit = onSubmit
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        textView.textColor = textColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        let width = scroll.contentSize.width > 0 ? scroll.contentSize.width : AnnotationPopoverView.width - 28
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineCommentEditor

        init(_ parent: InlineCommentEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
