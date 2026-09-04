import AppKit

enum AppDiagnostics {
    /// Deliberately excludes file names, paths, comment text, and raw errors,
    /// which can contain private document content or MuPDF command arguments.
    @MainActor
    static func copy(
        documentManager: PDFDocumentManager,
        appearance: AppAppearance,
        updater: AppUpdater
    ) {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unversioned"
        let report = """
        AnnotView \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(architecture)
        Appearance: \(appearance.label)
        Updates: \(updater.diagnosticStatus)
        MuPDF: \(MuPDFTool.diagnosticAvailability)
        Document open: \(documentManager.document != nil)
        Pages: \(documentManager.pageCount)
        Current page: \(documentManager.document == nil ? "None" : String(documentManager.selectedPageIndex + 1))
        Annotations loaded: \(documentManager.annotations.count)
        Loading annotations: \(documentManager.isLoadingAnnotations)
        Saving annotations: \(documentManager.isSavingAnnotation)
        Updating review states: \(documentManager.updatingAnnotationIDs.count)
        Error currently present: \(documentManager.errorMessage != nil)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "Unknown"
        #endif
    }
}
