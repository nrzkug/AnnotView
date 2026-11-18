import AppKit
import SwiftUI

struct AnnotationSidebar: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @Binding var statusFilter: Annotation.Status?
    @FocusState private var annotationListIsFocused: Bool
    @State private var hoveringFilter = false
    @State private var filterMenuTarget = AnnotationStatusMenuTarget()
    @State private var filterAnchorView: NSView?

    var body: some View {
        Group {
            if documentManager.document == nil {
                ContentUnavailableView("Annotations", systemImage: "text.bubble")
            } else if documentManager.isLoadingAnnotations {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading Acrobat annotations…")
                        .foregroundStyle(.secondary)
                }
            } else if documentManager.annotations.isEmpty {
                ContentUnavailableView {
                    Label("No Annotations Loaded", systemImage: "text.bubble")
                } description: {
                    Text("This document has no supported annotations.")
                }
            } else {
                VStack(spacing: 0) {
                    statusFilterHeader
                    Divider()

                    if threads.isEmpty {
                        emptyFilterState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: annotationSelectionBinding) {
                            ForEach(pageGroups) { pageGroup in
                                Section {
                                    ForEach(pageGroup.threads) { thread in
                                        AnnotationListItem(annotation: thread.root) {
                                            annotationListIsFocused = true
                                        }

                                        ForEach(thread.replies) { reply in
                                            AnnotationListItem(annotation: reply, isReply: true) {
                                                annotationListIsFocused = true
                                            }
                                        }
                                    }
                                } header: {
                                    pageHeader(for: pageGroup)
                                }
                            }
                        }
                        .focused($annotationListIsFocused)
                    }
                }
            }
        }
        .onChange(of: visibleAnnotationIDs) { _, ids in
            documentManager.retainSelectedAnnotations(ids)
        }
    }

    /// Native macOS list selection: the system draws the highlight and
    /// keyboard arrows move between annotations, each selection navigating.
    private var annotationSelectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { documentManager.selectedAnnotationIDs.intersection(visibleAnnotationIDs) },
            set: { ids in
                annotationListIsFocused = true
                documentManager.selectAnnotations(ids)
            }
        )
    }

    private var emptyFilterState: some View {
        VStack(spacing: 10) {
            if let statusFilter {
                Image(statusFilter.iconName, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.tertiary)
                Text("No \(statusFilter.displayName.lowercased()) annotations")
                    .font(.system(size: 12, weight: .semibold))
            }
            Button("Show all annotations") {
                self.statusFilter = nil
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
        }
        .padding(.horizontal, 20)
    }

    private var statusFilterHeader: some View {
        HStack(spacing: 8) {
            statusFilterMenu
            Spacer(minLength: 8)
            Text(summaryText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .help(summaryHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusFilterMenu: some View {
        Button {
            showStatusFilterMenu()
        } label: {
            HStack(spacing: 4) {
                Text(filterTitle)
                    .font(.system(size: 11, weight: .medium))
                Image("chevron-down", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 9, height: 9)
                    .opacity(0.68)
            }
            .foregroundStyle(statusFilter?.tint ?? .primary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(filterTint.opacity(hoveringFilter ? 0.17 : 0.11))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(filterTint.opacity(hoveringFilter ? 0.36 : 0.26), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(MenuAnchorView(view: $filterAnchorView))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hoveringFilter = $0 }
        .help("Filter by status")
    }

    private func showStatusFilterMenu() {
        guard let anchor = filterAnchorView,
              let window = anchor.window else { return }
        let rectOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        filterMenuTarget.onSelect = { next in
            statusFilter = next
        }
        let menu = AnnotationStatusMenu.make(
            selection: statusFilter,
            includeAll: true,
            target: filterMenuTarget
        )
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: max(rectOnScreen.minX, 8), y: rectOnScreen.minY - 6),
            in: nil
        )
    }

    private func pageHeader(for pageGroup: AnnotationPageGroup) -> some View {
        HStack(spacing: 6) {
            Text("Page \(pageGroup.pageIndex + 1)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(pageGroup.threads.reduce(0) { $0 + 1 + $1.replies.count })")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var filterTitle: String {
        statusFilter?.displayName ?? "All statuses"
    }

    private var filterTint: Color {
        statusFilter?.tint ?? .primary
    }

    private var summaryText: String {
        if statusFilter != nil {
            return "\(filteredAnnotationCount) of \(totalAnnotationCount)"
        }
        return "\(pendingCount) pending · \(totalAnnotationCount - pendingCount) reviewed"
    }

    private var summaryHelp: String {
        if let statusFilter {
            return "Showing \(filteredAnnotationCount) of \(totalAnnotationCount) \(statusFilter.displayName.lowercased()) annotations"
        }
        return "\(pendingCount) pending annotations, \(totalAnnotationCount - pendingCount) with a review status"
    }

    private var totalAnnotationCount: Int {
        documentManager.annotations.count
    }

    private var filteredAnnotationCount: Int {
        guard let statusFilter else { return totalAnnotationCount }
        return count(for: statusFilter)
    }

    private var pendingCount: Int {
        count(for: .none)
    }

    private func count(for status: Annotation.Status) -> Int {
        documentManager.annotations.lazy.filter { $0.status == status }.count
    }

    private var threads: [AnnotationThread] {
        guard let statusFilter else {
            return AnnotationThreading.group(documentManager.annotations)
        }
        return documentManager.annotations
            .filter { $0.status == statusFilter }
            .map { AnnotationThread(root: $0, replies: []) }
    }

    private var visibleAnnotationIDs: Set<UUID> {
        Set(threads.flatMap { [$0.root.id] + $0.replies.map(\.id) })
    }

    private var pageGroups: [AnnotationPageGroup] {
        Dictionary(grouping: threads, by: { $0.root.pageIndex })
            .map { AnnotationPageGroup(pageIndex: $0.key, threads: $0.value) }
            .sorted { $0.pageIndex < $1.pageIndex }
    }
}

private struct AnnotationPageGroup: Identifiable {
    var id: Int { pageIndex }
    let pageIndex: Int
    let threads: [AnnotationThread]
}

private struct AnnotationListItem: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveringStatus = false
    @State private var menuTarget = AnnotationStatusMenuTarget()
    @State private var statusAnchorView: NSView?
    let annotation: Annotation
    var isReply = false
    let onFocusList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                kindBadge

                Text(annotation.author?.trimmedNilIfEmpty ?? "Unknown author")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(annotation.author?.trimmedNilIfEmpty ?? "Unknown author")

                if isReply {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .accessibilityLabel("Reply")
                }

                Spacer(minLength: 2)

                statusMenu
            }
            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)

            if let markedText {
                HStack(alignment: .top, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                        .fill(kindTint.opacity(0.75))
                        .frame(width: 2.5)
                    Text(markedText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.72) : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(markedText)
            }

            if let commentText {
                Text(commentText)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, isReply ? 16 : 0)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowSeparator(.visible, edges: .bottom)
        .tag(annotation.id)
        .contextMenu {
            if contextTargets.count == 1 {
                Button("Copy", systemImage: "doc.on.doc") {
                    copyComment()
                }
                .disabled(commentText == nil)

                Button("Edit…", systemImage: "pencil") {
                    documentManager.edit(annotation: annotation)
                }

                Divider()
            }

            Button(
                contextTargets.count == 1 ? "Delete" : "Delete \(contextTargets.count) Annotations",
                systemImage: "trash",
                role: .destructive
            ) {
                let targets = contextTargets
                Task {
                    guard await AnnotationDeleteConfirmation.confirm(
                        count: targets.count,
                        from: NSApp.keyWindow ?? NSApp.mainWindow
                    ) else { return }
                    await documentManager.deleteAnnotations(targets)
                }
            }
            .disabled(deleteIsInProgress)

            Divider()

            Menu("Set Status") {
                statusActions
            }
            .disabled(statusUpdateIsInProgress)
        }
        // List does not write its selection binding when the user clicks the
        // already-selected row.  Treat that click as an explicit navigation so
        // a dismissed preview is restored and the PDF returns to the comment.
        .onTapGesture {
            onFocusList()
            let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
            if modifiers.isEmpty, documentManager.selectedAnnotationIDs == [annotation.id] {
                documentManager.goTo(annotation: annotation)
            }
        }
    }

    private var isSelected: Bool {
        documentManager.selectedAnnotationIDs.contains(annotation.id)
    }

    private var isExpanded: Bool {
        isSelected && documentManager.selectedAnnotationID == annotation.id
    }

    private var kindBadge: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(kindTint.opacity(0.17))
            .overlay {
                Image(annotation.kind.iconName, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(kindInk)
                    .frame(width: 12, height: 12)
            }
            .frame(width: 20, height: 20)
            .help(annotation.kind.displayName)
    }

    private var kindTint: Color {
        Color(
            red: annotation.color.red,
            green: annotation.color.green,
            blue: annotation.color.blue
        )
    }

    private var kindInk: Color {
        isSelected ? .white : kindTint.mix(
            with: colorScheme == .dark ? .white : .black,
            by: colorScheme == .dark ? 0.35 : 0.34
        )
    }

    private var statusControlInk: Color {
        isSelected ? .white : annotation.status.tint
    }

    private var statusMenu: some View {
        Button {
            showStatusMenu()
        } label: {
            if documentManager.updatingAnnotationIDs.contains(annotation.id) {
                ProgressView().controlSize(.mini)
                    .frame(height: 24)
            } else {
                Image(annotation.status.iconName, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(statusControlInk)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(hoveringStatus
                                ? (isSelected ? Color.white.opacity(0.16) : Color.primary.opacity(0.07))
                                : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .background(MenuAnchorView(view: $statusAnchorView))
                    .accessibilityLabel(annotation.status.displayName)
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hoveringStatus = $0 }
        .disabled(statusUpdateIsInProgress)
        .help("\(annotation.status.displayName): \(annotation.status.help)")
    }

    private func showStatusMenu() {
        guard let anchor = statusAnchorView,
              let window = anchor.window else { return }
        let rectOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))

        menuTarget.onSelect = { next in
            if let next { setStatus(next) }
        }
        let menu = AnnotationStatusMenu.make(
            selection: annotation.status,
            includeAll: false,
            target: menuTarget
        )
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: max(rectOnScreen.maxX - menu.size.width, 8), y: rectOnScreen.minY - 6),
            in: nil
        )
    }

    @ViewBuilder
    private var statusActions: some View {
        Picker("Status", selection: statusSelection) {
            ForEach(Annotation.Status.selectableCases, id: \.self) { status in
                Text(status.displayName)
                    .help(status.help)
                    .tag(status)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var statusSelection: Binding<Annotation.Status> {
        Binding(
            get: {
                let statuses = Set(statusTargets.map(\.status))
                return statuses.count == 1 ? statuses.first ?? annotation.status : annotation.status
            },
            set: { setStatus($0) }
        )
    }

    private var statusTargets: [Annotation] {
        guard documentManager.selectedAnnotationIDs.contains(annotation.id) else {
            return [annotation]
        }
        return documentManager.annotations.filter {
            documentManager.selectedAnnotationIDs.contains($0.id)
        }
    }

    private var contextTargets: [Annotation] { statusTargets }

    private var commentText: String? {
        annotation.contents?.trimmedNilIfEmpty
    }

    private var markedText: String? {
        annotation.markedText?.trimmedNilIfEmpty
    }

    private var statusUpdateIsInProgress: Bool {
        statusTargets.contains { documentManager.updatingAnnotationIDs.contains($0.id) }
    }

    private var deleteIsInProgress: Bool {
        documentManager.isSavingAnnotation || contextTargets.allSatisfy { $0.sourceID == nil }
    }

    private func copyComment() {
        guard let commentText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commentText, forType: .string)
    }

    private func setStatus(_ status: Annotation.Status) {
        let targets = statusTargets
        Task { await documentManager.updateStatus(of: targets, to: status) }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
