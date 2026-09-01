import Foundation

/// Shared infrastructure for locating and invoking MuPDF's `mutool` command.
/// Feature services remain responsible for their scripts, arguments, outputs,
/// and user-facing error context.
struct MuPDFTool: Sendable {
    enum ToolError: Error {
        case executableNotFound
        case processFailed(status: Int32, message: String)
    }

    private let executableURL: URL?

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    func run(
        script: URL,
        arguments: [String],
        capturesOutput: Bool = false
    ) async throws -> Data {
        let executable = try executableURL ?? Self.findExecutable()
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = capturesOutput ? Pipe() : nil
            let errors = Pipe()
            process.executableURL = executable
            process.arguments = ["run", script.path] + arguments
            process.standardOutput = output ?? FileHandle.nullDevice
            process.standardError = errors

            try process.run()
            let streams = await withTaskGroup(of: (isStandardOutput: Bool, data: Data).self) { group in
                group.addTask {
                    (true, output?.fileHandleForReading.readDataToEndOfFile() ?? Data())
                }
                group.addTask {
                    (false, errors.fileHandleForReading.readDataToEndOfFile())
                }

                process.waitUntilExit()
                var standardOutput = Data()
                var standardError = Data()
                for await stream in group {
                    if stream.isStandardOutput {
                        standardOutput = stream.data
                    } else {
                        standardError = stream.data
                    }
                }
                return (standardOutput, standardError)
            }

            guard process.terminationStatus == 0 else {
                let rawMessage = String(data: streams.1, encoding: .utf8) ?? "Unknown MuPDF error"
                throw ToolError.processFailed(
                    status: process.terminationStatus,
                    message: rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return streams.0
        }.value
    }

    static func bundledScript(named name: String) -> URL? {
        if let resources = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: resources.appendingPathComponent("AnnotView_AnnotView.bundle", isDirectory: true)
           ),
           let script = packagedBundle.url(forResource: name, withExtension: "js")
                ?? packagedBundle.url(
                    forResource: name,
                    withExtension: "js",
                    subdirectory: "MuPDF"
                ) {
            return script
        }
        return Bundle.module.url(forResource: name, withExtension: "js")
            ?? Bundle.module.url(
                forResource: name,
                withExtension: "js",
                subdirectory: "MuPDF"
            )
    }

    private static func findExecutable() throws -> URL {
        let fileManager = FileManager.default
        var candidates = [ProcessInfo.processInfo.environment["MUTOOL_PATH"]].compactMap { $0 }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "mutool")?.path {
            candidates.append(bundled)
        }
        candidates += ["/opt/homebrew/bin/mutool", "/usr/local/bin/mutool"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/mutool" }
        }
        guard let match = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            throw ToolError.executableNotFound
        }
        return URL(fileURLWithPath: match)
    }
}
