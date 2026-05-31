import Foundation

public struct ImportedCookie: Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expires: Date?
    public let isSecure: Bool
    public let isHTTPOnly: Bool

    public init(name: String, value: String, domain: String, path: String,
                expires: Date?, isSecure: Bool, isHTTPOnly: Bool) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }
}

public enum SupportedBrowser: String, CaseIterable, Sendable {
    case brave = "Brave"
    case chrome = "Chrome"
    case edge = "Edge"
    case safari = "Safari"
}

public enum CookieReadError: Error, CustomStringConvertible, Sendable {
    case browserNotInstalled
    case keychainAccessDenied
    case keychainKeyMissing
    case databaseUnreadable(String)
    case fullDiskAccessRequired
    case parseFailed(String)

    public var description: String {
        switch self {
        case .browserNotInstalled: return "Browser is not installed."
        case .keychainAccessDenied: return "Keychain access denied."
        case .keychainKeyMissing:   return "Keychain key not found."
        case .databaseUnreadable(let s): return "Cookie store unreadable: \(s)"
        case .fullDiskAccessRequired: return "Safari requires Full Disk Access."
        case .parseFailed(let s): return "Cookie parse failed: \(s)"
        }
    }
}

public protocol CookieReader {
    var browser: SupportedBrowser { get }
    func isAvailable() -> Bool
    func readYouTubeCookies() throws -> [ImportedCookie]
}

public enum CookieScope {
    public static let allowedSuffixes = [
        ".youtube.com",
        "youtube.com",
        ".google.com",
        "google.com"
    ]

    public static func matches(host: String) -> Bool {
        let h = host.hasPrefix(".") ? host : "." + host
        return allowedSuffixes.contains { h.hasSuffix($0) || h == $0 }
    }
}
