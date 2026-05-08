import SwiftUI
import WebKit

public struct CookieImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var rt: AppRuntime
    @State private var status: String = ""
    @State private var importing: Bool = false

    public init(rt: AppRuntime) {
        self.rt = rt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import session from another browser")
                .font(.headline)
            Text("TuneSync will copy your YouTube and Google cookies from the chosen browser into its own WebView so you don't have to sign in again. Cookies stay on this Mac.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(SupportedBrowser.allCases, id: \.self) { browser in
                Button {
                    Task { await runImport(browser: browser) }
                } label: {
                    HStack {
                        Image(systemName: icon(for: browser))
                        Text("Import from \(browser.rawValue)")
                        Spacer()
                        if !available(browser) {
                            Text("not installed").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!available(browser) || importing)
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Button("Clear imported session") {
                    Task { await runClear() }
                }
                .disabled(importing)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 360)
    }

    private func available(_ browser: SupportedBrowser) -> Bool {
        return reader(for: browser)?.isAvailable() ?? false
    }

    private func reader(for browser: SupportedBrowser) -> CookieReader? {
        switch browser {
        case .brave, .chrome, .edge:
            return ChromiumCookieReader(browser: browser)
        case .safari:
            return SafariCookieReader()
        }
    }

    private func icon(for browser: SupportedBrowser) -> String {
        switch browser {
        case .brave, .chrome, .edge: return "globe"
        case .safari: return "safari"
        }
    }

    @MainActor
    private func runImport(browser: SupportedBrowser) async {
        importing = true
        defer { importing = false }
        status = "Importing from \(browser.rawValue)…"
        do {
            guard let r = reader(for: browser) else {
                status = "No reader for \(browser.rawValue)"
                return
            }
            let cookies = try r.readYouTubeCookies()
            guard let wv = rt.player.currentWebView() else {
                status = "WebView not ready."
                return
            }
            let importer = CookieImporter(webView: wv)
            await importer.inject(cookies)
            wv.reload()
            status = "Imported \(cookies.count) cookies from \(browser.rawValue). Reloaded."
        } catch let e as CookieReadError {
            status = e.description
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func runClear() async {
        importing = true
        defer { importing = false }
        guard let wv = rt.player.currentWebView() else { return }
        let importer = CookieImporter(webView: wv)
        await importer.clear()
        wv.reload()
        status = "Cleared imported session."
    }
}
