import AppKit
import SwiftUI

struct AnnotationSidebar: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @Binding var statusFilter: Annotation.Status?

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

                    if threads.isEmpty {
                        ContentUnavailableView(
                            "No Matching Annotations",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: annotationSelectionBinding) {
                            ForEach(pageGroups) { pageGroup in
                                Section("Page \(pageGroup.pageIndex + 1)") {
                                    ForEach(pageGroup.threads) { thread in
                                        AnnotationListItem(annotation: thread.root)

                                        ForEach(thread.replies) { reply in
                                            AnnotationListItem(annotation: reply, isReply: true)
                                        }
                                    }
                                }
                            }
                        }
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
            set: documentManager.selectAnnotations
        )
    }

    private var statusFilterHeader: some View {
        statusFilterControls
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(sidebarBackground)
    }

    private var statusFilterControls: some View {
        HStack(spacing: 10) {
            Text("Annotations")
                .fontWeight(.semibold)

            Spacer(minLength: 8)

            Picker("Status", selection: $statusFilter) {
                Text("All").tag(nil as Annotation.Status?)
                ForEach(Annotation.Status.selectableCases, id: \.self) { status in
                    Text(status.displayName).tag(status as Annotation.Status?)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Text("\(filteredAnnotationCount) / \(totalAnnotationCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .help("Showing \(filteredAnnotationCount) of \(totalAnnotationCount) annotations")
        }
        .font(.callout)
    }

    private var totalAnnotationCount: Int {
        documentManager.annotations.count
    }

    private var sidebarBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var filteredAnnotationCount: Int {
        guard let statusFilter else { return totalAnnotationCount }
        return documentManager.annotations.lazy.filter { $0.status == statusFilter }.count
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
    let annotation: Annotation
    var isReply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(annotation.author?.trimmedNilIfEmpty ?? "Unknown author")
                    .font(.subheadline.weight(.semibold))
                if isReply {
                    Text("Reply")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                statusMenu
            }
            if let contents = annotation.contents?.trimmedNilIfEmpty {
                Text(contents)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(metadataLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, isReply ? 20 : 0)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Task { await documentManager.deleteAnnotations(targets) }
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
            if documentManager.selectedAnnotationIDs.contains(annotation.id) {
                documentManager.goTo(annotation: annotation, preservingMultipleSelection: true)
            }
        }
    }

    private var metadataLine: String {
        let kind = annotation.kind.rawValue.capitalized
        if let date = annotation.createdDate {
            return "\(kind) · \(date.formatted(date: .numeric, time: .omitted))"
        }
        return kind
    }

    private var statusMenu: some View {
        Menu {
            statusActions
        } label: {
            if documentManager.updatingAnnotationIDs.contains(annotation.id) {
                ProgressView().controlSize(.small)
            } else {
                Label(annotation.status.displayName, systemImage: annotation.status.symbolName)
            }
        }
        .menuStyle(.borderlessButton)
        .tint(annotation.status.tint)
        .fixedSize()
        .disabled(statusUpdateIsInProgress)
        .help("Status: \(annotation.status.displayName)")
    }

    @ViewBuilder
    private var statusActions: some View {
        ForEach(Annotation.Status.selectableCases, id: \.self) { status in
            Button {
                setStatus(status)
            } label: {
                if statusTargets.allSatisfy({ $0.status == status }) {
                    Label(status.displayName, systemImage: "checkmark")
                } else {
                    Text(status.displayName)
                }
            }
        }
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
