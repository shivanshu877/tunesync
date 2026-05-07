import Foundation
import AppKit
import TuneSyncCore

/// Polls a static JSON manifest hosted on GitHub Pages to find out if a
/// newer release is available. On finding one, shows a non-blocking
/// alert with a Download button that opens the DMG URL in the default
/// browser. The user manually installs.
///
/// Manifest schema (`updates.json`):
/// ```
/// {
///   "version": "0.2.5",
///   "url": "https://shivanshu877.github.io/tunesync/TuneSync-0.2.5.dmg",
///   "notes": "Markdown-formatted changelog. Optional."
/// }
/// ```
///
/// Versions are compared with semver-style numeric component compare.
@MainActor
public final class Updater: ObservableObject {

    public struct Manifest: Codable, Sendable {
        public let version: String
        public let url: String
        public let notes: String?
    }

    @Published public var available: Manifest?
    @Published public var lastChecked: Date?
    @Published public var lastError: String?

    private let manifestURL: URL
    private let currentVersion: String
    private var timer: Timer?

    /// - Parameters:
    ///   - manifestURL: The public URL of `updates.json`.
    ///   - currentVersion: Override (mostly for tests). Defaults to
    ///     `CFBundleShortVersionString` from the running app.
    public init(
        manifestURL: URL = URL(string: "https://shivanshu877.github.io/tunesync/updates.json")!,
        currentVersion: String? = nil
    ) {
        self.manifestURL = manifestURL
        self.currentVersion =
            currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    public func startPeriodicChecks(intervalHours: Double = 6) {
        // Initial check 30s after launch (let the WebView settle).
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await self?.check()
        }
        let t = Timer.scheduledTimer(withTimeInterval: intervalHours * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Manually trigger a check. Surfaces a "you're up to date" alert if
    /// no update — so this can be wired to a Help → Check for Updates menu.
    public func checkInteractive() {
        Task { @MainActor in
            await self.check()
            if let m = self.available {
                self.presentAvailable(m)
            } else if self.lastError != nil {
                self.presentError(self.lastError ?? "Unknown error")
            } else {
                self.presentUpToDate()
            }
        }
    }

    public func check() async {
        do {
            var req = URLRequest(url: manifestURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw NSError(domain: "Updater", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                ])
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            lastChecked = Date()
            lastError = nil
            if Self.isNewer(manifest.version, than: currentVersion) {
                available = manifest
                Log.app.info("update available: \(manifest.version, privacy: .public)")
                presentAvailable(manifest)
            } else {
                available = nil
                Log.app.info("no update; current=\(self.currentVersion, privacy: .public) latest=\(manifest.version, privacy: .public)")
            }
        } catch {
            lastError = error.localizedDescription
            Log.app.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var alertOpen = false

    private func presentAvailable(_ manifest: Manifest) {
        guard !alertOpen else { return }
        alertOpen = true
        let alert = NSAlert()
        alert.messageText = "TuneSync \(manifest.version) is available"
        alert.informativeText =
            (manifest.notes?.isEmpty == false ? manifest.notes! + "\n\n" : "")
            + "You're on \(currentVersion). Click Download to grab the new DMG, then drag it into Applications."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        alertOpen = false
        if response == .alertFirstButtonReturn, let dmg = URL(string: manifest.url) {
            NSWorkspace.shared.open(dmg)
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "TuneSync \(currentVersion) is the latest."
        alert.runModal()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = message
        alert.runModal()
    }

    /// Numeric component compare: "0.10.0" > "0.9.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let ap = a.split(separator: ".").compactMap { Int($0) }
        let bp = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(ap.count, bp.count) {
            let av = i < ap.count ? ap[i] : 0
            let bv = i < bp.count ? bp[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
