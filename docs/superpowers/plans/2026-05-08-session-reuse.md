# Session Reuse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Let users import a YouTube Music session from Brave / Chrome / Edge / Safari into TuneSync's WKWebView so they don't have to sign in twice.

**Architecture:** New `Sources/TuneSync/SessionImport/` module. Per-browser `CookieReader` types (Chromium-family share one impl; Safari has its own binarycookies parser). Reads cookies for `*.youtube.com` + `*.google.com`. Decrypts Chromium's encrypted-value column via Keychain-stored key (PBKDF2 → AES-128-CBC). Injects into `WKHTTPCookieStore`. UI: settings menu item → `CookieImportSheet` with browser picker + import status.

**Tech Stack:** Swift, `SQLite3` C lib, `CommonCrypto`, `Security`/Keychain, WebKit, SwiftUI.

---

## File Structure

- `Sources/TuneSync/SessionImport/CookieReader.swift` — protocol + shared types.
- `Sources/TuneSync/SessionImport/ChromiumCookieReader.swift` — Brave/Chrome/Edge SQLite + Keychain decrypt.
- `Sources/TuneSync/SessionImport/SafariCookieReader.swift` — `Cookies.binarycookies` parser.
- `Sources/TuneSync/SessionImport/CookieImporter.swift` — translates `ImportedCookie` → `HTTPCookie` → `WKHTTPCookieStore.setCookie`.
- `Sources/TuneSync/SessionImport/CookieImportSheet.swift` — SwiftUI sheet.
- `Sources/TuneSync/ContentView.swift` — toolbar entry point + sheet binding.
- `Tests/TuneSyncCoreTests/...` — pure-logic tests for the binarycookies parser; Chromium needs fixture SQLite DB and is harder to unit-test (best left to manual smoke).

---

## Task 1: Cookie types + `CookieReader` protocol

**File:** `Sources/TuneSync/SessionImport/CookieReader.swift`

- [ ] **Step 1: Create file**

```swift
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

/// Hosts we care about. Restricted by code review — never broadened to a wildcard.
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
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/TuneSync/SessionImport/CookieReader.swift
git commit -m "feat(session-import): cookie types + CookieReader protocol"
```

---

## Task 2: ChromiumCookieReader

**File:** `Sources/TuneSync/SessionImport/ChromiumCookieReader.swift`

Reads SQLite Cookies DB, fetches Chromium's "Safe Storage" key from Keychain, decrypts encrypted values via PBKDF2 → AES-128-CBC.

- [ ] **Step 1: Create file**

