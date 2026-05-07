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
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let req = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        wv.load(req)

        player.attach(to: wv)
        return wv
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {}

    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let player: PlayerController

        init(player: PlayerController) {
            self.player = player
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
            let allowed = ["music.youtube.com", "www.youtube.com", "youtube.com", "accounts.google.com", "accounts.youtube.com", "consent.youtube.com"]
            if allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return .allow
            }
            Log.player.info("blocked navigation to \(host, privacy: .public)")
            return .cancel
        }
    }
}
