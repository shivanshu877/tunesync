import SwiftUI
import WebKit
import TuneSyncCore

public struct WebViewHost: NSViewRepresentable {
    public let player: PlayerController

    public init(player: PlayerController) {
        self.player = player
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false

        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "tunesync")

        let script = WKUserScript(source: InjectedJS.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        userContent.addUserScript(script)

        cfg.userContentController = userContent

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let req = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        wv.load(req)

        player.attach(to: wv)
        return wv
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let player: PlayerController

        init(player: PlayerController) {
            self.player = player
        }

        // Block target=_blank / cmd-click new windows: load the URL inline if it's allowed,
        // ignore if it isn't.
        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url,
               let host = url.host,
               host == "music.youtube.com" || host.hasSuffix(".music.youtube.com") {
                webView.load(navigationAction.request)
            } else {
                Log.player.info("blocked new window for \(navigationAction.request.url?.host ?? "?", privacy: .public)")
            }
            return nil
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "tunesync" else { return }
            let body = message.body
            Task { @MainActor in
                self.player.handleMessage(body)
            }
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, let host = url.host else { return .allow }

            // Always allow YT Music itself
            if host == "music.youtube.com" || host.hasSuffix(".music.youtube.com") {
                return .allow
            }

            // Always allow Google login flow (sign-in, consent, account picker)
            let authHosts = ["accounts.google.com", "accounts.youtube.com", "consent.youtube.com", "consent.google.com", "myaccount.google.com"]
            if authHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return .allow
            }

            // For any other youtube.com host (e.g. www.youtube.com): block user clicks,
            // but allow server-side redirects so the OAuth flow can complete.
            if host == "youtube.com" || host.hasSuffix(".youtube.com") {
                if navigationAction.navigationType == .linkActivated {
                    Log.player.info("redirected click on \(host, privacy: .public) back to music.youtube.com")
                    let webViewRef = webView
                    Task { @MainActor in
                        webViewRef.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
                    }
                    return .cancel
                }
                return .allow
            }

            // Everything else: blocked
            Log.player.info("blocked navigation to \(host, privacy: .public)")
            return .cancel
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Belt-and-suspenders: if a navigation lands us on www.youtube.com (e.g. a
            // user-clicked link slipped through as a non-link activation), bounce home.
            guard let url = webView.url, let host = url.host else { return }
            let isYTMusic = host == "music.youtube.com" || host.hasSuffix(".music.youtube.com")
            let isAuth = ["accounts.google.com", "accounts.youtube.com", "consent.youtube.com", "consent.google.com", "myaccount.google.com"]
                .contains(where: { host == $0 || host.hasSuffix("." + $0) })
            if !isYTMusic && !isAuth {
                Log.player.info("post-load bounce from \(host, privacy: .public) → music.youtube.com")
                let webViewRef = webView
                Task { @MainActor in
                    webViewRef.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
                }
            }
        }
    }
}