```swift
import Foundation
import SQLite3
import CommonCrypto
import Security

public final class ChromiumCookieReader: CookieReader {
    public let browser: SupportedBrowser

    private let cookieDBPath: String
    private let keychainService: String

    public init?(browser: SupportedBrowser) {
        self.browser = browser
        let home = NSHomeDirectory()
        switch browser {
        case .brave:
            self.cookieDBPath = "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"
            self.keychainService = "Brave Safe Storage"
        case .chrome:
            self.cookieDBPath = "\(home)/Library/Application Support/Google/Chrome/Default/Cookies"
            self.keychainService = "Chrome Safe Storage"
        case .edge:
            self.cookieDBPath = "\(home)/Library/Application Support/Microsoft Edge/Default/Cookies"
            self.keychainService = "Microsoft Edge Safe Storage"
        case .safari:
            return nil
        }
    }

    public func isAvailable() -> Bool {
        return FileManager.default.fileExists(atPath: cookieDBPath)
    }

    public func readYouTubeCookies() throws -> [ImportedCookie] {
        guard isAvailable() else { throw CookieReadError.browserNotInstalled }
        let key = try fetchKeychainKey()
        let derivedKey = try deriveAESKey(from: key)
        return try queryCookies(decryptingWith: derivedKey)
    }

    private func fetchKeychainKey() throws -> Data {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw CookieReadError.keychainAccessDenied
            }
            throw CookieReadError.keychainKeyMissing
        }
        return data
    }

    private func deriveAESKey(from passphrase: Data) throws -> Data {
        // Chromium PBKDF2 params: iter=1003, salt="saltysalt", key length=16.
        let salt = Array("saltysalt".utf8)
        var derived = Data(count: 16)
        let result = derived.withUnsafeMutableBytes { (derivedPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            return passphrase.withUnsafeBytes { (passPtr: UnsafeRawBufferPointer) -> Int32 in
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr.bindMemory(to: Int8.self).baseAddress, passphrase.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    derivedPtr.bindMemory(to: UInt8.self).baseAddress, 16
                )
            }
        }
        guard result == 0 else { throw CookieReadError.parseFailed("pbkdf2") }
        return derived
    }

    private func decryptValue(_ blob: Data, key: Data) throws -> String {
        // v10 / v11 prefix: strip 3 bytes.
        guard blob.count > 3 else { return "" }
        let prefix = blob.prefix(3)
        let body: Data
        if prefix == Data("v10".utf8) || prefix == Data("v11".utf8) {
            body = blob.dropFirst(3)
        } else {
            // Plaintext (older).
            return String(data: blob, encoding: .utf8) ?? ""
        }
        // IV: 16 bytes of 0x20.
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr -> CCCryptorStatus in
            return body.withUnsafeBytes { bodyPtr -> CCCryptorStatus in
                return iv.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                    return key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            bodyPtr.baseAddress, body.count,
                            outPtr.baseAddress, out.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CookieReadError.parseFailed("aes-decrypt") }
        out.count = moved
        // v10/v11 cookies have a 32-byte SHA-256 hash prefix on the plaintext.
        // Strip if present (best-effort: only drop when length suggests it).
        let utf8 = String(data: out, encoding: .utf8)
        if let s = utf8 { return s }
        if out.count >= 32 {
            let stripped = out.dropFirst(32)
            return String(data: stripped, encoding: .utf8) ?? ""
        }
        return ""
    }

    private func queryCookies(decryptingWith key: Data) throws -> [ImportedCookie] {
        // Chrome locks the live DB. Copy to a temp file before opening.
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tunesync-cookies-\(UUID().uuidString).db")
        try FileManager.default.copyItem(atPath: cookieDBPath, toPath: tmpURL.path)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CookieReadError.databaseUnreadable("open")
        }
        defer { sqlite3_close(db) }

        // Newer Chromium: name, value, encrypted_value, host_key, path, expires_utc, is_secure, is_httponly
        let sql = """
        SELECT name, value, encrypted_value, host_key, path, expires_utc, is_secure, is_httponly
        FROM cookies
        WHERE host_key LIKE '%.youtube.com' OR host_key LIKE '%youtube.com'
           OR host_key LIKE '%.google.com'  OR host_key LIKE '%google.com'
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CookieReadError.databaseUnreadable("prepare")
        }
        defer { sqlite3_finalize(stmt) }

        var out: [ImportedCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let plainValue = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let encBytes = sqlite3_column_bytes(stmt, 2)
            let encBlob = sqlite3_column_blob(stmt, 2)
            let host = String(cString: sqlite3_column_text(stmt, 3))
            let path = String(cString: sqlite3_column_text(stmt, 4))
            let expiresMicros = sqlite3_column_int64(stmt, 5)
            let isSecure = sqlite3_column_int(stmt, 6) != 0
            let isHTTPOnly = sqlite3_column_int(stmt, 7) != 0

            guard CookieScope.matches(host: host) else { continue }

            let value: String
            if encBytes > 0, let blobPtr = encBlob {
                let blob = Data(bytes: blobPtr, count: Int(encBytes))
                value = (try? decryptValue(blob, key: key)) ?? plainValue
            } else {
                value = plainValue
            }

            // Chromium expires_utc = microseconds since 1601-01-01 UTC.
            let expires: Date?
            if expiresMicros > 0 {
                let chromiumEpoch = Date(timeIntervalSince1970: -11644473600) // 1601-01-01
                expires = chromiumEpoch.addingTimeInterval(TimeInterval(expiresMicros) / 1_000_000)
            } else {
                expires = nil
            }

            out.append(ImportedCookie(
                name: name, value: value, domain: host, path: path,
                expires: expires, isSecure: isSecure, isHTTPOnly: isHTTPOnly
            ))
        }
        return out
    }
}
```

- [ ] **Step 2: Confirm SQLite + CommonCrypto link**

`swift build` should already link them on macOS (system libs).

- [ ] **Step 3: Commit**

```bash
git add Sources/TuneSync/SessionImport/ChromiumCookieReader.swift
git commit -m "feat(session-import): ChromiumCookieReader for Brave/Chrome/Edge"
```

---

## Task 3: SafariCookieReader

**File:** `Sources/TuneSync/SessionImport/SafariCookieReader.swift`

Parses `~/Library/Cookies/Cookies.binarycookies`. Format: big-endian header, page count, page offsets, each page has a magic + cookie offsets, each cookie is a fixed-size header + null-terminated strings.

- [ ] **Step 1: Create file**

