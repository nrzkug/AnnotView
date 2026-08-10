import AppKit
import Foundation

/// Installs the `annotool` command line tool so AI agents (and shells) can use
/// it directly from PATH without knowing where AnnotView lives.
///
/// Install is a single symlink into PATH pointing at the app's own copy:
///   <bin-dir>/annotool -> /Applications/AnnotView.app/Contents/Resources/annotool
///
/// No files are copied: annotool finds the MuPDF bridge scripts relative to
/// itself inside the app bundle (Contents/Resources/AnnotView_AnnotView.bundle),
/// so there is exactly one copy of the tooling and it stays in sync with the
/// installed app automatically.
@MainActor
final class CLIInstaller: ObservableObject {
    @Published private(set) var installedURL: URL?
    @Published private(set) var binOnPath = false
    @Published private(set) var isWorking = false
    @Published private(set) var lastMessage: String?

    private let fileManager: FileManager
    private let annotoolURL: URL
    private let binCandidates: [URL]
    private let pathCheckEnabled: Bool

    init(
        annotoolURL: URL? = nil,
        binCandidates: [URL]? = nil,
        pathCheckEnabled: Bool = true,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let bundleResources = annotoolURL ?? (Bundle.main.resourceURL?.appendingPathComponent("annotool"))
        self.annotoolURL = bundleResources ?? URL(fileURLWithPath: "/")
        let home = fileManager.homeDirectoryForCurrentUser
        // ~/.local/bin first: the XDG convention for user-installed tools (owned
        // by the user, not another package manager's namespace). Homebrew's
        // /opt/homebrew/bin and /usr/local/bin are only fallbacks.
        self.binCandidates = binCandidates ?? [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent("bin", isDirectory: true),
        ]
        self.pathCheckEnabled = pathCheckEnabled
        refresh()
    }

    var isInstalled: Bool { installedURL != nil }

    // MARK: - Status

    func refresh() {
        installedURL = Self.findSymlink(
            named: "annotool",
            in: binCandidates,
            resolvingTo: annotoolURL,
            fileManager: fileManager
        )
        if pathCheckEnabled {
            Task { await refreshPathStatus() }
        }
    }

    private func refreshPathStatus() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-ic", "command -v annotool"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            binOnPath = !String(data: data, encoding: .utf8)!
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        } catch {
            binOnPath = false
        }
    }

    // MARK: - Install / uninstall

    @discardableResult
    func install() -> Bool {
        isWorking = true
        defer { isWorking = false }
        guard fileManager.fileExists(atPath: annotoolURL.path) else {
            lastMessage = "annotool is missing from the app bundle."
            return false
        }
        guard let binDirectory = firstUsableBinDirectory() else {
            lastMessage = "No writable directory on PATH found (tried ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, ~/bin)."
            return false
        }
        let symlink = binDirectory.appendingPathComponent("annotool")
        try? fileManager.removeItem(at: symlink)
        do {
            try fileManager.createSymbolicLink(at: symlink, withDestinationURL: annotoolURL)
            installedURL = symlink
            lastMessage = "Installed at \(symlink.path)"
            Task { await refreshPathStatus() }
            return true
        } catch {
            lastMessage = "Install failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func uninstall() -> Bool {
        isWorking = true
        defer { isWorking = false }
        for candidate in binCandidates {
            let symlink = candidate.appendingPathComponent("annotool")
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: symlink.path),
               URL(fileURLWithPath: destination).standardizedFileURL.path
                   == annotoolURL.standardizedFileURL.path {
                try? fileManager.removeItem(at: symlink)
            }
        }
        installedURL = nil
        binOnPath = false
        lastMessage = "Uninstalled."
        return true
    }

    // MARK: - Helpers

    private func firstUsableBinDirectory() -> URL? {
        for candidate in binCandidates {
            if !fileManager.fileExists(atPath: candidate.path) {
                // Only auto-create user-owned directories.
                let home = fileManager.homeDirectoryForCurrentUser
                let owned = candidate.path.hasPrefix(home.path)
                if !owned || (try? fileManager.createDirectory(
                    at: candidate, withIntermediateDirectories: true
                )) == nil {
                    continue
                }
            }
            if fileManager.isWritableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func findSymlink(
        named name: String,
        in candidates: [URL],
        resolvingTo target: URL,
        fileManager: FileManager
    ) -> URL? {
        let standardizedTarget = target.standardizedFileURL.path
        for candidate in candidates {
            let symlink = candidate.appendingPathComponent(name)
            guard let destination = try? fileManager.destinationOfSymbolicLink(
                atPath: symlink.path
            ) else { continue }
            let resolved = URL(fileURLWithPath: destination).standardizedFileURL.path
            if resolved == standardizedTarget {
                return symlink
            }
        }
        return nil
    }
}
