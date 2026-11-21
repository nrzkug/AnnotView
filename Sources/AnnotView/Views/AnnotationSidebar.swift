import AppKit
import SwiftUI

struct AnnotationSidebar: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @Binding var statusFilter: Annotation.Status?
    @FocusState private var annotationListIsFocused: Bool
    @State private var hoveringFilter = false
    @State private var filterMenuTarget = AnnotationStatusMenuTarget()
    @State private var filterAnchorView: NSView?
    @State private var cachedSnapshot: SidebarSnapshot?

    private var snapshot: SidebarSnapshot {
        if let cachedSnapshot,
           cachedSnapshot.annotations == documentManager.annotations,
           cachedSnapshot.statusFilter == statusFilter {
            return cachedSnapshot
        }
        return SidebarSnapshot.build(
            annotations: documentManager.annotations,
            statusFilter: statusFilter
        )
    }

    var body: some View {
        let current = snapshot
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
                    statusFilterHeader(snapshot: current)
                    Divider()

                    if current.threads.isEmpty {
                        emptyFilterState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            List(selection: annotationSelectionBinding(visibleIDs: current.visibleAnnotationIDs)) {
                                ForEach(current.pageGroups) { pageGroup in
                                    Section {
                                        ForEach(pageGroup.threads) { thread in
                                            AnnotationListItem(
                                                annotation: thread.root,
                                                isListFocused: annotationListIsFocused
                                            ) {
                                                annotationListIsFocused = true
                                            }
                                            .id(thread.root.id)

                                            ForEach(thread.replies) { reply in
                                                AnnotationListItem(
                                                    annotation: reply,
                                                    isReply: true,
                                                    isListFocused: annotationListIsFocused
                                                ) {
                                                    annotationListIsFocused = true
                                                }
                                                .id(reply.id)
                                            }
                                        }
                                    } header: {
                                        pageHeader(for: pageGroup)
                                    }
                                }
                            }
                            .focused($annotationListIsFocused)
                            .onChange(of: documentManager.selectedAnnotationID) { _, selectedID in
                                guard let selectedID,
                                      current.visibleAnnotationIDs.contains(selectedID) else { return }
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    proxy.scrollTo(selectedID, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { refreshSnapshot() }
        .onChange(of: documentManager.annotations) { refreshSnapshot() }
        .onChange(of: statusFilter) { refreshSnapshot() }
        .onChange(of: current.visibleAnnotationIDs) { _, ids in
            documentManager.retainSelectedAnnotations(ids)
        }
    }

    private func refreshSnapshot() {
        let next = SidebarSnapshot.build(
            annotations: documentManager.annotations,
            statusFilter: statusFilter
        )
        if cachedSnapshot != next {
            cachedSnapshot = next
        }
    }

    /// Native macOS list selection: the system draws the highlight and
    /// keyboard arrows move between annotations, each selection navigating.
    private func annotationSelectionBinding(visibleIDs: Set<UUID>) -> Binding<Set<UUID>> {
        Binding(
            get: { documentManager.selectedAnnotationIDs.intersection(visibleIDs) },
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
            Button("Show All Annotations") {
                self.statusFilter = nil
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 20)
    }

    private func statusFilterHeader(snapshot: SidebarSnapshot) -> some View {
        HStack(spacing: 8) {
            statusFilterMenu
            Spacer(minLength: 8)
            Text(summaryText(for: snapshot))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .help(summaryHelp(for: snapshot))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            if snapshot.totalCount > 0 && snapshot.totalCount > snapshot.pendingCount {
                GeometryReader { proxy in
                    let fraction = CGFloat(snapshot.totalCount - snapshot.pendingCount) / CGFloat(snapshot.totalCount)
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: proxy.size.width, height: 2)
                        Rectangle()
                            .fill(Color.green.opacity(0.85))
                            .frame(width: proxy.size.width * fraction, height: 2)
                            .animation(.easeInOut(duration: 0.25), value: snapshot.pendingCount)
                    }
                }
                .frame(height: 2)
                .allowsHitTesting(false)
            }
        }
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
            .padding(.horizontal, 8)
            .frame(height: 26)
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
        .accessibilityLabel("Filter annotations by status: \(filterTitle)")
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
        .padding(.trailing, 14)
    }

    private var filterTitle: String {
        statusFilter?.displayName ?? "All Statuses"
    }

    private var filterTint: Color {
        statusFilter?.tint ?? .primary
    }

    private func summaryText(for snapshot: SidebarSnapshot) -> String {
        if statusFilter != nil {
            return "\(snapshot.filteredCount) of \(snapshot.totalCount)"
        }
        return "\(snapshot.pendingCount) pending · \(snapshot.totalCount - snapshot.pendingCount) reviewed"
    }

    private func summaryHelp(for snapshot: SidebarSnapshot) -> String {
        if let statusFilter {
            return "Showing \(snapshot.filteredCount) of \(snapshot.totalCount) \(statusFilter.displayName.lowercased()) annotations"
        }
        return "\(snapshot.pendingCount) pending annotations, \(snapshot.totalCount - snapshot.pendingCount) with a review status"
    }
}

private struct SidebarSnapshot: Equatable {
    let annotations: [Annotation]
    let statusFilter: Annotation.Status?
    let threads: [AnnotationThread]
    let pageGroups: [AnnotationPageGroup]
    let visibleAnnotationIDs: Set<UUID>
    let totalCount: Int
    let pendingCount: Int
    let filteredCount: Int

    static func build(
        annotations: [Annotation],
        statusFilter: Annotation.Status?
    ) -> SidebarSnapshot {
        var pending = 0
        var filteredCount = 0
        var filteredAnnotations: [Annotation] = []
        if statusFilter != nil {
            filteredAnnotations.reserveCapacity(annotations.count)
        }
        for annotation in annotations {
            if annotation.status == .none {
                pending += 1
            }
            if let statusFilter, annotation.status == statusFilter {
                filteredCount += 1
                filteredAnnotations.append(annotation)
            }
        }
        let threads: [AnnotationThread] = if statusFilter != nil {
            filteredAnnotations.map { AnnotationThread(root: $0, replies: []) }
        } else {
            AnnotationThreading.group(annotations)
        }
        var visibleIDs = Set<UUID>()
        visibleIDs.reserveCapacity(threads.count)
        for thread in threads {
            visibleIDs.insert(thread.root.id)
            for reply in thread.replies {
                visibleIDs.insert(reply.id)
            }
        }
        let pageGroups = Dictionary(grouping: threads, by: { $0.root.pageIndex })
            .map { AnnotationPageGroup(pageIndex: $0.key, threads: $0.value) }
            .sorted { $0.pageIndex < $1.pageIndex }

        return SidebarSnapshot(
            annotations: annotations,
            statusFilter: statusFilter,
            threads: threads,
            pageGroups: pageGroups,
            visibleAnnotationIDs: visibleIDs,
            totalCount: annotations.count,
            pendingCount: pending,
            filteredCount: statusFilter == nil ? annotations.count : filteredCount
        )
    }
}

private struct AnnotationPageGroup: Identifiable, Equatable {
    var id: Int { pageIndex }
    let pageIndex: Int
    let threads: [AnnotationThread]
}

private struct AnnotationListItem: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hoveringStatus = false
    @State private var menuTarget = AnnotationStatusMenuTarget()
    @State private var statusAnchorView: NSView?
    let annotation: Annotation
    var isReply = false
    var isListFocused = false
    let onFocusList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                kindBadge

                Text(annotation.author?.trimmedNilIfEmpty ?? "Unknown author")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(annotation.author?.trimmedNilIfEmpty ?? "Unknown author")

                if let shortDateText {
                    Text("· \(shortDateText)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(isEmphasizedSelection ? Color.white.opacity(0.68) : Color.secondary.opacity(0.75))
                        .lineLimit(1)
                        .layoutPriority(-1)
                }

                if isReply {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .accessibilityLabel("Reply")
                }

                Spacer(minLength: 2)

                statusMenu
                    .padding(.trailing, -6)
            }
            .foregroundStyle(isEmphasizedSelection ? Color.white.opacity(0.85) : Color.secondary)

            if let markedText {
                HStack(alignment: .top, spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                        .fill(kindTint.opacity(0.75))
                        .frame(width: 2.5)
                    Text(markedText)
                        .font(.system(size: commentText == nil ? 12.5 : 12))
                        .foregroundStyle(
                            commentText == nil
                                ? (isEmphasizedSelection ? Color.white : (isDimmed ? Color.secondary : Color.primary))
                                : (isEmphasizedSelection ? Color.white.opacity(0.78) : Color.secondary)
                        )
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
                    .foregroundStyle(isEmphasizedSelection ? Color.white : (isDimmed ? Color.secondary : Color.primary))
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, markedText == nil ? 0 : 2)
            } else if markedText == nil {
                Text(annotation.kind.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(isEmphasizedSelection ? Color.white.opacity(0.75) : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(isDimmed ? 0.76 : 1)
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

    private var isEmphasizedSelection: Bool {
        isSelected && isListFocused && controlActiveState == .key
    }

    private var isResolved: Bool {
        annotation.status == .completed
            || annotation.status == .rejected
            || annotation.status == .cancelled
    }

    private var isDimmed: Bool {
        isResolved && !isEmphasizedSelection
    }

    private var isExpanded: Bool {
        isSelected && documentManager.selectedAnnotationID == annotation.id
    }

    private var kindBadge: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isEmphasizedSelection ? Color.white.opacity(0.18) : kindTint.opacity(0.17))
            .overlay {
                Image(annotation.kind.iconName, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(kindInk)
                    .frame(width: 12, height: 12)
            }
            .frame(width: 20, height: 20)
            .accessibilityLabel(annotation.kind.displayName)
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
        isEmphasizedSelection ? .white : kindTint.mix(
            with: colorScheme == .dark ? .white : .black,
            by: colorScheme == .dark ? 0.35 : 0.34
        )
    }

    private var statusControlInk: Color {
        isEmphasizedSelection ? .white : annotation.status.tint
    }

    private var statusMenu: some View {
        Button {
            showStatusMenu()
        } label: {
            if documentManager.updatingAnnotationIDs.contains(annotation.id) {
                ProgressView().controlSize(.mini)
                    .frame(width: 26, height: 26)
            } else {
                Image(annotation.status.iconName, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(statusControlInk)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hoveringStatus
                                ? (isEmphasizedSelection ? Color.white.opacity(0.16) : Color.primary.opacity(0.07))
                                : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .background(MenuAnchorView(view: $statusAnchorView))
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hoveringStatus = $0 }
        .disabled(statusUpdateIsInProgress)
        .accessibilityLabel("Status: \(annotation.status.displayName)")
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

    private var shortDateText: String? {
        guard let date = annotation.createdDate,
              Calendar.current.component(.year, from: date) >= 1980 else {
            return nil
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
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