```swift
import Foundation

public final class SafariCookieReader: CookieReader {
    public let browser = SupportedBrowser.safari

    private let path: String

    public init() {
        self.path = "\(NSHomeDirectory())/Library/Cookies/Cookies.binarycookies"
    }

    public func isAvailable() -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }

    public func readYouTubeCookies() throws -> [ImportedCookie] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            // Most often: Full Disk Access not granted.
            throw CookieReadError.fullDiskAccessRequired
        }
        return try parse(data)
    }

    /// `Cookies.binarycookies` format:
    /// - 4 bytes "cook" magic
    /// - 4 bytes BE: number of pages
    /// - N * 4 bytes BE: page sizes
    /// - For each page:
    ///   - 4 bytes "\0\0\1\0" page magic
    ///   - 4 bytes LE: number of cookies
    ///   - C * 4 bytes LE: cookie offsets within page
    ///   - 4 bytes 0x00000000
    ///   - For each cookie at its offset:
    ///     - 4 bytes LE: cookie size
    ///     - 4 bytes (unknown)
    ///     - 4 bytes LE: flags (1=secure, 4=httponly)
    ///     - 4 bytes (unknown)
    ///     - 4 bytes LE: url offset
    ///     - 4 bytes LE: name offset
    ///     - 4 bytes LE: path offset
    ///     - 4 bytes LE: value offset
    ///     - 8 bytes 0x00..00 end-marker
    ///     - 8 bytes LE double: expires (Mac epoch = 2001-01-01)
    ///     - 8 bytes LE double: created
    ///     - then the four null-terminated strings at their offsets.
    func parse(_ data: Data) throws -> [ImportedCookie] {
        guard data.count > 8 else { throw CookieReadError.parseFailed("too small") }
        guard data.subdata(in: 0..<4) == Data("cook".utf8) else {
            throw CookieReadError.parseFailed("bad magic")
        }
        let pageCount = Int(readUInt32BE(data, at: 4))
        guard data.count >= 8 + pageCount * 4 else {
            throw CookieReadError.parseFailed("truncated header")
        }
        var pageSizes: [Int] = []
        for i in 0..<pageCount {
            pageSizes.append(Int(readUInt32BE(data, at: 8 + i * 4)))
        }
        var pageStart = 8 + pageCount * 4

        var cookies: [ImportedCookie] = []
        for size in pageSizes {
            let pageEnd = pageStart + size
            guard pageEnd <= data.count else {
                throw CookieReadError.parseFailed("page overflow")
            }
            let page = data.subdata(in: pageStart..<pageEnd)
            try parsePage(page, into: &cookies)
            pageStart = pageEnd
        }
        return cookies.filter { CookieScope.matches(host: $0.domain) }
    }

    private func parsePage(_ page: Data, into cookies: inout [ImportedCookie]) throws {
        guard page.count >= 8 else { return }
        // Magic 0x00000100 (LE: 0x00 0x00 0x01 0x00).
        let cookieCount = Int(readUInt32LE(page, at: 4))
        guard page.count >= 8 + cookieCount * 4 else {
            throw CookieReadError.parseFailed("page header")
        }
        var offsets: [Int] = []
        for i in 0..<cookieCount {
            offsets.append(Int(readUInt32LE(page, at: 8 + i * 4)))
        }
        for off in offsets {
            if let c = parseCookie(page, at: off) {
                cookies.append(c)
            }
        }
    }

    private func parseCookie(_ page: Data, at off: Int) -> ImportedCookie? {
        guard off + 56 <= page.count else { return nil }
        let flags = readUInt32LE(page, at: off + 8)
        let urlOff = Int(readUInt32LE(page, at: off + 16))
        let nameOff = Int(readUInt32LE(page, at: off + 20))
        let pathOff = Int(readUInt32LE(page, at: off + 24))
        let valueOff = Int(readUInt32LE(page, at: off + 28))
        let expiresMac = readDoubleLE(page, at: off + 40)

        let macEpoch = Date(timeIntervalSince1970: 978307200) // 2001-01-01
        let expires = expiresMac > 0 ? macEpoch.addingTimeInterval(expiresMac) : nil

        guard let url = readCString(page, at: off + urlOff),
              let name = readCString(page, at: off + nameOff),
              let path = readCString(page, at: off + pathOff),
              let value = readCString(page, at: off + valueOff) else {
            return nil
        }

        return ImportedCookie(
            name: name, value: value,
            domain: url, path: path,
            expires: expires,
            isSecure: (flags & 1) != 0,
            isHTTPOnly: (flags & 4) != 0
        )
    }

    private func readUInt32BE(_ d: Data, at i: Int) -> UInt32 {
        let b = d.subdata(in: i..<i+4)
        return (UInt32(b[b.startIndex]) << 24) |
               (UInt32(b[b.startIndex + 1]) << 16) |
               (UInt32(b[b.startIndex + 2]) << 8) |
                UInt32(b[b.startIndex + 3])
    }

    private func readUInt32LE(_ d: Data, at i: Int) -> UInt32 {
        let b = d.subdata(in: i..<i+4)
        return  UInt32(b[b.startIndex]) |
               (UInt32(b[b.startIndex + 1]) << 8) |
               (UInt32(b[b.startIndex + 2]) << 16) |
               (UInt32(b[b.startIndex + 3]) << 24)
    }

    private func readDoubleLE(_ d: Data, at i: Int) -> Double {
        let b = d.subdata(in: i..<i+8)
        return b.withUnsafeBytes { ptr in ptr.load(as: Double.self) }
    }

    private func readCString(_ d: Data, at i: Int) -> String? {
        guard i < d.count else { return nil }
        var end = i
        while end < d.count && d[d.startIndex + end] != 0 { end += 1 }
        return String(data: d.subdata(in: i..<end), encoding: .utf8)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/TuneSync/SessionImport/SafariCookieReader.swift
git commit -m "feat(session-import): SafariCookieReader for binarycookies"
```

