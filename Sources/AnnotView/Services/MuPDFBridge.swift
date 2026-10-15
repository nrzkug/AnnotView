import CMuPDF
import Foundation

/// Swift-side wrapper for the C functions in `CMuPDF/MuPDFBridge.c`.
///
/// The bridge speaks JSON both ways, so this layer deals in `String`/`Data`
/// only and owns all of the unsafe-pointer marshalling, `out_error` cleanup,
/// and temp-file plumbing the C API requires.
enum MuPDFBridge {
    enum Failure: LocalizedError {
        case operationFailed(action: String, detail: String)
        case emptyOutput(action: String)

        var errorDescription: String? {
            switch self {
            case .operationFailed(let action, let detail):
                "MuPDF failed to \(action): \(detail)"
            case .emptyOutput(let action):
                "MuPDF produced no output while trying to \(action)."
            }
        }
    }

    /// Returns the annotation dump produced by `mupdf_bridge_parse_annotations`.
    static func annotationsJSON(at pdfURL: URL) throws -> Data {
        var json: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let success = pdfURL.path.withCString { path in
            mupdf_bridge_parse_annotations(path, &json, &error)
        }
        defer {
            if let json { mupdf_bridge_free(json) }
            if let error { mupdf_bridge_free(error) }
        }
        try check(success, error: error, action: "parse annotations")
        guard let json else {
            throw Failure.emptyOutput(action: "parse annotations")
        }
        return Data(bytes: json, count: strlen(json))
    }

    /// Applies the JSON-encoded operations (createMarkup/createNote/createCaret/
    /// move/update/delete) and saves the result to `output`.
    static func writeAnnotations(from input: URL, to output: URL, operationsJSON: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = withPaths(input, output) { inPath, outPath in
            operationsJSON.withCString { json in
                mupdf_bridge_write_annotations(inPath, outPath, json, &error)
            }
        }
        defer { if let error { mupdf_bridge_free(error) } }
        try check(success, error: error, action: "save annotations")
    }

    /// Sets /StateModel and /State on the annotations named by the JSON-encoded
    /// update list and saves the result to `output`.
    static func updateStatuses(from input: URL, to output: URL, statusesJSON: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = withPaths(input, output) { inPath, outPath in
            statusesJSON.withCString { json in
                mupdf_bridge_update_statuses(inPath, outPath, json, &error)
            }
        }
        defer { if let error { mupdf_bridge_free(error) } }
        try check(success, error: error, action: "update review states")
    }

    /// Saves a copy of `input` with every annotation removed to `output`.
    static func stripAnnotations(from input: URL, to output: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        let success = withPaths(input, output) { inPath, outPath in
            mupdf_bridge_strip_annotations(inPath, outPath, &error)
        }
        defer { if let error { mupdf_bridge_free(error) } }
        try check(success, error: error, action: "prepare the PDF for display")
    }

    /// Creates a unique temporary directory, yields a file URL inside it, and
    /// removes the directory afterwards.
    static func withTemporaryOutput<R>(
        named name: String,
        _ body: (URL) throws -> R
    ) throws -> R {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotView-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory.appendingPathComponent(name))
    }

    /// Atomically replaces `source` with the PDF the bridge wrote to `output`.
    static func replaceAtomically(_ source: URL, with output: URL, action: String) throws {
        let data = try Data(contentsOf: output)
        guard !data.isEmpty else { throw Failure.emptyOutput(action: action) }
        try data.write(to: source, options: .atomic)
    }

    private static func check(
        _ success: Bool,
        error: UnsafeMutablePointer<CChar>?,
        action: String
    ) throws {
        guard success else {
            throw Failure.operationFailed(
                action: action,
                detail: error.flatMap { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    private static func withPaths<R>(
        _ input: URL,
        _ output: URL,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> R
    ) -> R {
        input.path.withCString { inPath in
            output.path.withCString { outPath in
                body(inPath, outPath)
            }
        }
    }
}
