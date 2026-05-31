import Foundation
import WebKit

@MainActor
public final class CookieImporter {
    private let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func inject(_ cookies: [ImportedCookie]) async {
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for ic in cookies {
            guard let httpCookie = Self.makeHTTPCookie(ic) else { continue }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.setCookie(httpCookie) { cont.resume() }
            }
        }
    }

    public func clear() async {
        let dataStore = webView.configuration.websiteDataStore
        let types: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage
        ]
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) {
                cont.resume()
            }
        }
    }

    static func makeHTTPCookie(_ ic: ImportedCookie) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: ic.name,
            .value: ic.value,
            .domain: ic.domain,
            .path: ic.path.isEmpty ? "/" : ic.path,
        ]
        if let exp = ic.expires {
            props[.expires] = exp
        }
        if ic.isSecure { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)
    }
}