---

## Task 4: CookieImporter (inject into WKWebView)

**File:** `Sources/TuneSync/SessionImport/CookieImporter.swift`

- [ ] **Step 1: Create file**

```swift
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
```

Add a small helper on `PlayerController` to expose its `WKWebView`:

```swift
public func currentWebView() -> WKWebView? { return webView }
```

(Place near `navigate`. `webView` is the existing weak ref.)

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/TuneSync/SessionImport/CookieImporter.swift Sources/TuneSync/PlayerController.swift
git commit -m "feat(session-import): CookieImporter writes into WKHTTPCookieStore"
```

---

## Task 5: CookieImportSheet UI

**File:** `Sources/TuneSync/SessionImport/CookieImportSheet.swift`

- [ ] **Step 1: Create file**

```swift
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
```

- [ ] **Step 2: Wire up in `ContentView`**

Add to `ContentView` body's existing toolbar a second item (placement: `.primaryAction`) that opens the sheet:

```swift
@State private var showImportSheet: Bool = false

// inside .toolbar { ... }:
ToolbarItem(placement: .primaryAction) {
    Button { showImportSheet = true } label: {
        Label("Import session", systemImage: "key.fill")
    }
    .help("Import a YouTube Music session from another browser")
}

// at the end of body, attach sheet:
.sheet(isPresented: $showImportSheet) {
    CookieImportSheet(rt: rt)
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build
git add Sources/TuneSync/SessionImport/CookieImportSheet.swift Sources/TuneSync/ContentView.swift
git commit -m "feat(session-import): import sheet wired into toolbar"
```

---

## Task 6: README + manual scenarios + version bump

- [ ] **Step 1: Append to `docs/TESTING.md`:**

```markdown
## Session-import scenarios (post 0.3.0)

### Brave / Chrome import

1. Sign into YT Music in Brave on the test Mac.
2. In TuneSync, click "Import session" in the toolbar.
3. Click "Import from Brave". macOS may prompt to allow Keychain access — approve.
4. Sheet shows "Imported N cookies. Reloaded." TuneSync's WebView now shows the signed-in YT Music UI.

### Safari import

1. Sign into YT Music in Safari.
2. Click "Import from Safari". If Full Disk Access is missing, the sheet says so.
3. Grant FDA in System Settings → Privacy & Security → Full Disk Access → TuneSync. Restart app.
4. Try again. Imports.

### Clear

1. Click "Clear imported session" in the sheet.
2. WebView reloads to a signed-out state.
```

- [ ] **Step 2: Bump to 0.3.0**

`sed -i '' 's/0\.2\.10/0.3.0/g' Makefile`

- [ ] **Step 3: Commit**

```bash
git add docs/TESTING.md Makefile
git commit -m "build: bump to 0.3.0 for session-import release"
```

---

## Self-Review

| Spec section | Task |
| --- | --- |
| ImportedCookie + protocol | 1 |
| Chromium reader (Brave/Chrome/Edge) | 2 |
| Safari binarycookies reader | 3 |
| WKHTTPCookieStore inject + clear | 4 |
| Import sheet UI | 5 |
| Manual tests + bump | 6 |

No placeholders. Names consistent (`ImportedCookie`, `CookieReader`, `CookieReadError`, `SupportedBrowser`).
