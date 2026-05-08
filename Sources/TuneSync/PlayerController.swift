import Foundation
import WebKit
import TuneSyncCore

public struct DiagSnapshot: Equatable, Sendable {
    public let videoId: String?
    public let t: Double?
    public let playing: Bool?
    public let ad: Bool?
    public let skipped: String?
    public let trackChange: Bool
    public let at: Date

    public var isLive: Bool { videoId != nil && skipped == nil }
}

@MainActor
public final class PlayerController: NSObject {

    public var onLocalState: ((PlayerState) -> Void)?
    public var onAdStateChanged: ((Bool) -> Void)?
    public var onDiag: ((DiagSnapshot) -> Void)?

    private weak var webView: WKWebView?
    private var lastAd: Bool = false

    public override init() {
        super.init()
    }

    public func attach(to webView: WKWebView) {
        self.webView = webView
    }

    public func handleMessage(_ payload: Any) {
        guard let dict = payload as? [String: Any] else { return }
        let kind = (dict["kind"] as? String) ?? ""

        if kind == "diag" {
            let diag = DiagSnapshot(
                videoId: dict["videoId"] as? String,
                t: dict["t"] as? Double,
                playing: dict["playing"] as? Bool,
                ad: dict["ad"] as? Bool,
                skipped: dict["skipped"] as? String,
                trackChange: (dict["trackChange"] as? Bool) ?? false,
                at: Date()
            )
            onDiag?(diag)
            return
        }

        guard kind == "state" else { return }
        guard let videoId = dict["videoId"] as? String else { return }
        let t = (dict["t"] as? Double) ?? 0
        let playing = (dict["playing"] as? Bool) ?? false
        let ad = (dict["ad"] as? Bool) ?? false

        if ad != lastAd {
            lastAd = ad
            onAdStateChanged?(ad)
        }
        onLocalState?(PlayerState(videoId: videoId, t: t, playing: playing))
    }

    public func applyState(_ state: PlayerState) {
        guard let wv = webView else { return }
        let js = "window.tunesyncApplyState && window.tunesyncApplyState(\(jsString(state.videoId)), \(state.t), \(state.playing));"
        wv.evaluateJavaScript(js) { _, error in
            if let error {
                Log.player.error("applyState JS error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
