import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController?
    private var started = false

    var diagnosticStatus: String {
        controller == nil ? "Unavailable (requires a configured app bundle)"
            : (canCheckForUpdates ? "Ready" : "Not ready or busy")
    }

    init(bundle: Bundle = .main) {
        guard Self.isConfigured(
            bundleURL: bundle.bundleURL,
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        ) else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    static func isConfigured(bundleURL: URL, feedURL: String?) -> Bool {
        guard bundleURL.pathExtension == "app",
              let feedURL, let url = URL(string: feedURL),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    func start() {
        guard !started, let controller else { return }
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
